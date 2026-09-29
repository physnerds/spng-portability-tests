# Wire-Cell dependency image overview

This container is the dependency image based on which you can build wire-cell-toolkit. You can create a container and another image with any branch of wire-cell-toolkit using `wct` or `cmake` builds. From the [spng-portability-repo](https://github.com/physnerds/spng-portability-tests/tree/main),
`build-dependencies.sh` builds this intermediate image `wirecell-spng-deps:cuda89`. This image provides the compiler, CUDA toolkit, Spack environment, CUDA-enabled PyTorch, and other libraries needed to build Wire-Cell Toolkit. It intentionally installs only the dependencies of the Wire-Cell Spack specification; Wire-Cell Toolkit itself is built later by
`build-image.sh` (for wct build) or `build-image-cmake.sh` (cmake based build).

## Platform and principal versions

| Component | Version or configuration | Source |
| --- | --- | --- |
| Operating system | Rocky Linux 9 | Inherited from `nvidia/cuda:12.4.1-devel-rockylinux9` |
| CUDA development image | CUDA 12.4 Update 1 | Default `CUDA_IMAGE` in `build-dependencies.sh` |
| CUDA compiler/toolkit | `nvcc` 12.4.131 observed; declared to Spack as external `cuda@12.4` | `/usr/local/cuda` |
| GPU architecture | `cuda_arch=89` (`sm_89`) | `spack.yaml` |
| Host compiler | GCC/G++/GFortran 11.5.0 | Rocky Linux system compiler, declared external to Spack |
| Wire-Cell Spack recipes | `master` | Default `WIRECELL_SPACK_REF`; this is a moving branch that ensures dependencies for latest wire-cell-toolkit |
| PyTorch | Spack `py-torch` 2.13.0 with CUDA support in the currently observed concretization | Installed under `/opt/spack-install` and projected into the view |
| Python | 3.13.13 in the currently observed concretization | Spack dependency of PyTorch and other packages |
| CMake | 3.31.12 in the currently observed concretization | Spack-installed build dependency |
| gcc | 11.5.0 | `/usr/bin/gcc`

The base-image tag pins the CUDA release series, while the external declaration
in `spack.yaml` tells Spack to use the toolkit already at `/usr/local/cuda`
instead of building another copy. Keep these two settings consistent.

Individual CUDA library packages such as cuBLAS, cuFFT, cuRAND, cuSOLVER,
cuSPARSE, NVRTC, and the CUDA runtime come from the NVIDIA development image.
Their exact RPM patch versions are determined by that image digest. Query the
locally built image when exact component-level versions are needed:

```bash
docker run --rm wirecell-spng-deps:cuda89 bash -lc '
    nvcc --version
    rpm -qa --qf "%{NAME} %{VERSION}-%{RELEASE}\n" |
        grep -E "^(cuda|libcu|libnv|nsight|nvidia)" |
        sort
'
```

The NVIDIA host driver is not part of the image. At runtime, the NVIDIA
Container Toolkit exposes the host driver and GPU devices when the container
is started with `--gpus all`.

## What the build installs

The input specification is:

```text
wire-cell-toolkit@spng +cuda +torch cuda_arch=89 %gcc@11.5.0
```

Docker runs `spack install --only dependencies`, so this root specification is
used to calculate the complete dependency graph without installing
`wire-cell-toolkit`. The graph includes CUDA-enabled PyTorch and its build and
runtime dependencies, as well as the libraries required by Wire-Cell, such as
Boost, FFTW, TBB, JsonCpp, Jsonnet, Eigen, spdlog, fmt, compression libraries,
and CMake.

Because most dependency versions are selected by Spack's concretizer rather
than pinned directly in `spack.yaml`, inspect `spack.lock` or use `spack find`
inside the image for the authoritative versions of a particular build.

## Filesystem layout

| Path | Purpose |
| --- | --- |
| `/opt/spack` | Spack v1.0.0 source tree and CLI |
| `/opt/wire-cell-spack` | Wire-Cell package repository used during concretization |
| `/opt/wirecell-env` | Spack environment containing `spack.yaml` and the generated `spack.lock` |
| `/opt/spack-install` | Hash-qualified installation prefixes for concrete packages |
| `/opt/wirecell-view` | Unified Spack view with convenient `bin`, `include`, `lib`, and `share` paths |
| `/usr/local/cuda` | CUDA 12.4 toolkit supplied by the NVIDIA base image |
| `/opt/spack-cache` | Spack cache mount point used while building the image |
| `/opt/spack-stage` | Spack build-stage mount point used while building the image |

The BuildKit cache mounts accelerate repeated builds but their cached contents
are managed outside the image layers. Do not treat `/opt/spack-cache` or
`/opt/spack-stage` as installed software locations.

## Building the image

Build with the repository defaults:

```bash
./build-dependencies.sh
```

The most useful settings can be overridden as environment variables:

```bash
DEPENDENCY_IMAGE_NAME=wirecell-spng-deps \
DEPENDENCY_IMAGE_TAG=cuda89 \
CUDA_IMAGE=nvidia/cuda:12.4.1-devel-rockylinux9 \
SPACK_REF=v1.0.0 \
WIRECELL_SPACK_REF=master \
DOCKER_BUILD_NETWORK=default \
./build-dependencies.sh
```

Proxy variables `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY` are forwarded to
the Docker build. Lowercase host proxy variables are also recognized.

`build-dependencies.sh` currently defaults `USE_CUSTOM_PACKAGE=true` and checks
that `wirecell-package/package.py` exists, but `Dockerfile.dependencies` does
not consume that build argument or copy that package. The active Wire-Cell
recipe source is `/opt/wire-cell-spack`.

## Entering and navigating the dependency image

Start an interactive shell:

```bash
docker run --rm -it wirecell-spng-deps:cuda89 bash
```

Unlike the final Wire-Cell image, this intermediate image does not install or
run `entrypoint.sh`. Initialize Spack and activate the environment manually:

```bash
source /opt/spack/share/spack/setup-env.sh
spack env activate /opt/wirecell-env
```

