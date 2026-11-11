# Running the PDHD scaling tests with HTCondor on `sgpu`

Updated 2026-11-11. These tests have **not** been run on `sgpu`. They were
prepared on a machine without access to the BNL Condor pool or GPUs and are
being handed off for user execution and validation.

The Condor test uses the existing PDHD runner with its `local` launcher inside
one HTCondor slot. It does not add a native Condor launcher to `pdhd.py`.
Therefore these are one-node tests. Do not use `--nodes` above one.

No NVTX profiling is enabled. The Perlmutter reference campaign did not use
NVTX, and adding it would create a different performance experiment.

## 1. Files provided

| File | Purpose |
| --- | --- |
| `scaling/pdhd/pdhd-condor.sh` | Common HTCondor executable |
| `scaling/pdhd/pdhd-functional.sub` | Short one-GPU functional test |
| `scaling/pdhd/pdhd-scaling.sub` | Default one-GPU process-packing study |
| `scaling/pdhd/pdhd-scaling-4gpu.sub` | Optional four-GPU scaling study |
| `scaling/pdhd/tests/condor_campaign.py` | Preflight, campaign execution, GPU telemetry, validation, and report generation |

The test driver produces the throughput, scaling, GPU, CPU, memory, timing,
resource-productivity, and telemetry-coverage metrics used in
`2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-performance.md`.

## 2. Required inputs on `sgpu`

Log in to `sgpu`, enter the shared project checkout, and define these four
absolute paths:

```bash
ssh sgpu
cd /path/to/spng-portability-tests

export PROJECT_DIR="$PWD"
export DATASET=/shared/path/to/pdhd-dataset
export IMAGE=/shared/path/to/wirecell-spng.sif
export RESULTS_DIR=/shared/path/to/pdhd-condor-results
```

`PROJECT_DIR`, `DATASET`, `IMAGE`, and `RESULTS_DIR` must be visible at the
same absolute paths on the Condor execute node. Do not use paths local only to
the submit host.

The image must be an existing SIF file. Do not use a `docker://` URI or pull
the image during a measured job.

The dataset must contain:

```text
dataset.json
adc-tpc0.npz
adc-tpc1.npz
adc-tpc2.npz
adc-tpc3.npz
```

The project must contain:

```text
infiles/legacy_roiuniter_090326.ts
wire-cell-data/
scaling/pdhd/pdhd.py
```

Check the inputs without starting a job:

```bash
command -v condor_submit
command -v condor_q
test -x "$PROJECT_DIR/scaling/pdhd/pdhd-condor.sh"
test -r "$IMAGE"
test -r "$DATASET/dataset.json"
for apa in 0 1 2 3; do test -r "$DATASET/adc-tpc${apa}.npz"; done
test -r "$PROJECT_DIR/infiles/legacy_roiuniter_090326.ts"
test -d "$PROJECT_DIR/wire-cell-data"
mkdir -p "$PROJECT_DIR/condor-logs" "$RESULTS_DIR"
```

The execute node must provide `python3`, `apptainer`, `nvidia-smi`, and
`taskset`. The job checks these commands and fails before planning if any are
missing.

The reported `sgpu` host has two AMD EPYC 9355 sockets, 32 physical cores per
socket, two hardware threads/core (64 physical cores and 128 logical CPUs),
and ten NVIDIA L40S GPUs with 46,068 MiB/device. These are whole-node values.
They do not mean that one Condor job owns all CPUs or GPUs visible in `lscpu`
or `nvidia-smi`.

## 3. Confirm the available GPU slots

The BNL Condor environment has previously exposed an assigned GPU as a short
UUID such as `GPU-47806d5a`. The driver resolves that token to exactly one full
GPU UUID and records both values. It does not assume GPU index 0 and does not
use `nvidia-smi pmon -i` with a UUID.

The supplied `nvidia-smi` output shows all ten host GPUs, including GPUs used
by other jobs. That output is inventory, not allocation. The test uses only
the UUIDs listed in its own `CUDA_VISIBLE_DEVICES`; it fails if their count
differs from `request_gpus` or if a token is missing, ambiguous, or repeated.

Inspect the pool before choosing a submit file:

```bash
condor_status -compact
condor_status -constraint 'Gpus > 0' \
  -af Name Cpus Memory Gpus CUDACapability CUDAGlobalMemoryMb
```

Use `pdhd-scaling.sub` unless this output confirms that a single slot can
provide four GPUs and at least 16 physical CPU cores. The default study uses
one GPU because that is consistent with the previously observed `sgpu`
allocation.

The submit requests are intentionally limited to the maximum active workload:

