# Running PDHD scaling tests on Perlmutter

Updated 2026-11-09. Run GPU processing on allocated compute nodes. Use a
login node to edit scripts, submit jobs, and inspect results.

There are two workflows:

- **Functional review:** short debug allocation, four repeated events, normal
  completion and deliberate cancellation. This checks the runner.
- **Scaling campaign:** fixed dataset, selected process/thread configurations,
  warmups and repeated measurements. Use regular QOS for longer campaigns.

The user-reported review on 2026-11-09 passed normal Slurm cases and
coordinator SIGTERM cleanup. Evidence is in
`/pscratch/sd/a/abashyal/pdhd-runner-final-20261109T163451Z`.
This is single-node functional coverage. Multi-node hardware execution,
whole-job cancellation, allocation loss, and numerical equivalence remain
unverified. No scaling-performance conclusion follows from this review.

## 1. Paths, software, and inputs

These examples use account `m5037_g`; replace it if charging another project.
Set these variables in each new shell, or export them before `sbatch`:

```bash
export PROJECT_DIR=/global/u2/a/abashyal/spng-portability-tests
export DATASET="$SCRATCH/pdhd-runner-review-61007458/data"
export IMAGE=docker.io/abashyal/wirecell-spng:cuda80
```

The dataset must contain `dataset.json` and four matched archives,
`adc-tpc0.npz` through `adc-tpc3.npz`. The example dataset has only four
complete events, made from repeated copies. It supports at most four
concurrent Wire-Cell processes. Verify it still exists before reserving GPUs;
Scratch is temporary storage. Keep campaigns and large outputs on Scratch,
and preserve important evidence in appropriate persistent storage.

The project must also contain:

- `infiles/legacy_roiuniter_090326.ts`: Torch model.
- `wire-cell-data/`: detector response/geometry data.
- `scaling/pdhd/`: runner, profile, NPZ helper, and Jsonnet configuration.

The host needs `python3`, `srun`, `taskset`, and `podman-hpc`. Host Python runs
the coordinator without requiring Torch or NumPy. Dataset preparation and
planning use `/usr/bin/python3` in the image, which supplies NumPy and Torch.
The image must also supply Wire-Cell and its SPNG plugins/configuration.

Check image availability with `podman-hpc images`. If necessary, prepare it
on a login node before the timed job:

```bash
podman-hpc pull "$IMAGE"
# For an image built locally, instead migrate its existing tag:
# podman-hpc migrate "$IMAGE"
```

Podman-HPC pull prepares a squashed image; locally built images need migration
for compute-node use. Use a fixed image digest for reproducible measurements
when available, and record the image ID/software versions. The runner uses
`--gpu` and the Perlmutter profile's `slirp4netns` network setting.

For new simulated ADC inputs, see
[perlmutter-generation.md](scaling/pdhd/perlmutter-generation.md). To create a
larger scaling dataset from four existing matched ADC archives, run the
following **inside a compute allocation**, replacing `ADC_DIR` and choosing
a fresh output directory:

```bash
export ADC_DIR="$SCRATCH/path-to-generated-adc"
export DATASET="$SCRATCH/pdhd-data-32-$(date -u +%Y%m%dT%H%M%SZ)"
podman-hpc run --rm --net=slirp4netns --entrypoint /usr/bin/python3 \
  --volume "$PROJECT_DIR:$PROJECT_DIR:ro" \
  --volume "$SCRATCH:$SCRATCH" --workdir "$PROJECT_DIR" \
  "$IMAGE" scaling/pdhd/pdhd.py generate \
  --adc "$ADC_DIR/adc-tpc0.npz" "$ADC_DIR/adc-tpc1.npz" \
        "$ADC_DIR/adc-tpc2.npz" "$ADC_DIR/adc-tpc3.npz" \
  --events 32 --repeat --output "$DATASET"
```

`--repeat` explicitly allows cyclic copies if fewer source events exist.
Omit it when requiring independent available event IDs; the command then
rejects an insufficient source count. Copies are useful for controlled load,
but do not establish independent physics samples. Keep the same dataset and
model across all cases being compared. Preparation copies/shards data and
can require substantial storage and I/O time.

## 2. Interactive functional review through debug QOS

