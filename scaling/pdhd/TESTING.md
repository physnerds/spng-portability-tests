# Scaling runner review and tests

For a one-node interactive scaling sweep with mandatory host GPU telemetry,
see [INTERACTIVE-TELEMETRY.md](tests/INTERACTIVE-TELEMETRY.md). It produces
UUID-matched GPU utilization, memory and power tables and fails on missing samples.

Reviewed 2026-11-08. Tests are functional checks, not a statistically meaningful
scaling study. The inputs are four repeated copies of the previously generated
complete PDHD event, not four independent physics events.

## CPU regressions

From the project root:

```bash
python3 -m unittest discover -s scaling/pdhd/tests -v
```

No NumPy, Torch, GPU, Slurm allocation, or container is required for these
24 tests. Temporary fixtures use the standard library. Two cleanup tests
launch real short-lived subprocesses; other external operations are mocked.

| Area | Method and expected result |
| --- | --- |
| Physical CPU discovery | Inject logical IDs 1, 2, 65, 66 with shared SMT topology; discovery must select one logical CPU per package/core. |
| Affinity overlap | Give two controllers different logical CPU IDs with the same host/package/core; readiness must fail before barrier release. |
| Affinity containment | Remove a selected CPU from host allocation metadata; readiness must reject it. Wrong per-process core counts also fail. |
| Placement | Exercise 1, 2, 4 nodes and 1, 2, 4, 5, 8, 16 processes/node. Every process slot must appear exactly once, with no empty GPU controllers. Reject process counts not divisible by nodes. |
| Event partitioning | Partition 17 events among four processes; expect batch sizes 5, 4, 4, 4 and exact, disjoint coverage. Reject more processes than events. |
| Uniform Slurm requests | Five processes using 12 cores each need 60 useful cores, but packing them onto four equally provisioned controllers requests 96 cores. Reject that case on a 64-core profile. |
| Actual host placement | Accept a valid two-node metadata fixture; reject a planned node split across actual hosts and incorrect slot assignments. |
| Local/Slurm rank environment | Set local rank 1 alongside inherited Slurm rank 0; explicit local rank must win. |
| GPU identity | Accept full UUIDs with/without GPU prefix and case differences. Reject duplicate UUID aliases, mismatches with the host assignment, invalid UUIDs, and multiple visible GPU tokens. |
| Runtime commands | Inspect Podman-HPC, Docker, Apptainer arguments for GPU visibility, in-container taskset mask, Python selection, mounts, and OCI container-ID tracking. These adapters are not all hardware-tested. |
| Runtime client cleanup | Verify an exited OCI client is not signalled and cancellation targets only the client, preserving persistent FUSE helper processes. |
| Signal handling | Deliver SIGTERM to the test process inside the cancellation context; expect an exception and restoration of the previous handler. |
| Stubborn child cleanup | Start a real child ignoring SIGTERM; short test grace expires, SIGKILL must reap it. |
| Orphaned process group | Let a real group leader exit with a live sleep descendant; cleanup must kill the descendant. A zombie counts as terminated, not executing. |
| Failed launcher | Mock a controller exiting before readiness; require failed.json and launcher cleanup. |
| Campaign lock | Inject SIGTERM into campaign execution; .running must be removed. |
| Container cleanup isolation | Give two controllers CID files; normal host teardown must target only its own container. |
| Slurm cleanup dispatch | Check a separate cleanup step targets recorded actual hosts, requests zero GPUs, and uses --overlap to reach per-node runtime storage. |

## Runtime checks added to the runner

Each host controller records its Slurm/Linux affinity and CPU topology in
`rankN/launch.json`. It resolves its assigned CUDA token with `nvidia-smi` to
a full GPU UUID and forwards that UUID to the container. The worker starts
under an explicit `taskset` mask, checks that its allowed CPUs remain inside
the host mask, and uses one logical CPU per physical core for each child.

`rankN/ready.json` records actual Torch GPU UUID, CPU masks, package/core
identities, slots, host, and software versions. Before releasing work,
`check_ready()` verifies GPU uniqueness and host assignment, exact slot and
core counts, host/container topology agreement, physical-core disjointness,
actual host count and planned node grouping. This detects overlapping SMT
siblings, which the old logical-ID-only check missed.

