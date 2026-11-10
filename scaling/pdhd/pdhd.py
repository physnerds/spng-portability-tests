#!/usr/bin/env python3
"""External container PDHD scaling campaign: generate, plan, run, summarize."""
import argparse
import csv
from contextlib import contextmanager
import itertools
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
import zipfile

from npz_events import digest, generate, index, subset, validate

HERE = Path(__file__).resolve().parent


def save(path, obj):
    path = Path(path)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(obj, indent=2, allow_nan=False)+'\n')
    temporary.replace(path)


def read(path):
    return json.loads(Path(path).read_text())


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return number


def partitions(events, processes):
    if processes < 1:
        raise ValueError('Process count must be positive')
    if processes > len(events):
        raise ValueError('Need at least one event per Wire-Cell process')
    return [events[p::processes] for p in range(processes)]


def placement(nodes, processes, gpus_per_node):
    if min(nodes, processes, gpus_per_node) < 1:
        raise ValueError('Placement counts must be positive')
    if processes % nodes:
        raise ValueError('Total processes must divide evenly across nodes')
    per_node = processes // nodes
    active = min(per_node, gpus_per_node)
    ranks = []
    for node in range(nodes):
        for gpu in range(active):
            ranks.append(dict(node=node, gpu=gpu,
                              slots=list(range(node*per_node+gpu, (node+1)*per_node, active))))
    return active, ranks