From a login node, obtain the allocation used by the review procedure:

```bash
srun --account=m5037_g --qos=debug --constraint=gpu \
  --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-task=4 \
  --time=00:30:00 --job-name=pdhd-final-review \
  --pty bash --noprofile --norc
```

Inside the allocated shell, set the variables from section 1, then run:

```bash
export REVIEW_DIR="$SCRATCH/pdhd-runner-final-$(date -u +%Y%m%dT%H%M%SZ)"
bash "$PROJECT_DIR/scaling/pdhd/tests/perlmutter_review.sh"
cat "$REVIEW_DIR/normal/rounds.json"
cat "$REVIEW_DIR/cancellation.json"
```

`REVIEW_DIR` must not already exist. The harness prepares fresh campaign
snapshots and runs N=4 events, TBB=1, one physical core/process:

1. P=1 using one GPU, then P=4 using two GPUs.
2. A fresh P=4 campaign cancelled with coordinator SIGTERM after barrier release.

Success prints `PASS: normal Slurm cases and cancellation; evidence: ...`.
Both normal cases must report four verified events. The cancellation report
must contain `passed: true`, a nonzero return code, failure records,
`lock_removed: true`, and `leftover_containers: []`. Early work completion
makes cancellation inconclusive. Inspect logs if the script exits early.

The outer `srun --pty` shell occupies an existing Slurm step. The harness
creates a private `srun` wrapper adding `--overlap` so sibling runner steps
can start. That wrapper is specific to this functional test. Its PATH change
is scoped to the commands in the harness.

When finished, release the allocation:

```bash
exit
```

## 3. Interactive measured campaign through debug QOS

For a custom short campaign, use `salloc` from a login node so the
coordinator can launch steps directly, without an enclosing `srun --pty`
step. Debug QOS currently allows at most 30 minutes. Keep the matrix small.

```bash
salloc --account=m5037_g --qos=debug --constraint=gpu \
  --nodes=1 --ntasks-per-node=4 --cpus-per-task=8 \
  --gpus-per-node=4 --time=00:30:00 --job-name=pdhd-scaling-debug
```

In the allocation shell, set section 1's variables. Prepare a campaign on a
compute node with one short preparation step:

```bash
export CAMPAIGN="$SCRATCH/pdhd-scaling-debug-$SLURM_JOB_ID"
srun --nodes=1 --ntasks=1 --cpus-per-task=8 --gpus-per-task=1 \
  --cpu-bind=cores --exact \
  podman-hpc run --rm --gpu --net=slirp4netns \
  --entrypoint /usr/bin/python3 \
  --volume "$PROJECT_DIR:$PROJECT_DIR:ro" \
  --volume "$DATASET:$DATASET:ro" --volume "$SCRATCH:$SCRATCH" \
  --workdir "$PROJECT_DIR" "$IMAGE" scaling/pdhd/pdhd.py plan \
  --dataset "$DATASET" \
  --model "$PROJECT_DIR/infiles/legacy_roiuniter_090326.ts" \
  --image "$IMAGE" --profile perlmutter --launcher slurm \
  --nodes 1 --processes 1 2 4 --threads 1 --cores-per-process 1 \
  --gpus-per-node 4 --warmups 1 --repeats 3 \
  --timeout 300 --barrier-timeout 120 \
  --wirecell-data "$PROJECT_DIR/wire-cell-data" --output "$CAMPAIGN"

python3 "$CAMPAIGN/suite/pdhd.py" run --campaign "$CAMPAIGN" \
  > "$CAMPAIGN/run.log" 2>&1
cat "$CAMPAIGN/scaling-summary.json"
```

Run the coordinator directly in the allocation shell. Its own `srun`
commands launch one controller per active GPU. Do not wrap the coordinator
in another `srun`. This example creates three cases and twelve total rounds
(three warmups plus nine measured rounds). Estimate their duration from a
pilot; they are not guaranteed to fit the debug limit. Use regular QOS if
needed. Exit the allocation shell afterward.

## 4. Regular-QOS batch campaign

Save the following as `pdhd-scaling-regular.sbatch` in the project directory.
This is a one-node example using the existing four-event dataset. It sweeps
P=1,2,4 and TBB=1,2,4 with four physical cores reserved per process.

