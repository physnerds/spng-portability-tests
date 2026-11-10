#!/usr/bin/env python3
"""One-node interactive scaling with mandatory, host-side GPU telemetry."""
import argparse
import csv
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
import threading
import time


def uuid(value):
    return value.strip().lower().removeprefix('gpu-')


def query(selector=None):
    cmd = ['nvidia-smi']
    if selector:
        cmd += ['-i', selector]
    cmd += ['--query-gpu=uuid,utilization.gpu,memory.used,power.draw',
            '--format=csv,noheader,nounits']
    before = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=True)
    after = time.time()
    rows = []
    for fields in csv.reader(result.stdout.splitlines()):
        if len(fields) != 4 or not fields[0].strip().startswith('GPU-'):
            raise RuntimeError('Invalid GPU telemetry: '+result.stdout)
        values = [float(v.strip()) for v in fields[1:]]
        if not all(math.isfinite(v) and v >= 0 for v in values) or values[0] > 100:
            raise RuntimeError('Invalid GPU telemetry values: '+repr(fields))
        rows.append(dict(epoch=(before+after)/2, query_seconds=after-before,
                         uuid=fields[0].strip(), utilization_pct=values[0],
                         memory_mib=values[1], power_w=values[2]))
    if not rows or len({uuid(r['uuid']) for r in rows}) != len(rows):
        raise RuntimeError('Empty or duplicate GPU telemetry')
    return rows