| Job | GPUs | CPUs | Memory | Execute disk | Reason |
| --- | ---: | ---: | ---: | ---: | --- |
| Functional | 1 | 4 | 12 GB | 2 GB | P=4 with one core/process; reference peak RSS was about 7.4 GiB total |
| One-GPU scaling | 1 | 16 | 16 GB | 2 GB | P=4 with four cores/process; reference peak process-RSS sum was below 10 GiB |
| Optional four-GPU scaling | 4 | 16 | 16 GB | 2 GB | Same four host processes/16 cores; only GPU placement changes |

Large datasets, the SIF, campaign shards, and results remain on shared
storage, so the jobs do not request execute-node disk for those files.
`request_disk = 2GB` is only headroom for Condor/Apptainer temporary use.

The CPU requests assume one Condor CPU resource corresponds to one usable CPU
in the job affinity mask. The driver counts distinct physical cores from
`sched_getaffinity()` and refuses to run if it receives fewer than four for
the functional test or sixteen for the scaling test. If that check fails
because the pool assigns SMT siblings, report `preflight.json` and the Condor
slot configuration; do not increase CPU requests before confirming the
mapping.

The two studies answer different questions:

- `pdhd-scaling.sub`: P=1,2,4 Wire-Cell processes share one GPU. This is a
  process-packing/concurrency study. Multi-GPU efficiency is reported as N/A.
- `pdhd-scaling-4gpu.sub`: P=1,2,4 use one GPU/process. This is comparable in
  resource layout to the one-node Perlmutter scaling matrix.

Do not represent the one-GPU packing results as multi-GPU scaling.

## 4. Run the functional test first

The functional test requests one GPU, four CPUs, 12 GB RAM, and 2 GB execute
disk. It runs P=1 and P=4 with one core/process, no warmup, and one measured
round. A four-event dataset is sufficient.

First ask Condor to parse the submit description without submitting it:

```bash
cd "$PROJECT_DIR"
condor_submit -dry-run - scaling/pdhd/pdhd-functional.sub | sed -n '1,160p'
```

If the dry run shows the expected absolute paths and resource requests,
submit it:

```bash
condor_submit scaling/pdhd/pdhd-functional.sub
```

Record the cluster ID printed by `condor_submit`, then monitor it:

```bash
export CLUSTER_ID=REPLACE_WITH_CLUSTER_ID
condor_q "$CLUSTER_ID" -better-analyze
condor_q "$CLUSTER_ID" \
  -af ClusterId ProcId JobStatus RemoteHost RequestCpus RequestGpus
tail -f "$PROJECT_DIR/condor-logs/pdhd-functional-${CLUSTER_ID}.0.out"
```

The functional result directory is:

```bash
export RUN_DIR="$RESULTS_DIR/pdhd-functional-${CLUSTER_ID}.0"
```

After completion, inspect:

```bash
condor_history "$CLUSTER_ID" -limit 1 \
  -af ClusterId ProcId JobStatus ExitCode HoldReason RemoteHost RemoteWallClockTime
cat "$PROJECT_DIR/condor-logs/pdhd-functional-${CLUSTER_ID}.0.err"
cat "$RUN_DIR/preflight.json"
cat "$RUN_DIR/telemetry-summary.md"
cat "$RUN_DIR/telemetry-coverage.json"
```

A successful functional result must have:

- Condor exit code zero;
- a final `PASS: HTCondor PDHD one-gpu-packing` message;
- exactly one allocated and resolved GPU UUID;
- completed P=1 and P=4 cases;
- the intended verified event count in both rounds;
- no `failed.json` files;
- nonempty `host-gpu.csv`; and
- `telemetry-summary.md`, `case-metrics.csv`, and
  `gpu-process-windows.csv`.

Check failures explicitly:

```bash
find "$RUN_DIR/campaign/rounds" -name failed.json -print
find "$RUN_DIR/campaign/rounds" -name summary.json -print
```

Do not submit the measured campaign until this test succeeds.

## 5. Run the default one-GPU packing campaign

Use the prepared 32-event dataset for useful measurements. The default job
requests one GPU, 16 CPUs, 16 GB RAM, and 2 GB execute disk. It runs the
Cartesian product P=1,2,4 and TBB=1,2,4 with four assigned physical
cores/process, one warmup, and five measured rounds/case.

Set `DATASET` to the 32-event directory, repeat the input checks from section
2, and submit:

```bash
cd "$PROJECT_DIR"
condor_submit -dry-run - scaling/pdhd/pdhd-scaling.sub | sed -n '1,160p'
condor_submit scaling/pdhd/pdhd-scaling.sub
```

Monitor it with the commands from section 4, substituting the new cluster ID
and `pdhd-scaling` log prefix. Its result directory is:

```bash
export CLUSTER_ID=REPLACE_WITH_CLUSTER_ID
export RUN_DIR="$RESULTS_DIR/pdhd-scaling-${CLUSTER_ID}.0"
```

