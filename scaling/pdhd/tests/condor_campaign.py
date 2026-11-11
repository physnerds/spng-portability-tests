#!/usr/bin/env python3
"""Run and analyze a one-node PDHD campaign in an HTCondor GPU slot."""

import argparse
import csv
import json
import math
import os
from pathlib import Path
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time


def canonical_uuid(value):
    return value.strip().lower().removeprefix('gpu-').replace('-', '')


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def write_csv(path, rows):
    if not rows:
        raise RuntimeError(f'No rows available for {path}')
    with Path(path).open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def resolve_gpu_tokens(tokens, devices):
    """Resolve HTCondor short UUIDs, full UUIDs, or indices uniquely."""
    resolved = []
    for token in tokens:
        key = token.strip().lower()
        matches = [device for device in devices
                   if str(device['index']) == token.strip()
                   or device['uuid'].lower() == key
                   or device['uuid'].lower().startswith(key)]
        if len(matches) != 1:
            raise ValueError(f'GPU token {token!r} matched {matches!r}')
        resolved.append(dict(token=token, **matches[0]))
    identities = [canonical_uuid(item['uuid']) for item in resolved]
    if len(set(identities)) != len(identities):
        raise ValueError('HTCondor GPU assignments are not unique')
    return resolved


def discover_gpus():
    result = subprocess.run(
        ['nvidia-smi', '--query-gpu=index,uuid', '--format=csv,noheader'],
        capture_output=True, text=True, timeout=30, check=True)
    devices = []
    for row in csv.reader(result.stdout.splitlines()):
        if len(row) != 2 or not row[1].strip().startswith('GPU-'):
            raise RuntimeError(f'Invalid nvidia-smi GPU row: {row!r}')
        devices.append(dict(index=row[0].strip(), uuid=row[1].strip()))
    if not devices:
        raise RuntimeError('nvidia-smi reported no GPUs')
    return devices


def physical_core_count():
    cores = set()
    for cpu in os.sched_getaffinity(0):
        topology = Path(f'/sys/devices/system/cpu/cpu{cpu}/topology')
        cores.add(((topology/'physical_package_id').read_text().strip(),
                   (topology/'core_id').read_text().strip()))
    return len(cores), sorted(os.sched_getaffinity(0))


def query_gpu(uuid):
    before = time.time()
    result = subprocess.run([
        'nvidia-smi', '-i', uuid,
        '--query-gpu=uuid,utilization.gpu,memory.used,power.draw',
        '--format=csv,noheader,nounits'], capture_output=True, text=True,
        timeout=10, check=True)
    after = time.time()
    rows = list(csv.reader(result.stdout.splitlines()))
    if len(rows) != 1 or len(rows[0]) != 4:
        raise RuntimeError(f'Invalid telemetry for {uuid}: {result.stdout!r}')
    values = [float(value.strip()) for value in rows[0][1:]]
    if (not all(math.isfinite(value) and value >= 0 for value in values)
            or values[0] > 100):
        raise RuntimeError(f'Invalid telemetry values for {uuid}: {rows[0]!r}')
    return dict(epoch=(before+after)/2, query_seconds=after-before,
                uuid=rows[0][0].strip(), utilization_pct=values[0],
                memory_mib=values[1], power_w=values[2])


class Telemetry:
    def __init__(self, output, uuids, sample_ms):
        self.output = Path(output)
        self.uuids = list(uuids)
        self.interval = sample_ms/1000
        self.samples = []
        self.error = None
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._monitor, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.done.set()
        self.thread.join(timeout=30)
        if self.thread.is_alive():
            raise RuntimeError('GPU telemetry thread did not stop')
        if self.error:
            raise RuntimeError(f'GPU telemetry failed: {self.error}')
        if not self.samples:
            raise RuntimeError('GPU telemetry produced no samples')

    def _monitor(self):
        path = self.output/'host-gpu.csv'
        fields = ['epoch', 'query_seconds', 'uuid', 'utilization_pct',
                  'memory_mib', 'power_w']
        try:
            with path.open('w', newline='', buffering=1) as stream:
                writer = csv.DictWriter(stream, fieldnames=fields)
                writer.writeheader()
                while not self.done.is_set():
                    tick = time.monotonic()
                    current = [query_gpu(uuid) for uuid in self.uuids]
                    identities = {canonical_uuid(row['uuid']) for row in current}
                    if identities != {canonical_uuid(uuid) for uuid in self.uuids}:
                        raise RuntimeError('Telemetry GPU set differs from allocation')
                    self.samples.extend(current)
                    writer.writerows(current)
                    self.done.wait(max(0, self.interval-(time.monotonic()-tick)))
        except BaseException as error:
            self.error = repr(error)
            write_json(self.output/'telemetry-error.json', dict(error=self.error))
            self.done.set()