```bash
#!/bin/bash
#SBATCH --account=m5037_g
#SBATCH --qos=regular
#SBATCH --constraint=gpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=4
#SBATCH --cpus-per-task=8
#SBATCH --gpus-per-node=4
#SBATCH --time=02:00:00
#SBATCH --job-name=pdhd-scaling
#SBATCH --output=pdhd-scaling-%j.log

set -euo pipefail
export PROJECT_DIR=${PROJECT_DIR:-/global/u2/a/abashyal/spng-portability-tests}
export DATASET=${DATASET:-$SCRATCH/pdhd-runner-review-61007458/data}
export IMAGE=${IMAGE:-docker.io/abashyal/wirecell-spng:cuda80}
export CAMPAIGN="$SCRATCH/pdhd-scaling-regular-$SLURM_JOB_ID"
cd "$PROJECT_DIR"
command -v python3
command -v podman-hpc
printf 'Job %s; campaign %s\n' "$SLURM_JOB_ID" "$CAMPAIGN"

# Prepare/shard on one compute node; this step exits before measured steps.
srun --nodes=1 --ntasks=1 --cpus-per-task=8 --gpus-per-task=1 \
  --cpu-bind=cores --exact \
  podman-hpc run --rm --gpu --net=slirp4netns \
  --entrypoint /usr/bin/python3 \
  --volume "$PROJECT_DIR:$PROJECT_DIR:ro" \
  --volume "$DATASET:$DATASET:ro" --volume "$SCRATCH:$SCRATCH" \
  --workdir "$PROJECT_DIR" "$IMAGE" scaling/pdhd/pdhd.py plan \
  --dataset "$DATASET" \
  --model "$PROJECT_DIR/infiles/legacy_roiuniter_090326.ts" \
  --image "$IMAGE" --profile perlmutter --launcher slurm \
  --nodes 1 --processes 1 2 4 --threads 1 2 4 --cores-per-process 4 \
  --gpus-per-node 4 --warmups 1 --repeats 5 \
  --timeout 1800 --barrier-timeout 300 \
  --wirecell-data "$PROJECT_DIR/wire-cell-data" --output "$CAMPAIGN"

# The batch shell coordinates; the runner launches its own Slurm steps.
python3 "$CAMPAIGN/suite/pdhd.py" run --campaign "$CAMPAIGN" \
  > "$CAMPAIGN/run.log" 2>&1
cat "$CAMPAIGN/scaling-summary.json"
```

Submit and monitor from a login node:

```bash
cd "$PROJECT_DIR"
sbatch --export=ALL pdhd-scaling-regular.sbatch
# Substitute the job ID printed by sbatch:
squeue -j JOBID
sacct -j JOBID --format=JobID,JobName,State,Elapsed,ExitCode
# Read the submission-directory log and the campaign's run.log.
tail -n 60 pdhd-scaling-JOBID.log
```

Slurm directives do not expand shell variables. Edit directives in the file
or override them on submission, for example:

```bash
sbatch --account=m5037_g --time=04:00:00 pdhd-scaling-regular.sbatch
```

Regular GPU QOS currently permits up to 48 hours and allocates exclusive
nodes. The two-hour request above is a starting estimate, not a measured
runtime. Nine cases with one warmup and five repeats produce 54 rounds.
Budget preparation, container startup, processing, validation, assembly and
cleanup; per-round `--timeout` does not set the job's walltime. Increase N
beyond four for useful sustained measurements, using the preparation step
in section 1 and exporting the resulting `DATASET` before submission.

## 5. Choosing a matrix and sizing the allocation

`--nodes`, `--processes`, and `--threads` form a Cartesian product.
`--processes` is the total Wire-Cell process count across all nodes;
`--threads` is the TBB limit per process. `--torch-threads` defaults to one.
The Perlmutter profile uses 64 physical CPU cores/node and two Slurm logical
CPUs per physical core. `--cores-per-process` must be at least the largest
TBB thread count; it remains fixed across the campaign.

For each case, let:

- `Pnode = total_processes / nodes` (must be an integer).
- `G = min(Pnode, gpus_per_node)` active GPU controllers per node.
- `S = ceil(Pnode / G)` maximum process slots per controller.
- `C = cores_per_process` physical cores per process.

