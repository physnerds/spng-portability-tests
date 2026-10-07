# Wire-Cell SPNG containers on Perlmutter

Build and run Wire-Cell Toolkit SPNG on NERSC Perlmutter with `podman-hpc`.
The Dockerfiles describe OCI images; the supplied build scripts invoke
`podman-hpc`, without a Docker daemon or `sudo`.

This README follows the **current root-level scripts**. The
[knowledge-base index](local-build/knowledge-base/knowledge-base.md) also records
an earlier, successful Docker/CMake/NVTX build. That older workflow used Rocky
Linux, CUDA 12.4, and Spack PyTorch; it is not the software stack built by the
current Dockerfiles.

## Current build layout

The build has two stages:

1. `Dockerfile.dependencies` starts from `docker.io/nersc/pytorch:24.08.01`,
   installs Spack and non-Torch dependencies, and creates a unified Spack view.
   CUDA and PyTorch come from the NERSC base image, not a Spack `py-torch` build.
2. `Dockerfile` clones the Toolkit's `spng` branch, builds it with `wcb`/Waf
   and SPNG/LibTorch support, and installs into `/opt/wirecell-view`.

| File | Purpose |
| --- | --- |
| `Dockerfile.dependencies`, `spack.yaml` | Dependency image and Spack specifications |
| `build-dependencies.sh` | Build `wirecell-spng-deps:perlmutter` |
| `Dockerfile`, `build-image.sh` | Build `wirecell-spng:cuda80` |
| `bootstrap.sh` | Convenience wrapper; see the dependency-selection caveat below |
| `run-container.sh` | Interactive launcher with user-specific mounts and image default |
| `entrypoint.sh` | Environment helper; the current Dockerfile does not install or register it |
| `local-build/knowledge-base/` | Build investigations and recorded outcomes |
| `local-build/benchmarks/` | Native/container comparison launchers |

Inside the dependency/final images:

| Path | Contents |
| --- | --- |
| `/opt/spack` | Spack |
| `/opt/wirecell-env` | Spack environment and concretized specifications |
| `/opt/spack-install` | Installed Spack dependencies |
| `/opt/wirecell-view` | Dependency view and installed Toolkit |
| `/opt/wire-cell-toolkit` | Toolkit source, configuration, and Waf build |
| `/usr/local/cuda` | CUDA toolkit inherited from the base image |

## Prepare on Perlmutter

```bash
cd /global/homes/a/abashyal/spng-portability-tests
command -v podman-hpc
podman-hpc --version
```

