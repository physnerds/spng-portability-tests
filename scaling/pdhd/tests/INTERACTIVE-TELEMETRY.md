# Interactive one-node scaling with mandatory GPU telemetry

Run these commands yourself. This test uses all four GPUs on one GPU node,
P=1,2,4, TBB=1,2,4, four physical cores/process, one warmup and two measured
rounds/case. It uses host-side `nvidia-smi`, avoiding the earlier broken
container sampler. It does not modify or rely on the worker's `gpu.csv`.
The default is now **local controllers inside the existing Slurm compute
step**, with explicit GPU UUIDs and disjoint CPU masks. It launches no sibling
Slurm steps, avoiding the reproduced four-rank GPU-binding failure. Slurm
still supplies the one-node allocation and interactive compute step.

From a login node, request the compute shell:

```bash
srun --account=m5037_g --qos=debug --constraint=gpu \
  --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-node=4 --gpu-bind=none \
  --time=00:30:00 --job-name=pdhd-gpu-telemetry \
  --pty bash --noprofile --norc
```

Inside that compute shell:

```bash
export PROJECT_DIR=/global/u2/a/abashyal/spng-portability-tests
# Four complete events: short functional/scaling pilot with repeated inputs.
export DATASET="$SCRATCH/pdhd-runner-review-61007458/data"
export TELEMETRY_DIR="$SCRATCH/pdhd-telemetry-${SLURM_JOB_ID}-$(date -u +%Y%m%dT%H%M%SZ)"
python3 "$PROJECT_DIR/scaling/pdhd/tests/interactive_telemetry.py" \
  --dataset "$DATASET" --output "$TELEMETRY_DIR"
cat "$TELEMETRY_DIR/telemetry-summary.md"
```

The output directory must be fresh. The image and prepared dataset must
already exist. The script plans a new campaign in a container, launches its
local container controllers, and samples all four host GPUs approximately
every 500 ms. It verifies that the shell affinity includes at least 16 physical
cores before planning. Sampling
starts before the campaign and stops after it exits. UUID matching selects
only each Wire-Cell process's execution interval for utilization summaries.
The sampler also records idle GPUs in the raw CSV, but they are excluded
from active-process averages. GPU preflight occurs before campaign planning.

For optional `--launcher slurm`, the coordinator clears inherited `SLURM_TRES_BIND`, `SLURM_TRES_PER_TASK`,
`SLURM_GPU_BIND`, and `SLURM_GPUS_PER_TASK` in its child environment so the
outer shell's GPU task settings cannot conflict with each inner step's
explicit one-GPU/task request. The allocation identity and CUDA visibility
are preserved. Original Slurm settings are retained in `preflight.json`;
removed settings are recorded in `step-environment.json`.
That optional mode still uses a private `srun --overlap` shim and remains
known to fail with duplicate GPU assignments in the reproduced interactive
configuration. Use the default local mode for this telemetry test. Its
launch/readiness and E2E overhead differ from the original batch Slurm study;
do not combine their E2E measurements as if they used the same launcher.

The script fails if GPU UUIDs/readings are missing, sampling fails, campaign
execution fails, or any measured process has fewer than two samples or a
sample gap exceeding max(2 seconds, four requested sampling intervals).
Zero utilization is a valid reading; it is not replaced with missing data.
No pass is printed for missing telemetry. SIGINT/SIGTERM requests coordinator
cleanup; allocation loss/SIGKILL still cannot guarantee cleanup.

| Output | Contents |
| --- | --- |
| `preflight.json` | Host, Slurm job, device UUIDs, numeric preflight readings, invocation |
| `step-environment.json` | Inherited GPU task/binding settings removed for sibling steps |
| `host-gpu.csv` | Epoch timestamp, query duration, GPU UUID, utilization %, used memory MiB, power W |
| `gpu-process-windows.csv` | Per measured rank/round sample counts/gaps, GPU utilization/memory/power, CPU usage and peak RSS |
| `telemetry-summary.md` | Nine-case table with throughput, resource counts, speedup, scaling efficiency, CPU and GPU measurements |
| `campaign/` | Frozen runner/configuration, all warmup/measured rounds, placement, validation, timings and logs |
| `plan.log`, `run.log` | Planning and coordinator logs |
| `telemetry-error.json` | Sampler error, if collection fails |

Means are arithmetic sample means within a process window, then equal means
over measured processes/rounds. Power/memory/utilization are device-wide,
not process-exclusive. `nvidia-smi` utilization is GPU busy time, not kernel
occupancy. Query midpoint timestamps have uncertainty of approximately half
the recorded query duration. No energy estimate is claimed. Peak memory and
power columns are maximum readings on any active GPU, not node sums.

The default four-event dataset is suitable for verifying telemetry and
short scaling checks, not replacing the 32-event study. To repeat that
workload, use a prepared 32-event dataset, `--repeats 5`, and an allocation
long enough for nine warmups plus 45 measured rounds. Do not expect that
campaign to fit a 30-minute allocation. Two repeats provide only a small
sample for SD. Monitor remaining allocation time and exit the shell when done.

## First hardware attempt and binding correction

User-run job 61092478 on nid002180 passed telemetry preflight and recorded
1,528 host GPU readings across four devices, with peak observed busy time
99%. Six P=1/P=2 warmups completed. The first P=4 warmup failed before
processing because ranks 1 and 3 reported the same UUID. Slurm logged
`Can't find free slot for local_proc_id = 3`; cleanup also logged
`Not enough gres to bind 4 per task`. No measured rounds completed because
the runner performs all case warmups before its measured rounds.

Evidence is retained at
`/pscratch/sd/a/abashyal/pdhd-telemetry-61092478-20261110T160057Z`.
This indicates a task-binding conflict consistent with inherited outer
four-GPU/task settings; the original environment was not captured, so the
exact inherited values cannot be proved from that attempt. The allocation
example and coordinator environment handling above address this risk.
The corrected version still requires a fresh user-run hardware check.
The later 30-minute time-limit message concerned the still-open allocation;
the campaign had already failed near 16:04 UTC.

The second attempt, job 61095121 on nid008576, reproduced the same P=4
duplicate UUID and Slurm free-slot error despite removing inherited GPU
settings. `preflight.json` confirms the original binding was `gres/gpu:none`,
not four GPUs/task. Thus the first inheritance explanation was insufficient;
the underlying Slurm/overlap/binding interaction remains unresolved. The
script now defaults to its existing local-launcher path with explicit
host GPU UUIDs, avoiding sibling-step allocation entirely. This new default
requires hardware verification; neither failed attempt completed measured
rounds. Start a fresh evidence directory, including when reusing a still-live
allocation. The agent has not launched any tests.

References checked:
[NERSC interactive jobs](https://docs.nersc.gov/jobs/interactive/) and
[Podman-HPC GPU support](https://docs.nersc.gov/development/containers/podman-hpc/overview/),
plus [Slurm's documented GPU/task and binding environment variables](https://slurm.schedmd.com/srun.html).