Children run through `taskset` in separate process groups. SIGTERM/SIGINT in
the coordinator produce failure records and unwind cleanup. Worker cleanup
terminates/reaps child groups and telemetry. Host supervisors track OCI CID
files and stop/remove their own containers. Slurm can kill those supervisors
before their finally blocks finish, so failed Slurm rounds also launch a
separate bounded cleanup step, one task per recorded host. It stops/removes
only recorded campaign CIDs and writes `rankN/cleanup.json` when a CID remains.

The worker uses the profile's `container_python`; the Perlmutter profile
selects `/usr/bin/python3`, which has NumPy and Torch in the tested image.
Override it with `plan --container-python PATH` for another image.

## Reproduce the hardware review

Use a prepared dataset from `pdhd.py generate` containing four complete events
(copies explicitly allowed). Obtain one GPU node, at least eight Slurm CPUs,
and at least two GPUs. The recorded review used an outer interactive shell
with 32 Slurm CPUs and four GPUs:

```bash
srun --account=YOUR_GPU_ACCOUNT --qos=debug --constraint=gpu \
  --nodes=1 --ntasks=1 --cpus-per-task=32 --gpus-per-task=4 \
  --time=00:30:00 --pty bash --noprofile --norc
```

Inside the shell, set actual host paths, then run:

```bash
export PROJECT_DIR=/global/u2/a/abashyal/spng-portability-tests
export DATASET="$SCRATCH/pdhd-runner-review-61007458/data"
export IMAGE=docker.io/abashyal/wirecell-spng:cuda80
# REVIEW_DIR must be a fresh directory if set explicitly.
bash "$PROJECT_DIR/scaling/pdhd/tests/perlmutter_review.sh"
```

The script creates two fresh Slurm campaigns:

1. Normal completion: N=4, TBB=1, one physical core/process, P=1 on one GPU,
   then P=4 packed two processes/GPU on two GPUs. No warmup and one measured
   round. Require successful child exits, four matched APA outputs per slot,
   exact assigned event coverage, and four assembled final event files/case.
2. Cancellation: same N=4/P=4/two-GPU case. `cancel_campaign.py` waits for
   barrier release, verifies work has not already finished, waits one second,
   and sends SIGTERM to the coordinator. Require nonzero exit, failed.json,
   no campaign lock and no recorded CIDs in `podman-hpc ps -a`. It saves
   `cancellation.json` plus the coordinator log. Early completion makes the
   test inconclusive rather than successful.

An outer `srun --pty` shell already occupies a Slurm step. The test harness
uses a private srun shim adding `--overlap` for sibling steps within that
allocation. The production runner does not add overlap to measured steps;
run production campaigns from a batch script or a plain salloc shell. The
runner's failure-cleanup step intentionally uses overlap and zero GPUs.

Evidence is in the fresh REVIEW_DIR: `normal/rounds.json`, per-rank
`launch.json`, `ready.json`, `result.json`, child commands/logs, `events/`,
`cancel/rounds/.../failed.json`, cleanup logs/records and `cancellation.json`.

## Findings and scope

The review fixed physical-core overlap checks, in-container affinity loss,
local ranks shadowed by inherited Slurm ranks, padded CPU reservation checks,
container Python selection, UUID comparison/mapping, and cancellation cleanup.
A subsequent retest exposed stale container storage after group teardown; OCI client signalling now preserves persistent FUSE helpers, while recorded CIDs govern container teardown. Cleanup steps explicitly use `--cpu-bind=none` to avoid inherited bindings.

The first real Slurm cancellation test exposed two leftover running
containers; the separate per-host cleanup step addresses that failure.

Docker/Apptainer command construction and multi-node placement are covered by
CPU fixtures, not actual runs on those systems. Multi-node Slurm, larger
packing factors, TBB sweeps, numerical equivalence, whole-job scancel,
SIGKILL, node failure and cleanup after allocation loss remain unverified.
Cleanup needs a live allocation and reachable nodes; it cannot guarantee
remote cleanup after the coordinator is killed without a catchable signal.
The affinity checks establish startup placement; continuous thread-affinity
sampling is not implemented. Raw telemetry spans processing and validation;
no GPU occupancy or measurement-window average is claimed.

NERSC references checked during review:

- [CPU/GPU affinity](https://docs.nersc.gov/jobs/affinity/)
- [Podman-HPC GPU support and runtime use](https://docs.nersc.gov/development/containers/podman-hpc/overview/)
- [Slurm srun signals and step overlap](https://slurm.schedmd.com/srun.html)

Recorded results and retained evidence are indexed in the
[review note](../../local-build/knowledge-base/2026-11-08_20-30-53_UTC-pdhd-runner-review.md).