Each controller requests `2 × S × C` Slurm CPUs. Provision at least
`G × 2 × S × C` Slurm CPUs and G GPUs per node for that case. Uniform
controller requests can include padding, so checking only `Pnode × C`
is insufficient. The planner rejects requests exceeding physical capacity.
The allocation must cover the maximum requirements across the entire matrix.

The regular example's maximum is four controllers × eight logical CPUs =
32 Slurm CPUs/node, with four GPUs. GPU use grows from one to four as P
grows. For a packing experiment at fixed four GPUs, use P=4,8,16 with at least
16 events. With C=4, its maximum needs four controllers × 32 logical CPUs =
128 Slurm CPUs/node: change `--cpus-per-task=32` in the allocation directives.
Keep the preparation step at eight CPUs if desired.

To explore nodes=1,2 at a fixed four processes/GPU, prepare **separate plans**
for `(nodes=1, processes=4)` and `(nodes=2, processes=8)`, with identical
N, image, model, threads, and cores/process. Submit each with the matching
node count and a fresh campaign path. At least eight events are needed.
A single `--nodes 1 2 --processes 4 8` command also creates unwanted cross
combinations. Separate campaigns require an explicit cross-campaign analysis;
the built-in summary only compares cases in its own campaign. Multi-node
examples are proposed configurations, pending hardware validation. All nodes
must see the same project, campaign, detector-data paths and migrated image.

## 6. Results, validation, and interrupted runs

Inspect these files under `CAMPAIGN`:

| File | Meaning |
| --- | --- |
| `campaign.json` | Matrix, profile, input hashes, image, and timing definition |
| `run.log` | Coordinator errors and progress |
| `rounds.json`, `rounds.csv` | Successful round records, including warmups |
| `scaling-summary.json` | Measured throughput means, standard deviations, completeness |
| `rounds/CASE/ROUND/summary.json` | Event count and timing for one validated round |
| `rounds/CASE/ROUND/rank*/launch.json`, `ready.json` | Host/container CPU topology, masks, GPU identities |
| `rounds/CASE/ROUND/events/` | Assembled complete-event outputs |
| `rounds/CASE/ROUND/failed.json`, `launcher.log`, `cleanup.log` | Failure and teardown evidence when present |

Require all planned measured rounds, `complete: true`, and the intended
`verified_events` in each round before comparing performance. Structural
validation does not establish numerical equivalence. `events_per_min` uses
the barrier-release-to-last-processing-finish window; the end-to-end rate
also includes startup, validation and assembly. Warmups are excluded from
means. Built-in GPU scaling comparisons require a fixed process/GPU ratio;
thread and packing sweeps need their own interpretation. Record GPU memory
variant and software versions when comparing jobs.

The campaign snapshots its runner, configuration, model and data shards.
Create a fresh campaign after changing code, inputs or parameters. Existing
round directories are not resumable: rerunning the same campaign can fail
on existing output paths. If a run fails, inspect its logs before planning
a new campaign. To summarize successful rounds already written:

```bash
python3 "$CAMPAIGN/suite/pdhd.py" summarize --campaign "$CAMPAIGN"
```

This can produce a partial summary; it does not finish missing rounds.
The runner handles coordinator SIGTERM/SIGINT, but whole-job `scancel`,
SIGKILL, allocation expiry and unreachable nodes have different cleanup
limits. Do not assume the tested SIGTERM guarantee applies to them. Do not
reset shared Podman storage or indiscriminately delete containers to recover
a campaign. Retain failure evidence and inspect the recorded campaign CIDs.

## References

NERSC guidance checked 2026-11-09:

- [Interactive allocations](https://docs.nersc.gov/jobs/interactive/)
- [GPU QOS limits and charges](https://docs.nersc.gov/jobs/policy/)
- [Running jobs on Perlmutter](https://docs.nersc.gov/systems/perlmutter/running-jobs/)
- [Podman-HPC image preparation and GPU support](https://docs.nersc.gov/development/containers/podman-hpc/overview/)
- [Scratch filesystem](https://docs.nersc.gov/filesystems/perlmutter-scratch/)
- [Runner test methods and limits](scaling/pdhd/TESTING.md)