def write_csv(path, rows):
    if not rows:
        raise RuntimeError('No rows for '+str(path))
    with path.open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def summarize(campaign, samples, output, interval):
    results = []
    summaries = json.loads((campaign/'rounds.json').read_text())
    measured = [r for r in summaries if not r['warmup']]
    cfg = json.loads((campaign/'campaign.json').read_text())
    if len(measured) != len(cfg['cases'])*cfg['repeats']:
        raise RuntimeError('Incomplete measured campaign')
    for row in measured:
        directory = campaign/'rounds'/row['case']/row['round']
        for path in sorted(directory.glob('rank*/result.json')):
            result = json.loads(path.read_text())
            if not result['validated'] or len(result['processes']) != 1:
                raise RuntimeError('Expected one validated process per GPU')
            process = result['processes'][0]
            start, end = process['start_epoch'], process['end_epoch']
            selected = [s for s in samples if uuid(s['uuid']) == uuid(result['metadata']['gpu_uuid'])
                        and start <= s['epoch'] <= end]
            stamps = [start]+[s['epoch'] for s in selected]+[end]
            max_gap = max(b-a for a, b in zip(stamps, stamps[1:]))
            if len(selected) < 2 or max_gap > max(2., interval*4):
                raise RuntimeError(f'Missing/sparse telemetry: {path}; samples={len(selected)}, max gap={max_gap:.2f}s')
            mean = lambda key: statistics.mean(s[key] for s in selected)
            results.append(dict(case=row['case'], round=row['round'], rank=path.parent.name,
                gpu_uuid=result['metadata']['gpu_uuid'], samples=len(selected), max_gap_s=max_gap,
                gpu_util_mean_pct=mean('utilization_pct'),
                gpu_util_max_pct=max(s['utilization_pct'] for s in selected),
                gpu_memory_max_mib=max(s['memory_mib'] for s in selected),
                gpu_power_mean_w=mean('power_w'), gpu_power_max_w=max(s['power_w'] for s in selected),
                cpu_seconds=process['cpu_seconds'],
                cpu_capacity_pct=100*process['cpu_seconds']/(4*process['elapsed_seconds']),
                max_rss_gib=process['max_rss_kib']/1048576))
    write_csv(output/'gpu-process-windows.csv', results)
    scaling = json.loads((campaign/'scaling-summary.json').read_text())['cases']
    lines = ['# Interactive one-node scaling and GPU telemetry', '',
        f"Launcher: {cfg['launcher']} inside the existing one-node Slurm allocation.", '',
        'GPU samples come from host nvidia-smi, matched by UUID to each process execution window.',
        'GPU means are arithmetic sample means per process/round, then averaged equally across measured processes/rounds.',
        'Power and memory are device-wide readings; memory peaks below are per-device, not sums. Warmups are excluded.',
        'GPU utilization is the nvidia-smi busy percentage, not kernel occupancy. CPU utilization uses four assigned cores/process.',
        'Sampling is approximately periodic; raw query durations and sample gaps are retained. No energy estimate is made.', '',
        '| Case | P | GPUs | Physical cores | TBB/process | Events/min ± SD | E2E events/min | Speedup | Scaling efficiency | GPU mean busy % | GPU peak busy % | Peak GPU MiB | Mean W/GPU | Peak W/GPU | CPU capacity % | Peak RSS/process GiB | Samples |',
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
    for row in scaling:
        selected = [r for r in results if r['case'] == row['case']]
        if len(selected) != cfg['repeats']*row['gpus']:
            raise RuntimeError('Missing per-rank results for '+row['case'])
        avg = lambda key: statistics.mean(r[key] for r in selected)
        peak = lambda key: max(r[key] for r in selected)
        values = [row['case'],row['processes'],row['gpus'],4*row['processes'],row['threads'],
            f"{row['mean_events_per_min']:.2f} ± {row['stdev_events_per_min'] or 0:.2f}",
            f"{row['mean_end_to_end_events_per_min']:.2f}",f"{row['throughput_speedup']:.3f}",
            f"{100*row['strong_scaling_efficiency']:.1f}%",f"{avg('gpu_util_mean_pct'):.1f}",
            f"{peak('gpu_util_max_pct'):.1f}",f"{peak('gpu_memory_max_mib'):.0f}",
            f"{avg('gpu_power_mean_w'):.1f}",f"{peak('gpu_power_max_w'):.1f}",
            f"{avg('cpu_capacity_pct'):.1f}",f"{peak('max_rss_gib'):.2f}",sum(r['samples'] for r in selected)]
        lines.append('| '+' | '.join(map(str, values))+' |')
    lines += ['', 'Speedup = mean processing rate / one-process rate at the same TBB setting.',
              'Scaling efficiency = speedup / process count × 100%. These differ from measured hardware utilization.',
              'See campaign/rounds.json for timing, validation and assembly; gpu-process-windows.csv for per-rank measurements.', '']
    (output/'telemetry-summary.md').write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='Fresh evidence directory')
    parser.add_argument('--image', default='docker.io/abashyal/wirecell-spng:cuda80')
    parser.add_argument('--repeats', type=int, default=2)
    parser.add_argument('--sample-ms', type=int, default=500)
    parser.add_argument('--launcher', choices=('local', 'slurm'), default='local',
                        help='Default: local controllers inside the existing Slurm compute step')
    args = parser.parse_args()
    if args.repeats < 2 or args.sample_ms < 100:
        parser.error('Use at least two repeats and sample-ms >=100')
    if not os.environ.get('SLURM_JOB_ID') or int(os.environ.get('SLURM_JOB_NUM_NODES', os.environ.get('SLURM_NNODES', '0'))) != 1:
        parser.error('Run inside a one-node GPU compute allocation')
    for name in ('nvidia-smi','podman-hpc','srun'):
        if not shutil.which(name):
            parser.error('Missing command: '+name)
    project = Path(__file__).resolve().parents[3]
    dataset = args.dataset.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    # Host CUDA tokens identify allocated devices; do not use container-local ordinals.
    initial = query(os.environ.get('CUDA_VISIBLE_DEVICES'))
    if len(initial) != 4:
        raise RuntimeError('This test requires all four GPUs on one node')
    affinity = sorted(os.sched_getaffinity(0))
    physical = set()
    for cpu in affinity:
        topology = Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
        physical.add(((topology/'physical_package_id').read_text().strip(),
                      (topology/'core_id').read_text().strip()))
    if args.launcher == 'local' and len(physical) < 16:
        raise RuntimeError(f'Local launcher needs 16 physical cores; shell affinity contains {len(physical)}')
    selector = ','.join(r['uuid'] for r in initial)
    expected = {uuid(r['uuid']) for r in initial}
    (output/'preflight.json').write_text(json.dumps(dict(host=socket.gethostname(),
        job=os.environ['SLURM_JOB_ID'], samples=initial, argv=sys.argv,
        launcher=args.launcher, affinity=affinity, physical_cores_in_affinity=len(physical),
        slurm_environment={k:v for k,v in os.environ.items() if k.startswith('SLURM_')}), indent=2)+'\n')
    samples, errors = [], []
    done = threading.Event()
    interval = args.sample_ms/1000

    def monitor():
        with (output/'host-gpu.csv').open('w', buffering=1) as stream:
            writer = csv.DictWriter(stream, fieldnames=list(initial[0]))
            writer.writeheader()
            try:
                while not done.is_set():
                    tick = time.monotonic()
                    current = query(selector)
                    if {uuid(r['uuid']) for r in current} != expected:
                        raise RuntimeError('Host GPU set changed')
                    samples.extend(current)
                    writer.writerows(current)
                    done.wait(max(0, interval-(time.monotonic()-tick)))
            except Exception as error:
                errors.append(repr(error))
                (output/'telemetry-error.json').write_text(json.dumps(errors)+'\n')

    campaign = output/'campaign'
    cmd = ['podman-hpc','run','--rm','--gpu','--net=slirp4netns',
        '--entrypoint','/usr/bin/python3','--volume',f'{project}:{project}:ro',
        '--volume',f'{dataset}:{dataset}:ro','--volume',f'{output}:{output}',
        '--workdir',str(project),args.image,'scaling/pdhd/pdhd.py','plan',
        '--dataset',str(dataset),'--model',str(project/'infiles/legacy_roiuniter_090326.ts'),
        '--image',args.image,'--profile','perlmutter','--launcher',args.launcher,
        '--nodes','1','--processes','1','2','4','--threads','1','2','4',
        '--cores-per-process','4','--gpus-per-node','4','--warmups','1',
        '--repeats',str(args.repeats),'--timeout','600','--barrier-timeout','180',
        '--wirecell-data',str(project/'wire-cell-data'),'--output',str(campaign)]
    print('Preflight passed: four GPUs return numeric utilization, memory and power.', flush=True)
    with (output/'plan.log').open('w') as stream:
        planning = subprocess.run(cmd, stdout=stream, stderr=subprocess.STDOUT)
    if planning.returncode:
        tail = '\n'.join((output/'plan.log').read_text().splitlines()[-15:])
        raise RuntimeError(f'Planning container failed ({planning.returncode}); '
                           +str(output/'plan.log')+'\n'+tail)
    env = dict(os.environ)
    # The enclosing srun --pty shell can export gpu:per_task:4. A sibling
    # one-GPU/controller step must not inherit that four-GPU task binding.
    # Preserve allocation identity and CUDA visibility; the runner explicitly
    # sets --gpus-per-task and --gpu-bind for each measured step and cleanup.
    removed = {key: env.pop(key) for key in (
        'SLURM_TRES_BIND', 'SLURM_TRES_PER_TASK',
        'SLURM_GPU_BIND', 'SLURM_GPUS_PER_TASK') if key in env}
    (output/'step-environment.json').write_text(json.dumps(
        dict(removed_inherited_settings=removed), indent=2)+'\n')
    step = env.get('SLURM_STEP_ID')
    if args.launcher == 'slurm' and step and step not in ('batch','extern'):
        shim = output/'bin'; shim.mkdir()
        (shim/'srun').write_text('#!/bin/bash\nexec '+shlex.quote(shutil.which('srun'))+' --overlap "$@"\n')
        (shim/'srun').chmod(0o700)
        env['PATH'] = str(shim)+os.pathsep+env['PATH']
    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    coordinator = None
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f'Signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    print(f'Running nine cases with {args.launcher} controllers; live coordinator log: '+str(output/'run.log'), flush=True)
    try:
        with (output/'run.log').open('w') as stream:
            coordinator = subprocess.Popen([sys.executable,str(campaign/'suite/pdhd.py'),
                'run','--campaign',str(campaign), '--gpu-devices',
                *[r['uuid'] for r in initial]], env=env, stdout=stream, stderr=subprocess.STDOUT)
            while coordinator.poll() is None:
                if errors:
                    raise RuntimeError('Telemetry stopped: '+errors[0])
                done.wait(.25)
            if coordinator.returncode:
                stream.flush()
                tail = '\n'.join((output/'run.log').read_text().splitlines()[-15:])
                raise RuntimeError('Campaign failed; '+str(output/'run.log')+'\n'+tail)
    finally:
        if coordinator is not None and coordinator.poll() is None:
            coordinator.terminate()
            try:
                coordinator.wait(timeout=240)
            except subprocess.TimeoutExpired:
                coordinator.kill(); coordinator.wait()
                (output/'cleanup-incomplete.txt').write_text('Coordinator cleanup timed out; inspect campaign containers.\n')
        done.set()
        thread.join(timeout=15)
    if errors or thread.is_alive():
        raise RuntimeError('Telemetry collection failed; inspect telemetry-error.json')
    summarize(campaign, samples, output, interval)
    print('PASS: scaling and GPU telemetry; '+str(output/'telemetry-summary.md'))


if __name__ == '__main__':
    main()