Inspect the completed report:

```bash
cat "$RUN_DIR/telemetry-summary.md"
cat "$RUN_DIR/telemetry-coverage.json"
column -s, -t < "$RUN_DIR/case-metrics.csv" | less -S
```

All 45 measured rounds must be present: nine cases times five repeats.
Warmups are additional rounds and are excluded from the tables.

## 6. Optional four-GPU campaign

Only use this test after `condor_status` confirms that `sgpu` can provide four
GPUs in one slot. Otherwise the job may remain idle indefinitely.

```bash
cd "$PROJECT_DIR"
condor_submit -dry-run - scaling/pdhd/pdhd-scaling-4gpu.sub | sed -n '1,160p'
condor_submit scaling/pdhd/pdhd-scaling-4gpu.sub
```

The result directory is:

```bash
export CLUSTER_ID=REPLACE_WITH_CLUSTER_ID
export RUN_DIR="$RESULTS_DIR/pdhd-scaling-${CLUSTER_ID}.0"
```

This uses the same output prefix as the default scaling campaign; unique
Condor cluster IDs keep the directories separate.

The four-GPU report includes process speedup and multi-GPU scaling efficiency
relative to P=1 at the same TBB setting.

## 7. What the test records

| Output | Contents |
| --- | --- |
| `preflight.json` | Host, Condor environment, CPU affinity, original GPU allocation token, resolved full UUID, and initial GPU readings |
| `nvidia-smi-L.txt` | GPUs visible on the execute host |
| `image.sha256` | SIF checksum |
| `plan.log` | Campaign planning output |
| `run.log` | Coordinator output |
| `host-gpu.csv` | Timestamped UUID, GPU busy %, used MiB, power, and query duration |
| `gpu-process-windows.csv` | GPU/CPU/RSS measurements selected for each measured process window |
| `case-metrics.csv` | Aggregated throughput, scaling, resource, timing, and telemetry metrics |
| `telemetry-coverage.json` | Raw/selected sample counts, gaps, repeats, and dataset repetition status |
| `telemetry-summary.md` | Human-readable throughput, resource, and timing tables |
| `campaign/` | Frozen runner, model, shards, validated rounds, outputs, and structural summaries |

GPU samples are matched by full UUID and process timestamps. Missing or sparse
telemetry fails the job; it is never reported as zero utilization. GPU busy %
is device activity, not achieved FLOPS or kernel occupancy. Power and memory
are device-wide readings. For one-GPU packing, overlapping process windows
observe the same shared device and are not process-exclusive GPU measurements.

## 8. Holds, failures, cancellation, and reruns

Useful Condor `JobStatus` values are 1 idle, 2 running, 5 held, and 6
transferring output. For a held job:

```bash
condor_q "$CLUSTER_ID" -af ClusterId ProcId JobStatus HoldReason
cat "$PROJECT_DIR/condor-logs/"*"${CLUSTER_ID}.0.err"
tail -n 100 "$RUN_DIR/plan.log" 2>/dev/null
tail -n 100 "$RUN_DIR/run.log" 2>/dev/null
```

Cancel a job with:

```bash
condor_rm "$CLUSTER_ID"
```

The coordinator handles SIGTERM/SIGINT, but eviction grace periods and
SIGKILL behavior are controlled by the site. Treat an interrupted round as a
failure, retain its evidence, and do not include it in performance results.

Every submission uses a fresh directory derived from its Condor cluster and
process IDs. Do not rerun manually into an existing `RUN_DIR`; campaigns are
immutable and incomplete round directories are not resumable.

## 9. Results to report back

For each attempted job, report:

1. the submit file used and Condor cluster ID;
2. the output of the `condor_history` command from section 4;
3. the Condor `.out` and `.err` files;
4. `preflight.json` and `nvidia-smi-L.txt`;
5. `plan.log` and `run.log`, or at least their last 100 lines;
6. `telemetry-summary.md`, `telemetry-coverage.json`, and
   `case-metrics.csv` when produced; and
7. every `failed.json` if the job did not pass.

Also state the dataset event count, `repeated_copies` value, SIF path, and
whether the run was the one-GPU packing or four-GPU scaling study. Do not
claim physics equivalence from structural validation alone.

## References

- [Condor/SPNG requirements used for this handoff](SKILL-Condor.md)
- [Reference Perlmutter telemetry report](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-performance.md)
- [Runner test scope and limitations](scaling/pdhd/TESTING.md)
- [HTCondor GPU jobs](https://htcondor.readthedocs.io/en/latest/users-manual/submitting-a-job.html#jobs-that-require-gpus)
- [HTCondor GPU UUID discovery](https://htcondor.readthedocs.io/en/main/man-pages/condor_gpu_discovery.html)