def plan(args):
    profile = read(HERE/'profiles.json')[args.profile]
    for key in ('gpus_per_node', 'physical_cores_per_node', 'slurm_cpus_per_core', 'runtime', 'container_python'):
        value = getattr(args, key)
        if value is not None:
            profile[key] = value
    if args.network is not None:
        profile['network'] = args.network or None
    dataset = args.dataset.resolve(strict=True)
    meta = read(dataset/'dataset.json')
    events = [m['event_id'] for m in meta['mapping']]
    if len(set(events)) != len(events) or len(events) != meta['events']:
        raise ValueError('Dataset manifest has invalid event IDs')
    if meta.get('apas') != 4 or len(meta['archives']) != 4:
        raise ValueError('Dataset must contain exactly four APA archives')
    for apa, record in enumerate(meta['archives']):
        source = dataset/f'adc-tpc{apa}.npz'
        if record['path'] != source.name or digest(source) != record['sha256']:
            raise ValueError(f'Dataset hash mismatch: {source}')
        validate(source, events)
    cores = args.cores_per_process or max(args.threads)
    if max(args.threads) > cores:
        raise ValueError('TBB threads exceed physical cores/process; increase --cores-per-process')
    cases = []
    for nodes, processes, threads in itertools.product(args.nodes, args.processes, args.threads):
        active, ranks = placement(nodes, processes, profile['gpus_per_node'])
        partitions(events, processes)
        if (processes//nodes)*cores > profile['physical_cores_per_node']:
            raise ValueError(f'{nodes=} {processes=}: physical CPU oversubscription')
        slots = max(len(r['slots']) for r in ranks)
        if active*slots*cores > profile['physical_cores_per_node']:
            raise ValueError('Uniform Slurm controller CPU requests exceed node capacity')
        cases.append(dict(name=f'n{nodes}-p{processes}-t{threads}', nodes=nodes,
                          processes=processes, threads=threads, cores_per_process=cores,
                          active_gpus_per_node=active, gpus=len(ranks), ranks=ranks,
                          slurm_cpus_per_task=slots*cores*profile['slurm_cpus_per_core']))
    if len({c['name'] for c in cases}) != len(cases):
        raise ValueError('Duplicate matrix values')
    args.output.mkdir(parents=True, exist_ok=False)
    root = args.output.resolve()
    (root/'suite').mkdir()
    for name in ('pdhd.py', 'npz_events.py', 'pdhd.jsonnet', 'profiles.json'):
        shutil.copy2(HERE/name, root/'suite'/name)
    shutil.copy2(args.model.resolve(strict=True), root/'model.ts')
    save(root/'dataset.json', meta)
    for processes in sorted(set(args.processes)):
        batches = partitions(events, processes)
        for slot, batch in enumerate(batches):
            directory = root/f'shards/p{processes}/slot{slot}'
            directory.mkdir(parents=True)
            for apa in range(4):
                subset(dataset/f'adc-tpc{apa}.npz', directory/f'adc-tpc{apa}.npz',
                       [(e, e) for e in batch])
    hashes = {str(p.relative_to(root)): digest(p) for p in (root/'shards').rglob('*.npz')}
    hashes.update({f'suite/{n}': digest(root/'suite'/n)
                   for n in ('pdhd.py', 'npz_events.py', 'pdhd.jsonnet', 'profiles.json')})
    hashes['model.ts'] = digest(root/'model.ts')
    config = dict(schema=1, events=events, dataset=meta, profile=profile,
                  image=args.image, launcher=args.launcher, cases=cases,
                  warmups=args.warmups, repeats=args.repeats, timeout=args.timeout,
                  barrier_timeout=args.barrier_timeout, sample_ms=args.sample_ms,
                  torch_threads=args.torch_threads,
                  wirecell_data=str(args.wirecell_data.resolve(strict=True)) if args.wirecell_data else None,
                  wirecell_path=args.wirecell_path, hashes=hashes,
                  timing='Coordinator monotonic clock; processing window from barrier release '
                         'to last wc-finished marker, excluding validation and event assembly.')
    save(root/'campaign.json', config)
    print(f'Prepared {len(cases)} cases for {len(events)} complete events in {root}')
    print('Repeated complete-event copies:', meta['repeated_copies'])


def cpu_identity(cpu):
    base = Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
    return [int((base/'physical_package_id').read_text()), int((base/'core_id').read_text())]


def physical_cpus():
    """One allowed logical CPU per physical core, without hard-coded SMT IDs."""
    selected = {}
    for cpu in sorted(os.sched_getaffinity(0)):
        key = tuple(cpu_identity(cpu))
        selected.setdefault(key, cpu)
    return list(selected.values())


def command(case, slot, config, round_rel):
    base = f'/campaign/{round_rel}/slot{slot}'
    result = ['wire-cell', '-l', base+'.wirecell.log', '-L', 'info',
              '-c', '/campaign/suite/pdhd.jsonnet']
    params = dict(input=f'/campaign/shards/p{case["processes"]}/slot{slot}/adc.npz',
                  output=base+'.npz', model_file='/campaign/model.ts',
                  stage='spng', detname='pdhd', napa=4, apa=-1,
                  engine='TbbFlow', wc_cores=case['threads'], device='gpu0',
                  gpu_scheme='none', ngpu=1, timeline=base+'.timeline.json')
    for key, value in params.items():
        result += ['-A', f'{key}={value}']
    return result


def gpu_uuid(value):
    """Canonical full-GPU UUID; reject indices and MIG tokens as identities."""
    import re
    value = str(value).lower().removeprefix('gpu-').replace('-', '')
    if not re.fullmatch(r'[0-9a-f]{32}', value):
        raise ValueError(f'Expected full GPU UUID, got {value!r}')
    return value


def assigned_gpu(token):
    result = subprocess.run(['nvidia-smi', '-i', token, '--query-gpu=uuid',
                             '--format=csv,noheader'], capture_output=True, text=True,
                            check=True, timeout=30)
    values = result.stdout.split()
    if len(values) != 1:
        raise ValueError('Host GPU token must resolve to exactly one GPU')
    gpu_uuid(values[0])
    return values[0]


@contextmanager
def cancellation_signals():
    def interrupted(signum, _frame):
        raise RuntimeError(f'Interrupted by signal {signum}')
    previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def runtime_command(root, cfg, case, round_rel, rank, cpus):
    profile = cfg['profile']
    runtime, image = profile['runtime'], cfg['image']
    visible = os.environ.get('CUDA_VISIBLE_DEVICES', '')
    if not visible or ',' in visible:
        raise ValueError(f'Controller must receive one CUDA_VISIBLE_DEVICES token, got {visible!r}')
    env = dict(CUDA_VISIBLE_DEVICES=visible, PDHD_HOST=socket.gethostname(),
               PDHD_EXPECTED_GPU=os.environ.get('PDHD_EXPECTED_GPU', visible),
               OMP_NUM_THREADS=str(cfg['torch_threads']), MKL_NUM_THREADS=str(cfg['torch_threads']),
               OPENBLAS_NUM_THREADS=str(cfg['torch_threads']), OMP_DYNAMIC='FALSE',
               WIRECELL_PATH='/campaign/suite:'+cfg['wirecell_path']+
               (':/wct-data' if cfg['wirecell_data'] else ''))
    mask = ','.join(map(str, cpus))
    python = profile.get('container_python', 'python3')
    worker_cmd = [python, '/campaign/suite/pdhd.py', '_worker',
                  '--campaign', '/campaign', '--case', case['name'],
                  '--round', round_rel, '--rank', str(rank)]
    if runtime == 'apptainer':
        result = ['apptainer', 'exec', '--nv', '--cleanenv', '--bind', f'{root}:/campaign']
        if cfg['wirecell_data']:
            result += ['--bind', f'{cfg["wirecell_data"]}:/wct-data:ro']
        for key, value in env.items():
            result += ['--env', f'{key}={value}']
        return result + [image, 'taskset', '-c', mask] + worker_cmd
    result = [runtime, 'run', '--rm', '--cpuset-cpus', mask,
              '--cidfile', str(root/round_rel/f'rank{rank}'/'container.cid'),
              '--entrypoint', 'taskset', '--volume', f'{root}:/campaign', '--workdir', '/campaign']
    if runtime == 'podman-hpc':
        result += ['--gpu']
    else:
        result += ['--gpus', f'device={visible}']
        # CUDA UUID avoids index changes when the runtime filters devices.
        env['CUDA_VISIBLE_DEVICES'] = visible
        # Match host user permissions on bind-mounted outputs.
        result += ['--user', f'{os.getuid()}:{os.getgid()}']
    if profile.get('network'):
        result += ['--net', profile['network']]
    if cfg['wirecell_data']:
        result += ['--volume', f'{cfg["wirecell_data"]}:/wct-data:ro']
    for key, value in env.items():
        result += ['--env', f'{key}={value}']
    return result + [image, '-c', mask] + worker_cmd


def host_rank(args):
    root = args.campaign.resolve()
    cfg = read(root/'campaign.json')
    case = next(c for c in cfg['cases'] if c['name'] == args.case)
    rank = int(os.environ.get('PDHD_RANK', os.environ.get('SLURM_PROCID', '-1')))
    if rank not in range(len(case['ranks'])):
        raise ValueError('Invalid rank')
    directory = root/args.round/f'rank{rank}'
    directory.mkdir(exist_ok=False)
    cpus = sorted(os.sched_getaffinity(0))
    needed = len(case['ranks'][rank]['slots'])*case['cores_per_process']
    if len(physical_cpus()) < needed:
        raise ValueError(f'Rank {rank}: need {needed} physical cores in affinity mask {cpus}')
    token = os.environ.get('CUDA_VISIBLE_DEVICES', '')
    if not token or ',' in token:
        raise ValueError('Expected one assigned GPU token')
    expected_gpu = assigned_gpu(token)
    os.environ['CUDA_VISIBLE_DEVICES'] = expected_gpu
    os.environ['PDHD_EXPECTED_GPU'] = expected_gpu
    cmd = runtime_command(root, cfg, case, args.round, rank, cpus)
    save(directory/'launch.json', dict(command=cmd, host=socket.gethostname(), affinity=cpus,
                                      cuda_visible_devices=os.environ.get('CUDA_VISIBLE_DEVICES'),
                                      physical_cores={str(c): cpu_identity(c) for c in cpus},
                                      expected_gpu=expected_gpu,
                                      slurm_job=os.environ.get('SLURM_JOB_ID')))
    # Keep a host supervisor so cancellation also stops a detached OCI container.
    process = None
    try:
        with cancellation_signals():
            process = subprocess.Popen(cmd, start_new_session=True)
            rc = process.wait()
            if rc:
                raise RuntimeError(f'Container controller exited with status {rc}')
    finally:
        if process is not None:
            stop_runtime(process)
        cleanup_containers(root, cfg, args.round, rank=rank)


def cleanup_containers(root, cfg, round_rel, rank=None):
    """Stop only this campaign's containers on the current host; retain evidence."""
    runtime = cfg['profile']['runtime']
    if runtime not in ('podman-hpc', 'docker'):
        return
    directories = [root/round_rel/f'rank{rank}'] if rank is not None else sorted((root/round_rel).glob('rank*'))
    for directory in directories:
        launchfile, cidfile = directory/'launch.json', directory/'container.cid'
        if not launchfile.exists() or read(launchfile)['host'] != socket.gethostname():
            continue
        try:
            cid = cidfile.read_text().strip()
        except FileNotFoundError:
            continue
        if not cid:
            continue
        records = []
        for operation in ([runtime, 'stop', '--time', '5', cid],
                          [runtime, 'rm', '--force', cid]):
            try:
                result = subprocess.run(operation, capture_output=True, text=True, timeout=20)
                records.append(dict(command=operation, returncode=result.returncode,
                                    stdout=result.stdout, stderr=result.stderr))
            except subprocess.TimeoutExpired:
                records.append(dict(command=operation, error='cleanup command timed out'))
        listing = subprocess.run([runtime, 'ps', '-a', '--format', '{{.ID}}'],
                                 capture_output=True, text=True, timeout=20, check=True)
        remains = any(cid.startswith(value) for value in listing.stdout.split())
        save(directory/'cleanup.json', dict(container_id=cid, operations=records, removed=not remains))
        if remains:
            raise RuntimeError(f'Container cleanup failed: {cid}')


def remote_cleanup(root, cfg, case, round_rel):
    if cfg['profile']['runtime'] not in ('podman-hpc', 'docker'):
        return
    hosts = sorted({read(p)['host'] for p in (root/round_rel).glob('rank*/launch.json')})
    if not hosts:
        return
    # srun termination can kill supervisors before their finally blocks run.
    # A separate bounded cleanup step reaches the per-node OCI runtime storage.
    cmd = ['srun', '--overlap', '--nodes', str(len(hosts)), '--ntasks', str(len(hosts)),
           '--ntasks-per-node=1', '--cpus-per-task=1', '--gpus-per-task=0', '--cpu-bind=none',
           '--nodelist', ','.join(hosts), '--exact',
           sys.executable, str(root/'suite/pdhd.py'), '_cleanup',
           '--campaign', str(root), '--round', round_rel]
    with (root/round_rel/'cleanup.log').open('w') as stream:
        result = subprocess.run(cmd, stdout=stream, stderr=subprocess.STDOUT, timeout=150)
    if result.returncode:
        raise RuntimeError('Remote container cleanup failed; inspect cleanup.log')


def worker(args):
    import torch
    root = args.campaign
    cfg = read(root/'campaign.json')
    case = next(c for c in cfg['cases'] if c['name'] == args.case)
    directory = root/args.round/f'rank{args.rank}'
    slots = case['ranks'][args.rank]['slots']
    cores = case['cores_per_process']
    launch = read(directory/'launch.json')
    allowed = set(launch['affinity'])
    if not set(os.sched_getaffinity(0)) <= allowed:
        raise ValueError('Container affinity escaped host allocation')
    available = physical_cpus()
    if len(available) < len(slots)*cores:
        raise ValueError('Container affinity has too few physical cores')
    if torch.cuda.device_count() != 1:
        raise ValueError('Controller must see exactly one CUDA GPU')
    gpu = torch.cuda.get_device_properties(0)
    if not getattr(gpu, 'uuid', None):
        raise ValueError('PyTorch must expose the CUDA device UUID (use recent PyTorch)')
    if gpu_uuid(gpu.uuid) != gpu_uuid(launch['expected_gpu']):
        raise ValueError('Container GPU differs from host assignment')
    masks = {slot: available[i*cores:(i+1)*cores] for i, slot in enumerate(slots)}
    # Limit this controller as well; children inherit then narrow to their masks.
    os.sched_setaffinity(0, [cpu for mask in masks.values() for cpu in mask])
    version = subprocess.run(['wire-cell', '--version'], capture_output=True, text=True, timeout=30)
    if version.returncode:
        raise RuntimeError('wire-cell --version failed: '+version.stderr)
    meta = dict(host=os.environ['PDHD_HOST'], gpu_uuid=str(gpu.uuid), gpu_name=gpu.name,
                gpu_memory_bytes=gpu.total_memory, slots=slots, cpu_masks=masks,
                physical_cores={str(cpu): cpu_identity(cpu) for mask in masks.values() for cpu in mask},
                torch=torch.__version__, torch_cuda=torch.version.cuda,
                wirecell_version=version.stdout, image=cfg['image'])
    save(directory/'ready.json', meta)
    deadline = time.monotonic()+cfg['barrier_timeout']
    while not (root/args.round/'release.json').exists():
        if time.monotonic() > deadline:
            raise TimeoutError('Launch barrier timed out')
        time.sleep(.05)
    live, records = {}, []
    telemetry = None
    capture = (directory/'gpu.csv').open('w')

    def cleanup(*_):
        # Do not let a second termination signal interrupt child/container teardown.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        for item in live.values():
            stop(item['child'], grace=10)
            item['capture'].close()
        if telemetry is not None:
            telemetry.terminate()
            try:
                telemetry.wait(timeout=5)
            except subprocess.TimeoutExpired:
                telemetry.kill()
                telemetry.wait()
        capture.close()
    def interrupted(signum, _frame):
        raise RuntimeError(f'Worker interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    started = time.monotonic()
    try:
        try:
            telemetry = subprocess.Popen(['nvidia-smi', '-i', str(gpu.uuid),
                '--query-gpu=timestamp,uuid,utilization.gpu,memory.used,power.draw',
                '--format=csv,noheader,nounits', '-lms', str(cfg['sample_ms'])],
                stdout=capture, stderr=subprocess.STDOUT)
        except FileNotFoundError:
            capture.write('nvidia-smi unavailable; telemetry not collected\n')
        for slot in slots:
            cmd = command(case, slot, cfg, args.round)
            logfile = (root/args.round/f'slot{slot}.stdio.log').open('w')
            # taskset changes affinity before exec, avoiding unsafe preexec_fn.
            cmd = ['taskset', '-c', ','.join(map(str, masks[slot]))]+cmd
            child = subprocess.Popen(cmd, stdout=logfile, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            live[slot] = dict(child=child, capture=logfile, command=cmd,
                              start=time.monotonic(), start_epoch=time.time())
        while live:
            if time.monotonic()-started > cfg['timeout']:
                raise TimeoutError('Wire-Cell round exceeded timeout')
            for slot, item in list(live.items()):
                pid, status, usage = os.wait4(item['child'].pid, os.WNOHANG)
                if not pid:
                    continue
                rc = os.waitstatus_to_exitcode(status)
                item['child'].returncode = rc
                item['capture'].close()
                records.append(dict(slot=slot, command=item['command'], returncode=rc,
                                    elapsed_seconds=time.monotonic()-item['start'],
                                    start_epoch=item['start_epoch'], end_epoch=time.time(),
                                    cpu_seconds=usage.ru_utime+usage.ru_stime,
                                    max_rss_kib=usage.ru_maxrss))
                del live[slot]
                if rc:
                    raise RuntimeError(f'Wire-Cell slot {slot} failed ({rc}); see its logs')
            time.sleep(.02)
        save(directory/'wc-finished.json', dict(duration_seconds=time.monotonic()-started))
        for record in records:
            expected = partitions(cfg['events'], case['processes'])[record['slot']]
            for apa in range(4):
                validate(root/args.round/f'slot{record["slot"]}-tpc{apa}.npz', expected)
        save(directory/'result.json', dict(metadata=meta, processes=records, validated=True))
    finally:
        cleanup()
        save(directory/'processes.json', records)


def stop_runtime(process, grace=15):
    # Podman-HPC may leave persistent FUSE helpers in its process group.
    # Signal only the runtime client; recorded CIDs own container teardown.
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def stop(process, grace=15):
    # Always signal the group: a failed launcher may have surviving descendants.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    # Reap/kill any remaining group members even if the group leader exited.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def check_ready(root, case):
    metadata = [read(root/f'rank{r}/ready.json') for r in range(len(case['ranks']))]
    if len({gpu_uuid(m['gpu_uuid']) for m in metadata}) != len(metadata):
        raise ValueError('GPU assignments overlap between controllers')
    cpus, node_hosts = set(), {}
    for rank, m in enumerate(metadata):
        assignment = case['ranks'][rank]
        if sorted(m['slots']) != sorted(assignment['slots']):
            raise ValueError('Controller slots differ from plan')
        if set(map(int, m['cpu_masks'])) != set(assignment['slots']):
            raise ValueError('Controller masks differ from assigned slots')
        previous_host = node_hosts.setdefault(assignment['node'], m['host'])
        if previous_host != m['host']:
            raise ValueError('Planned node split across actual hosts')
        launch = read(root/f'rank{rank}/launch.json')
        if m['host'] != launch['host'] or gpu_uuid(m['gpu_uuid']) != gpu_uuid(launch['expected_gpu']):
            raise ValueError('Container host/GPU differs from host assignment')
        for mask in m['cpu_masks'].values():
            if len(mask) != case['cores_per_process']:
                raise ValueError('Incorrect physical core count per process')
            for cpu in mask:
                if cpu not in launch['affinity']:
                    raise ValueError('Container CPU outside host allocation')
                identity = m['physical_cores'][str(cpu)]
                if identity != launch['physical_cores'][str(cpu)]:
                    raise ValueError('Container CPU topology differs from host')
                key = (m['host'], *identity)
                if key in cpus:
                    raise ValueError('Physical CPU assignments overlap between processes')
                cpus.add(key)
    hosts = {m['host'] for m in metadata}
    if len(hosts) != case['nodes'] or len(set(node_hosts.values())) != case['nodes']:
        raise ValueError('Actual node count differs from plan')
    for host in hosts:
        if sum(m['host'] == host for m in metadata) != case['active_gpus_per_node']:
            raise ValueError('Uneven controller placement across nodes')
    return metadata


def assemble(root, round_dir, cfg, case):
    start = time.monotonic()
    output = round_dir/'events'
    output.mkdir()
    batches = partitions(cfg['events'], case['processes'])
    for slot, events in enumerate(batches):
        sources = [round_dir/f'slot{slot}-tpc{apa}.npz' for apa in range(4)]
        groups = [index(p) for p in sources]
        with zipfile.ZipFile(sources[0]) as a0, zipfile.ZipFile(sources[1]) as a1, \
                zipfile.ZipFile(sources[2]) as a2, zipfile.ZipFile(sources[3]) as a3:
            for event in events:
                target = output/f'event-{event:06d}.npz'
                with zipfile.ZipFile(target.with_suffix('.partial'), 'x', zipfile.ZIP_STORED) as dst:
                    for apa, archive in enumerate((a0, a1, a2, a3)):
                        for (kind, tag), name in groups[apa][event].items():
                            dst.writestr(f'{kind}_apa{apa}_{tag}_{event}.npy', archive.read(name))
                target.with_suffix('.partial').rename(target)
    if len(list(output.glob('*.npz'))) != len(cfg['events']):
        raise ValueError('Incomplete event assembly')
    return time.monotonic()-start


def launch_round(root, cfg, case, label, devices):
    rel = f'rounds/{case["name"]}/{label}'
    directory = root/rel
    directory.mkdir(parents=True, exist_ok=False)
    base = [sys.executable, str(root/'suite/pdhd.py'), '_host-rank',
            '--campaign', str(root), '--case', case['name'], '--round', rel]
    processes, streams = [], []
    outer = time.monotonic()
    failed = False
    try:
        if cfg['launcher'] == 'slurm':
            cmd = ['srun', '--nodes', str(case['nodes']), '--ntasks', str(case['gpus']),
                   '--ntasks-per-node', str(case['active_gpus_per_node']),
                   '--cpus-per-task', str(case['slurm_cpus_per_task']),
                   '--gpus-per-task=1', '--gpu-bind=single:1', '--cpu-bind=cores',
                   '--distribution=block:block', '--exact', '--kill-on-bad-exit=1'] + base
            save(directory/'launcher.json', dict(command=cmd))
            stream = (directory/'launcher.log').open('w')
            streams.append(stream)
            processes.append(subprocess.Popen(cmd, stdout=stream, stderr=subprocess.STDOUT,
                                               start_new_session=True))
        else:
            if case['nodes'] != 1 or len(devices) < case['gpus']:
                raise ValueError('Local launcher needs one node and enough --gpu-devices')
            cpus = physical_cpus()
            if len(cpus) < case['processes']*case['cores_per_process']:
                raise ValueError('Insufficient physical cores in local affinity mask')
            offset = 0
            for rank, assignment in enumerate(case['ranks']):
                size = len(assignment['slots'])*case['cores_per_process']
                mask = cpus[offset:offset+size]
                offset += size
                env = dict(os.environ, PDHD_RANK=str(rank), CUDA_VISIBLE_DEVICES=devices[rank])
                stream = (directory/f'controller{rank}.log').open('w')
                streams.append(stream)
                processes.append(subprocess.Popen(['taskset', '-c', ','.join(map(str, mask))]+base,
                    env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True))
        deadline = time.monotonic()+cfg['barrier_timeout']
        ready_files = [directory/f'rank{r}/ready.json' for r in range(case['gpus'])]
        finished_files = [directory/f'rank{r}/wc-finished.json' for r in range(case['gpus'])]
        while not all(p.exists() for p in ready_files):
            if any(p.poll() is not None for p in processes):
                raise RuntimeError('Controller exited before ready; inspect launcher/controller logs')
            if time.monotonic() > deadline:
                raise TimeoutError('Controller readiness timed out')
            time.sleep(.05)
        check_ready(directory, case)
        released = time.monotonic()
        save(directory/'release.json', dict(epoch=time.time()))
        while not all(p.exists() for p in finished_files):
            if any(p.poll() not in (None, 0) for p in processes):
                raise RuntimeError('Controller failed during processing; inspect logs')
            if time.monotonic()-released > cfg['timeout']+30:
                raise TimeoutError('Processing timed out')
            time.sleep(.02)
        workflow_wall = time.monotonic()-released
        # Validation may take substantial I/O time but remains bounded.
        deadline = time.monotonic()+cfg['timeout']
        while any(p.poll() is None for p in processes):
            if time.monotonic() > deadline:
                raise TimeoutError('Controller output validation timed out')
            time.sleep(.05)
        if any(p.returncode for p in processes):
            raise RuntimeError('Controller validation failed; round is not a result')
        step_wall = time.monotonic()-outer
        results = [read(directory/f'rank{r}/result.json') for r in range(case['gpus'])]
        if any(not r['validated'] for r in results):
            raise ValueError('Missing validation')
        records = [p for r in results for p in r['processes']]
        if sorted(p['slot'] for p in records) != list(range(case['processes'])):
            raise ValueError('Missing or duplicate process results')
        assembly = assemble(root, directory, cfg, case)
        finalized = time.monotonic()-outer
        count = len(cfg['events'])
        row = dict(case=case['name'], nodes=case['nodes'], gpus=case['gpus'],
                   processes=case['processes'], tbb_threads=case['threads'],
                   physical_cores=case['cores_per_process']*case['processes'],
                   round=label, warmup=label.startswith('warmup'), verified_events=count,
                   repeated_event_copies=cfg['dataset']['repeated_copies'],
                   workflow_wall_seconds=workflow_wall, step_wall_seconds=step_wall,
                   assembly_seconds=assembly, finalized_wall_seconds=finalized,
                   events_per_min=60*count/workflow_wall,
                   end_to_end_events_per_min=60*count/finalized,
                   cpu_seconds=sum(p['cpu_seconds'] for p in records))
        save(directory/'summary.json', row)
        return row
    except BaseException as error:
        failed = True
        save(directory/'failed.json', dict(error=str(error)))
        raise
    finally:
        for process in processes:
            stop(process, grace=60)
        try:
            if failed and cfg['launcher'] == 'slurm':
                remote_cleanup(root, cfg, case, rel)
        finally:
            for stream in streams:
                stream.close()


def summarize(root):
    cfg = read(root/'campaign.json')
    rows = [read(p) for p in sorted((root/'rounds').glob('*/*/summary.json'))]
    save(root/'rounds.json', rows)
    if rows:
        with (root/'rounds.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
    groups = []
    for case in cfg['cases']:
        selected = [r for r in rows if r['case'] == case['name'] and not r['warmup']]
        if not selected:
            continue
        rates = [r['events_per_min'] for r in selected]
        groups.append(dict(case=case['name'], nodes=case['nodes'], processes=case['processes'],
                           threads=case['threads'], gpus=case['gpus'], rounds=len(rates),
                           complete=len(rates) == cfg['repeats'],
                           mean_events_per_min=statistics.mean(rates),
                           stdev_events_per_min=statistics.stdev(rates) if len(rates)>1 else None,
                           mean_end_to_end_events_per_min=statistics.mean(
                               r['end_to_end_events_per_min'] for r in selected)))
    # Compare node scaling only at fixed threads and processes/GPU (constant CPU/GPU ratio).
    for row in groups:
        peers = [g for g in groups if g['complete'] and row['complete']
                 and g['threads'] == row['threads']
                 and g['processes']*row['gpus'] == row['processes']*g['gpus']]
        if peers:
            baseline = min(peers, key=lambda g: (g['gpus'], g['nodes']))
            speedup = row['mean_events_per_min']/baseline['mean_events_per_min']
            row.update(baseline=baseline['case'], throughput_speedup=speedup,
                       strong_scaling_efficiency=speedup/(row['gpus']/baseline['gpus']))
    save(root/'scaling-summary.json', dict(schema=1, scaling='strong: fixed N complete events',
                                          repeated_event_copies=cfg['dataset']['repeated_copies'],
                                          cases=groups))


def run(args):
    root = args.campaign.resolve()
    cfg = read(root/'campaign.json')
    selected = [c for c in cfg['cases'] if not args.cases or c['name'] in args.cases]
    if not selected or (args.cases and set(args.cases) != {c['name'] for c in selected}):
        raise ValueError('Unknown or empty case selection')
    if cfg['launcher'] == 'slurm':
        if not os.environ.get('SLURM_JOB_ID'):
            raise ValueError('Run inside an existing GPU Slurm allocation')
        if int(os.environ.get('SLURM_JOB_NUM_NODES', '0')) < max(c['nodes'] for c in selected):
            raise ValueError('Allocation has too few nodes')
    for name, expected in cfg['hashes'].items():
        if digest(root/name) != expected:
            raise ValueError(f'Campaign input changed: {name}')
    lock = root/'.running'
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    try:
        with cancellation_signals():
            run_cases(root, cfg, selected, args)
    finally:
        lock.unlink()


def run_cases(root, cfg, selected, args):
    for case in selected:
        for n in range(cfg['warmups']):
            launch_round(root, cfg, case, f'warmup{n+1}', args.gpu_devices)
    for n in range(cfg['repeats']):
        # Alternate traversal to reduce systematic order/drift bias.
        for case in selected if n % 2 == 0 else list(reversed(selected)):
            launch_round(root, cfg, case, f'measure{n+1}', args.gpu_devices)
    summarize(root)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('generate', help='Create N complete events from four matched APA ADC archives')
    p.add_argument('--adc', nargs=4, type=Path, required=True)
    p.add_argument('--events', type=positive, required=True)
    p.add_argument('--repeat', action='store_true', help='Allow explicitly labelled cyclic copies')
    p.add_argument('--output', type=Path, required=True)
    p = sub.add_parser('plan', help='Prepare an immutable campaign without running containers')
    p.add_argument('--dataset', type=Path, required=True)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--image', required=True, help='Image available on every node; digest recommended')
    p.add_argument('--profile', choices=('perlmutter', 'generic'), default='perlmutter')
    p.add_argument('--launcher', choices=('slurm', 'local'), default='slurm')
    p.add_argument('--runtime', choices=('podman-hpc', 'docker', 'apptainer'))
    p.add_argument('--container-python', help='Python executable inside the container with Torch and NumPy')
    p.add_argument('--network', help='Override container network; empty string uses runtime default')
    p.add_argument('--nodes', type=positive, nargs='+', required=True)
    p.add_argument('--processes', type=positive, nargs='+', required=True,
                   help='Total concurrent WC processes across all nodes')
    p.add_argument('--threads', type=positive, nargs='+', required=True,
                   help='TbbDataFlowGraph.max_threads per WC process')
    p.add_argument('--cores-per-process', type=positive)
    p.add_argument('--gpus-per-node', type=positive)
    p.add_argument('--physical-cores-per-node', type=positive)
    p.add_argument('--slurm-cpus-per-core', type=positive)
    p.add_argument('--torch-threads', type=positive, default=1)
    p.add_argument('--warmups', type=int, default=1)
    p.add_argument('--repeats', type=positive, default=5)
    p.add_argument('--timeout', type=positive, default=1800)
    p.add_argument('--barrier-timeout', type=positive, default=300)
    p.add_argument('--sample-ms', type=positive, default=500)
    p.add_argument('--wirecell-data', type=Path, help='Optional external response/geometry data directory')
    p.add_argument('--wirecell-path', default='/opt/wirecell-view/share/wirecell:'
                   '/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg')
    p = sub.add_parser('run')
    p.add_argument('--campaign', type=Path, required=True)
    p.add_argument('--cases', nargs='+')
    p.add_argument('--gpu-devices', nargs='+', default=['0', '1', '2', '3'],
                   help='Local launcher GPU tokens, preferably UUIDs')
    p = sub.add_parser('summarize')
    p.add_argument('--campaign', type=Path, required=True)
    p = sub.add_parser('_cleanup')
    p.add_argument('--campaign', type=Path, required=True)
    p.add_argument('--round', required=True)
    for action in ('_host-rank', '_worker'):
        p = sub.add_parser(action)
        p.add_argument('--campaign', type=Path, required=True)
        p.add_argument('--case', required=True)
        p.add_argument('--round', required=True)
        if action == '_worker':
            p.add_argument('--rank', type=int, required=True)
    args = parser.parse_args()
    if getattr(args, 'warmups', 0) < 0:
        parser.error('--warmups cannot be negative')
    try:
        if args.action == 'generate':
            generate(args)
        elif args.action == 'plan':
            plan(args)
        elif args.action == 'run':
            run(args)
        elif args.action == 'summarize':
            summarize(args.campaign)
        elif args.action == '_cleanup':
            cleanup_containers(args.campaign, read(args.campaign/'campaign.json'), args.round)
        elif args.action == '_host-rank':
            host_rank(args)
        else:
            worker(args)
    except (ValueError, OSError, RuntimeError, TimeoutError, zipfile.BadZipFile) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