def mean(rows, key):
    return statistics.mean(row[key] for row in rows)


def sample_sd(values):
    return statistics.stdev(values) if len(values) > 1 else None


def analyze(campaign, samples, output, sample_ms, study):
    """Create process-window telemetry, case metrics, and a Markdown report."""
    campaign, output = Path(campaign), Path(output)
    config = read_json(campaign/'campaign.json')
    rounds = read_json(campaign/'rounds.json')
    measured = [row for row in rounds if not row['warmup']]
    expected = len(config['cases'])*config['repeats']
    if len(measured) != expected:
        raise RuntimeError(f'Incomplete campaign: {len(measured)}/{expected} measured rounds')

    windows = []
    round_processes = {}
    interval = sample_ms/1000
    for summary in measured:
        directory = campaign/'rounds'/summary['case']/summary['round']
        records = []
        for result_path in sorted(directory.glob('rank*/result.json')):
            result = read_json(result_path)
            if not result.get('validated'):
                raise RuntimeError(f'Unvalidated result: {result_path}')
            uuid = result['metadata']['gpu_uuid']
            for process in result['processes']:
                start, end = process['start_epoch'], process['end_epoch']
                selected = [sample for sample in samples
                            if canonical_uuid(sample['uuid']) == canonical_uuid(uuid)
                            and start <= sample['epoch'] <= end]
                stamps = [start]+[sample['epoch'] for sample in selected]+[end]
                max_gap = max(b-a for a, b in zip(stamps, stamps[1:]))
                if len(selected) < 2 or max_gap > max(2.0, interval*4):
                    raise RuntimeError(f'Missing/sparse telemetry: {result_path}; '
                                       f'slot={process["slot"]}, samples={len(selected)}, '
                                       f'max_gap={max_gap:.3f}s')
                row = dict(case=summary['case'], round=summary['round'],
                           rank=result_path.parent.name, slot=process['slot'],
                           gpu_uuid=uuid, samples=len(selected), max_gap_s=max_gap,
                           gpu_util_mean_pct=mean(selected, 'utilization_pct'),
                           gpu_util_max_pct=max(x['utilization_pct'] for x in selected),
                           gpu_memory_max_mib=max(x['memory_mib'] for x in selected),
                           gpu_power_mean_w=mean(selected, 'power_w'),
                           gpu_power_max_w=max(x['power_w'] for x in selected),
                           elapsed_seconds=process['elapsed_seconds'],
                           cpu_seconds=process['cpu_seconds'],
                           cpu_capacity_pct=100*process['cpu_seconds']
                           /(summary['physical_cores']/summary['processes']
                             * process['elapsed_seconds']),
                           max_rss_gib=process['max_rss_kib']/1048576)
                windows.append(row)
                records.append(row)
        if len(records) != summary['processes']:
            raise RuntimeError(f'Expected {summary["processes"]} processes in '
                               f'{summary["case"]}/{summary["round"]}, got {len(records)}')
        round_processes[(summary['case'], summary['round'])] = records
    write_csv(output/'gpu-process-windows.csv', windows)

    cases = []
    for case in config['cases']:
        selected_rounds = [row for row in measured if row['case'] == case['name']]
        selected_windows = [row for row in windows if row['case'] == case['name']]
        rates = [row['events_per_min'] for row in selected_rounds]
        e2e_rates = [row['end_to_end_events_per_min'] for row in selected_rounds]
        by_round = [round_processes[(row['case'], row['round'])]
                    for row in selected_rounds]
        processing = [row['workflow_wall_seconds'] for row in selected_rounds]
        finalized = [row['finalized_wall_seconds'] for row in selected_rounds]
        cases.append(dict(
            case=case['name'], processes=case['processes'], gpus=case['gpus'],
            assigned_physical_cores=case['processes']*case['cores_per_process'],
            tbb_threads=case['threads'], rounds=len(selected_rounds),
            events_per_min=statistics.mean(rates), events_per_min_sd=sample_sd(rates),
            coefficient_variation_pct=(100*sample_sd(rates)/statistics.mean(rates)
                                       if len(rates) > 1 else None),
            e2e_events_per_min=statistics.mean(e2e_rates),
            gpu_mean_busy_pct=mean(selected_windows, 'gpu_util_mean_pct'),
            gpu_peak_busy_pct=max(row['gpu_util_max_pct'] for row in selected_windows),
            gpu_peak_mib_per_device=max(row['gpu_memory_max_mib'] for row in selected_windows),
            mean_w_per_active_gpu=mean(selected_windows, 'gpu_power_mean_w'),
            peak_w_per_device=max(row['gpu_power_max_w'] for row in selected_windows),
            cpu_capacity_pct=mean(selected_windows, 'cpu_capacity_pct'),
            busy_core_equivalents=statistics.mean(
                sum(item['cpu_seconds'] for item in records)/round_row['workflow_wall_seconds']
                for records, round_row in zip(by_round, selected_rounds)),
            cpu_seconds_per_round=statistics.mean(
                sum(item['cpu_seconds'] for item in records) for records in by_round),
            peak_rss_per_process_gib=max(row['max_rss_gib'] for row in selected_windows),
            mean_sum_process_peak_rss_gib=statistics.mean(
                sum(item['max_rss_gib'] for item in records) for records in by_round),
            measured_samples=sum(row['samples'] for row in selected_windows),
            largest_sample_gap_s=max(row['max_gap_s'] for row in selected_windows),
            processing_seconds=statistics.mean(processing),
            step_seconds=mean(selected_rounds, 'step_wall_seconds'),
            assembly_seconds=mean(selected_rounds, 'assembly_seconds'),
            finalized_e2e_seconds=statistics.mean(finalized),
            other_step_seconds=statistics.mean(
                row['step_wall_seconds']-row['workflow_wall_seconds']
                for row in selected_rounds),
            processing_share_pct=statistics.mean(
                100*work/end for work, end in zip(processing, finalized)),
            events_per_min_per_gpu=statistics.mean(rates)/case['gpus'],
            events_per_min_per_assigned_core=statistics.mean(rates)
            /(case['processes']*case['cores_per_process'])))

    for row in cases:
        baseline = next(item for item in cases
                        if item['processes'] == 1 and item['tbb_threads'] == row['tbb_threads'])
        row['process_speedup'] = row['events_per_min']/baseline['events_per_min']
        row['e2e_speedup'] = row['e2e_events_per_min']/baseline['e2e_events_per_min']
        row['scaling_efficiency_pct'] = (100*row['process_speedup']/row['processes']
            if study == 'multi-gpu' and row['gpus'] == row['processes'] else None)
    write_csv(output/'case-metrics.csv', cases)

    raw_gaps = []
    by_uuid = {}
    for sample in samples:
        by_uuid.setdefault(canonical_uuid(sample['uuid']), []).append(sample['epoch'])
    for stamps in by_uuid.values():
        stamps.sort()
        raw_gaps.extend(b-a for a, b in zip(stamps, stamps[1:]))
    coverage = dict(study=study, raw_samples=len(samples),
                    selected_process_window_samples=sum(row['samples'] for row in windows),
                    requested_sample_ms=sample_ms,
                    mean_query_seconds=statistics.mean(row['query_seconds'] for row in samples),
                    largest_raw_same_gpu_gap_s=max(raw_gaps) if raw_gaps else None,
                    measured_process_windows=len(windows), warmups=config['warmups'],
                    measured_repeats=config['repeats'], repeated_event_copies=
                    config['dataset']['repeated_copies'])
    write_json(output/'telemetry-coverage.json', coverage)

    def value(number, digits=2):
        return 'N/A' if number is None else f'{number:.{digits}f}'
    lines = ['# HTCondor PDHD scaling and telemetry', '',
             f'Study type: **{study}**. Warmups are excluded from all tables.', '',
             'GPU samples are selected by full UUID and process timestamps. '
             'Utilization is device busy time, not FLOPS or kernel occupancy.', '',
             '## Throughput and scaling', '',
             '| Case | P | GPUs | Cores | TBB | Events/min ± SD | E2E events/min | Process speedup | Scaling efficiency | E2E speedup | CV |',
             '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for row in cases:
        lines.append('| {case} | {processes} | {gpus} | {assigned_physical_cores} | '
                     '{tbb_threads} | {rate} ± {sd} | {e2e} | {speedup}× | {eff} | '
                     '{e2es}× | {cv}% |'.format(
                         **row, rate=value(row['events_per_min'], 3),
                         sd=value(row['events_per_min_sd'], 3),
                         e2e=value(row['e2e_events_per_min'], 3),
                         speedup=value(row['process_speedup'], 3),
                         eff=('N/A' if row['scaling_efficiency_pct'] is None else
                              value(row['scaling_efficiency_pct'], 1)+'%'),
                         e2es=value(row['e2e_speedup'], 3),
                         cv=value(row['coefficient_variation_pct'], 2)))
    lines += ['', '## GPU, CPU, and memory', '',
              '| Case | GPU mean % | GPU peak % | Peak MiB/device | Mean W/GPU | Peak W/device | CPU capacity % | Busy cores | CPU s/round | Peak RSS/process GiB | Samples | Max gap s |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for row in cases:
        lines.append('| {case} | {gpu_mean_busy_pct:.1f} | {gpu_peak_busy_pct:.1f} | '
                     '{gpu_peak_mib_per_device:.0f} | {mean_w_per_active_gpu:.1f} | '
                     '{peak_w_per_device:.1f} | {cpu_capacity_pct:.1f} | '
                     '{busy_core_equivalents:.2f} | {cpu_seconds_per_round:.2f} | '
                     '{peak_rss_per_process_gib:.2f} | {measured_samples} | '
                     '{largest_sample_gap_s:.3f} |'.format(**row))
    lines += ['', '## Timing and resource productivity', '',
              '| Case | Processing s | Step s | Assembly s | Finalized s | Other step s | Processing share | Rate/GPU | Rate/core | Sum process RSS GiB |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for row in cases:
        lines.append('| {case} | {processing_seconds:.2f} | {step_seconds:.2f} | '
                     '{assembly_seconds:.2f} | {finalized_e2e_seconds:.2f} | '
                     '{other_step_seconds:.2f} | {processing_share_pct:.1f}% | '
                     '{events_per_min_per_gpu:.2f} | '
                     '{events_per_min_per_assigned_core:.2f} | '
                     '{mean_sum_process_peak_rss_gib:.2f} |'.format(**row))
    if study == 'one-gpu-packing':
        lines += ['', 'Scaling efficiency is intentionally N/A: all P values share one '
                  'GPU, so this is a packing/concurrency study rather than multi-GPU scaling.']
    lines += ['', f'Raw samples: {coverage["raw_samples"]}; selected process-window '
              f'samples: {coverage["selected_process_window_samples"]}; requested '
              f'interval: {sample_ms} ms.', '']
    (output/'telemetry-summary.md').write_text('\n'.join(lines))


def run(args):
    project = args.project.resolve(strict=True)
    dataset = args.dataset.resolve(strict=True)
    image = args.image.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    for command in ('python3', 'apptainer', 'nvidia-smi', 'taskset', 'sha256sum'):
        if not shutil.which(command):
            raise RuntimeError(f'Missing command: {command}')
    tokens = [item.strip() for item in os.environ.get('CUDA_VISIBLE_DEVICES', '').split(',')
              if item.strip()]
    if len(tokens) != args.gpus:
        raise RuntimeError(f'Expected {args.gpus} CUDA_VISIBLE_DEVICES tokens, got {tokens!r}')
    resolved = resolve_gpu_tokens(tokens, discover_gpus())
    uuids = [item['uuid'] for item in resolved]
    preflight_samples = [query_gpu(uuid) for uuid in uuids]
    physical, affinity = physical_core_count()
    needed = max(args.processes)*args.cores_per_process
    if physical < needed:
        raise RuntimeError(f'Need {needed} physical cores; affinity has {physical}')
    nvidia_list = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True,
                                 timeout=30, check=True).stdout
    (output/'nvidia-smi-L.txt').write_text(nvidia_list)
    write_json(output/'preflight.json', dict(
        host=socket.gethostname(), argv=sys.argv, study=args.study,
        condor_job_id=os.environ.get('PDHD_CONDOR_JOB_ID'),
        requested_test_resources=dict(gpus=args.gpus,
                                      physical_cpu_cores_needed=needed),
        condor_environment={key: value for key, value in os.environ.items()
                            if key.startswith(('_CONDOR', 'CONDOR'))},
        cuda_visible_devices=os.environ.get('CUDA_VISIBLE_DEVICES'),
        resolved_gpus=resolved, samples=preflight_samples, affinity=affinity,
        physical_cores_in_affinity=physical, image=str(image)))
    checksum = subprocess.run(['sha256sum', str(image)], capture_output=True, text=True,
                              timeout=300, check=True).stdout
    (output/'image.sha256').write_text(checksum)

    campaign = output/'campaign'
    plan = ['apptainer', 'exec', '--cleanenv', '--nv',
        '--bind', f'{project}:{project}:ro', '--bind', f'{dataset}:{dataset}:ro',
        '--bind', f'{output}:{output}', str(image), '/usr/bin/python3',
        str(project/'scaling/pdhd/pdhd.py'), 'plan', '--dataset', str(dataset),
        '--model', str(project/'infiles/legacy_roiuniter_090326.ts'),
        '--image', str(image), '--profile', 'generic', '--launcher', 'local',
        '--runtime', 'apptainer', '--container-python', '/usr/bin/python3',
        '--nodes', '1', '--processes', *map(str, args.processes),
        '--threads', *map(str, args.threads), '--cores-per-process',
        str(args.cores_per_process), '--gpus-per-node', str(args.gpus),
        '--physical-cores-per-node', str(needed), '--warmups', str(args.warmups),
        '--repeats', str(args.repeats), '--sample-ms', str(args.sample_ms),
        '--timeout', str(args.timeout), '--barrier-timeout', str(args.barrier_timeout),
        '--wirecell-data', str(project/'wire-cell-data'), '--output', str(campaign)]
    with (output/'plan.log').open('w') as stream:
        planned = subprocess.run(plan, stdout=stream, stderr=subprocess.STDOUT)
    if planned.returncode:
        raise RuntimeError(f'Planning failed ({planned.returncode}); inspect {output/"plan.log"}')

    telemetry = Telemetry(output, uuids, args.sample_ms)
    telemetry.start()
    coordinator = None
    previous = {}
    def interrupted(signum, _frame):
        if coordinator is not None and coordinator.poll() is None:
            coordinator.terminate()
    for sig in (signal.SIGINT, signal.SIGTERM):
        previous[sig] = signal.signal(sig, interrupted)
    try:
        with (output/'run.log').open('w') as stream:
            coordinator = subprocess.Popen([
                sys.executable, str(campaign/'suite/pdhd.py'), 'run',
                '--campaign', str(campaign), '--gpu-devices', *uuids],
                stdout=stream, stderr=subprocess.STDOUT)
            while coordinator.poll() is None:
                if telemetry.error:
                    coordinator.terminate()
                    try:
                        coordinator.wait(timeout=240)
                    except subprocess.TimeoutExpired:
                        coordinator.kill()
                        coordinator.wait()
                    raise RuntimeError(f'Telemetry stopped: {telemetry.error}')
                time.sleep(.25)
            if coordinator.returncode:
                raise RuntimeError(f'Campaign failed ({coordinator.returncode}); '
                                   f'inspect {output/"run.log"}')
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        if coordinator is not None and coordinator.poll() is None:
            coordinator.terminate()
            try:
                coordinator.wait(timeout=240)
            except subprocess.TimeoutExpired:
                coordinator.kill()
                coordinator.wait()
        telemetry.stop()
    analyze(campaign, telemetry.samples, output, args.sample_ms, args.study)
    print(f'PASS: HTCondor PDHD {args.study}; {output/"telemetry-summary.md"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gpus', type=int, choices=range(1, 9), required=True)
    parser.add_argument('--study', choices=('one-gpu-packing', 'multi-gpu'), required=True)
    parser.add_argument('--processes', type=int, nargs='+', default=[1, 2, 4])
    parser.add_argument('--threads', type=int, nargs='+', default=[1, 2, 4])
    parser.add_argument('--cores-per-process', type=int, default=4)
    parser.add_argument('--warmups', type=int, default=1)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--sample-ms', type=int, default=500)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--barrier-timeout', type=int, default=300)
    args = parser.parse_args()
    if min(args.processes+args.threads) < 1 or args.cores_per_process < max(args.threads):
        parser.error('positive matrix values and cores-per-process >= max(threads) required')
    if args.warmups < 0 or args.repeats < 1 or args.sample_ms < 100:
        parser.error('warmups >= 0, repeats >= 1, and sample-ms >= 100 required')
    if args.study == 'multi-gpu' and args.gpus < max(args.processes):
        parser.error('multi-gpu study needs at least max(processes) GPUs')
    try:
        run(args)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
