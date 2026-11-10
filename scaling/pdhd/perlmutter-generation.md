# Perlmutter container event-generation smoke test

Status: one-event container simulation and structural validation passed on
2026-11-08 in interactive `srun --qos=debug` job 61006832, node nid003017,
account m5037_g. Image: docker.io/abashyal/wirecell-spng:cuda80 (listed ID
7143e3e2e3a7); Wire-Cell version: spng-0.35.0-1147-ga8d61722.

Successful outputs: `/pscratch/sd/a/abashyal/pdhd-generation-61006832-attempt3`.
`validation.json` records one complete event, ID 0, and hashes for all four
APA archives (about 21 MB each). This establishes structural generation only.
The interactive shell was exited after verification.

The test found two launcher issues, now fixed: nested srun is skipped inside
an existing task, and image inspection falls back to image listing for the
migrated read-only image. The image default Python lacked NumPy; checks now
use `/usr/bin/python3` (NumPy 1.24.4). Failed attempts are retained separately.

From the project root on a login node, select an image already built/pulled
and migrated for Podman-HPC. This script does not build or pull an image.
The image must provide `wire-cell`, the SPNG configuration imports/plugins,
Python 3 with NumPy, and detector response dependencies.

```bash
export PROJECT_DIR="$PWD"
export IMAGE=wirecell-spng:cuda80
export EVENTS=1
sbatch --account=<your-GPU-account> scaling/pdhd/perlmutter-generate.sbatch
```

Replace `<your-GPU-account>` with the actual account before running. A GPU
allocation is used with one task, eight Slurm CPUs and one GPU. Simulation
itself uses the serial Pgrapher engine and CPU response components; this is
not a GPU performance test. The same script can be invoked with `bash` inside
an existing sufficiently sized GPU allocation.

Optional environment settings (export before submission):

- `CONTAINER_PYTHON`: Python inside the image with NumPy; defaults to `/usr/bin/python3`.
- `DEPOS`: deposit NPZ input; defaults to `$PROJECT_DIR/infiles/muons.npz`.
- `EVENTS`: number of deposit sets to select, defaults to one; refuses requests
  exceeding the input count. IDs and payloads are preserved, without repetition.
- `WIRECELL_DATA`: response/geometry directory, defaults to the project copy.
- `RUN_DIR`: fresh output directory, defaults to `$SCRATCH/pdhd-generation-$SLURM_JOB_ID`.

The existing notes describe `muons.npz` as two copies of one deposit event.
Increasing EVENTS to two therefore does not establish two distinct physics
samples. This test simulates ADC frames from existing deposits; it does not
create new particle tracks. No model file is required for `stage=sim`.

Inspect `pdhd-generation-<jobid>.log` for the output path and final status.
The run directory retains `stdio.log`, image inspection, Wire-Cell version,
GPU information, the selected deposits and input hashes, a configuration
snapshot, and `adc-tpc0.npz` through `adc-tpc3.npz`. `validation.json` is
written only after all four archives have the requested number of matched
frame IDs, complete triplets, finite frames, valid channel vectors and timing
metadata. A PASS establishes structural generation, not numerical correctness
or channel/geometry equivalence. Failures preserve the run directory.

This uses the external `pdhd.jsonnet` snapshot of the local
`spng/test/spngbench/spngbench.jsonnet`; compatibility with the selected image
was confirmed for the one-event simulation above; other stages remain untested. It imports detector modules from the image rather than
mounting the host toolkit checkout.

NERSC references checked when writing the script:

- https://docs.nersc.gov/development/containers/podman-hpc/overview/
- https://docs.nersc.gov/jobs/examples/

Podman-HPC requires explicit `--gpu` for NVIDIA support. `slirp4netns`
retains the workaround used in the project's previous successful container run.