NERSC supports image builds on Perlmutter with Podman-HPC. Keep long,
CPU-intensive compilation in an allocated compute job. Pulls and image
preparation can be done before allocating GPU runtime resources. See the
[NERSC Podman-HPC guide](https://docs.nersc.gov/development/containers/podman-hpc/overview/).

The CUDA compiler and PyTorch libraries are inside the image. A GPU is not
required to compile; do not require `torch.cuda.is_available()` or `nvidia-smi`
to succeed during image construction. Check GPU access later in a GPU job.

The supplied `.dockerignore` is empty. This checkout includes native builds,
input data, and outputs, so the build context can be large. Use a clean checkout
or an appropriate `.dockerignore` for repeated builds.

## Build both images from source

Run these commands on the node where you intend to build. For a compute-node
build, first request a CPU allocation and enter a job step, for example:

```bash
salloc --account=YOUR_PROJECT --constraint=cpu --qos=regular \
    --nodes=1 --ntasks=1 --cpus-per-task=16 --time=04:00:00
srun --nodes=1 --ntasks=1 --cpus-per-task=16 --pty bash
cd /global/homes/a/abashyal/spng-portability-tests
```

Replace `YOUR_PROJECT` with your CPU project account and choose a walltime
appropriate for dependency compilation. `BUILD_JOBS` controls only the final
Toolkit build; the dependency script does not expose a Spack job-count setting.

Build the dependency image, then explicitly use it for the final image:

```bash
./build-dependencies.sh
DEPENDENCY_IMAGE=wirecell-spng-deps:perlmutter \
    IMAGE_NAME=wirecell-spng IMAGE_TAG=cuda80 BUILD_JOBS=4 \
    ./build-image.sh
podman-hpc images
podman-hpc migrate wirecell-spng:cuda80
```

The explicit `DEPENDENCY_IMAGE` matters: `build-image.sh` otherwise defaults to
`docker.io/abashyal/wirecell-spng-deps:cuda80` and attempts to pull it if absent.
Its default is different from the locally built dependency tag.

**Bootstrap caveat:** `bootstrap.sh` selects a dependency image but does not
export that selection to `build-image.sh`. To use the default locally built
image through the wrapper, export it by placing the assignment before the command:

```bash
DEPENDENCY_IMAGE=wirecell-spng-deps:perlmutter ./bootstrap.sh
podman-hpc migrate wirecell-spng:cuda80
```

For custom dependency names/tags, use the explicit two-step workflow and pass
the same tag to `build-image.sh`.

[NERSC's migration tutorial](https://docs.nersc.gov/development/containers/podman-hpc/podman-beginner-tutorial/)
explains why locally built images must be migrated for use on other nodes.
Migrate the final image after rebuilding it. Migration prepares a runtime copy;
it does not transfer the writable build cache between nodes.

## Rebuild only the Toolkit

Reuse the dependency image when changing the Toolkit branch:

```bash
DEPENDENCY_IMAGE=wirecell-spng-deps:perlmutter \
    WCT_REF=spng BUILD_JOBS=4 ./build-image.sh
podman-hpc migrate wirecell-spng:cuda80
```

For an uncached final build, add `NO_CACHE=true`. A cached Git clone layer can
retain an older commit even when the remote branch has advanced. Record the
actual revision inside the image; `WCT_REF` is used as a Git branch/tag selector
by the current Dockerfile.

| Setting | Default | Used by |
| --- | --- | --- |
| `NERSC_PYTORCH_IMAGE` | `docker.io/nersc/pytorch:24.08.01` | Dependency build |
| `DEPENDENCY_IMAGE_NAME` / `DEPENDENCY_IMAGE_TAG` | `wirecell-spng-deps` / `perlmutter` | Dependency build |
| `SPACK_REF` / `WIRECELL_SPACK_REF` | `v1.0.0` / `master` | Dependency build |
| `DEPENDENCY_IMAGE` | `docker.io/abashyal/wirecell-spng-deps:cuda80` | Final build |
| `WCT_REPOSITORY` / `WCT_REF` | WireCell GitHub Toolkit repository / `spng` | Final build |
| `IMAGE_NAME` / `IMAGE_TAG` | `wirecell-spng` / `cuda80` | Final build |
| `BUILD_JOBS` | `4` | Final build |
| `PODMAN_BUILD_NETWORK` | `host` | Both build scripts |
| `NO_CACHE` | `false` | Both build scripts |

The dependency script also forwards existing HTTP/HTTPS proxy settings.

## Use an existing image

To skip compilation, pull the published Perlmutter-tagged image:

```bash
podman-hpc pull docker.io/abashyal/wirecell-spng:cuda80
export IMAGE=docker.io/abashyal/wirecell-spng:cuda80
```

Podman-HPC automatically migrates pulled images. A published image can have a
different Toolkit revision or dependency stack from this checkout; inspect it
before using it for a software-parity or performance comparison.

For your locally built image, use:

```bash
export IMAGE=wirecell-spng:cuda80
```

## Verify and run in a GPU allocation

Perlmutter GPU nodes have four NVIDIA A100 GPUs. Use an A100-compatible build
(compute capability 8.0); the old `cuda89` configuration targeted other GPUs.
The `cuda80` image tag is a label: the current scripts do not pass a
`cuda_arch=80` build argument, and `spack.yaml` does not build PyTorch. Inspect
actual CUDA/Torch support rather than inferring it from the tag. See the
[Perlmutter architecture](https://docs.nersc.gov/systems/perlmutter/architecture/).

Request GPU resources, then launch checks through `srun`:

```bash
salloc --account=YOUR_PROJECT_g --constraint=gpu --qos=interactive \
    --nodes=1 --gpus=4 --time=01:00:00

srun --nodes=1 --ntasks=1 --cpus-per-task=2 --gpus-per-task=1 \
    podman-hpc run --rm --gpu "$IMAGE" nvidia-smi

srun --nodes=1 --ntasks=1 --cpus-per-task=2 --gpus-per-task=1 \
    podman-hpc run --rm --gpu "$IMAGE" /usr/bin/python -c \
    'import torch; print("Torch:", torch.__version__); print("CUDA:", torch.version.cuda); print("Available:", torch.cuda.is_available()); assert torch.cuda.is_available(); print("GPU:", torch.cuda.get_device_name(0))'

srun --nodes=1 --ntasks=1 --cpus-per-task=2 --gpus-per-task=1 \
    podman-hpc run --rm --gpu "$IMAGE" bash -c \
    'command -v wire-cell; wire-cell --version; nvcc --version; git -C /opt/wire-cell-toolkit rev-parse HEAD'
```

Use the NERSC Python explicitly because the Spack view on `PATH` may expose a
Python without NERSC PyTorch. The Toolkit is built against the NERSC Torch
installation.

Both the allocation and the job step need GPU requests; Podman-HPC's `--gpu`
adds the GPU runtime integration. See
[NERSC interactive jobs](https://docs.nersc.gov/jobs/interactive/) and
[Podman-HPC GPU access](https://docs.nersc.gov/development/containers/podman-hpc/overview/#using-nvidia-gpus-in-podman-hpc).

### Interactive shell with project data

From the project root, after obtaining the GPU allocation:

```bash
export PROJECT_DIR="$PWD"
export WORK_DIR="$SCRATCH/wirecell-spng-work"
mkdir -p "$WORK_DIR" "$PROJECT_DIR/outfiles"

srun --nodes=1 --ntasks=1 --cpus-per-task=8 --gpus-per-task=1 --pty \
    podman-hpc run --rm -it --gpu \
    --volume "$WORK_DIR:/work" \
    --volume "$PROJECT_DIR/wire-cell-data:/opt/wire-cell-toolkit/wire-cell-data:ro" \
    --volume "$PROJECT_DIR/infiles:/opt/wire-cell-toolkit/infiles:ro" \
    --volume "$PROJECT_DIR/outfiles:/opt/wire-cell-toolkit/outfiles" \
    --env WIRECELL_PATH=/opt/wire-cell-toolkit/wire-cell-data:/opt/wire-cell-toolkit/spng/cfg:/opt/wire-cell-toolkit/cfg:/opt/wirecell-view/share/wirecell \
    --ulimit stack=67108864 --workdir /work "$IMAGE" /bin/bash
```

Ensure `wire-cell-data` and `infiles` exist before launching. Container
configuration must use container paths for input files, models, and outputs.
The explicit `WIRECELL_PATH` includes the data mount and corrects the current
Dockerfile's `/opt/wire-cell-view` spelling to `/opt/wirecell-view`.

`run-container.sh` currently defaults to the published image, uses hard-coded
`/global/homes/a/abashyal/...` mounts, and requests `--gpus=all` instead of the
NERSC-documented `--gpu` integration. Use the explicit launch above until the
helper is adapted. The current Dockerfile sets `CMD ["/bin/bash"]`; it does not
run `entrypoint.sh` automatically.

For noninteractive jobs, use the same `srun podman-hpc run --rm --gpu` command
in an `sbatch` script with GPU account, constraint, node/task/CPU/GPU counts,
and walltime directives. Omit `-it` and `--pty`, and replace `/bin/bash` with
your Wire-Cell command. Put active high-I/O outputs under `$SCRATCH` and retain
needed results elsewhere according to your storage requirements.

## CMake/NVTX history and benchmarks

The [successful CMake/NVTX milestone](local-build/knowledge-base/2026-09-29_16-18-13_EDT-cmake-nvtx-build-milestone.md)
records `spng-default-nvtx`, `Dockerfile.CMake`, `build-image-cmake.sh`, and an
NVTX3 compatibility patch. Those container recipe/helper/patch files are not
present in the current root-level checkout. Setting `WCT_REF=spng-default-nvtx`
in the Waf helper does not reproduce that CMake/NVTX build.

If restoring that workflow, preserve its recorded fixes: use
`WCT_WITH_NVTX` (the earlier `CT_WITH_NVTX` option was ignored), account for
header-only NVTX3 rather than requiring `libnvToolsExt.so`, and put compatible
Spack fmt headers before Torch's bundled fmt headers. Resolve Spack package
prefixes dynamically instead of copying hash-qualified installation paths.
The milestone confirms image compilation; GPU execution and visible NVTX
ranges require separate runtime verification.

See the [benchmark instructions](local-build/benchmarks/README.md) for matched
native/container runs. Record image digest, Toolkit revision, CUDA/PyTorch
versions, resource placement, and numerical output agreement before interpreting
performance differences. Allocating more GPUs alone does not distribute a
single SPNG workflow across them.
