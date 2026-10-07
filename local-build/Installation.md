# Installation

## Pre-requisites

Use a Bash shell on Perlmutter with access to NERSC modules and network access
for Spack downloads. Work from this project root:

```bash
cd /global/homes/a/abashyal/spng-portability-tests
```

The prepared `local-build` directory contains the `spng` source checkout,
WireCell Spack recipes, environment manifest/lockfile, and setup/build scripts.
The manifest uses absolute paths; adjust those paths and `setup.sh` if moving
the installation to another workspace or account.

The local source patch [wct-cmake-nvtx3.patch](patches/wct-cmake-nvtx3.patch)
is already applied. For a fresh checkout at revision `a8d61722`, apply it before
building:

```bash
git -C local-build/wire-cell-toolkit apply --check ../patches/wct-cmake-nvtx3.patch
git -C local-build/wire-cell-toolkit apply ../patches/wct-cmake-nvtx3.patch
```

## GCC and Pytorch from Module

```bash
module load gcc-native/13.2 cudatoolkit/12.9 pytorch/2.8.0 cmake/3.30.2
source local-build/setup.sh
```

`pytorch/2.8.0` depends on GCC 13.2 and CUDA 12.9. Its Torch 2.8.0+cu129
uses the C++11 ABI. `setup.sh` also selects NERSC Spack 1.0.4 and keeps Spack
configuration, cache, staging, and bootstrap state under `local-build`.
CUDA, GCC, Python, and PyTorch are reused; Spack does not install `py-torch`.
Keep the module Python ahead of `deps-view/bin` in `PATH`.

## Other Dependencies

[spack-env/spack.yaml](spack-env/spack.yaml) defines the environment;
[spack-env/spack.lock](spack-env/spack.lock) records the resolved graph.
Dependencies are based on `Dockerfile.dependencies`, with versions adapted
to Spack 1.0.4's package definitions.

| Dependency | Version |
| --- | --- |
| Boost / Eigen / FFTW | 1.88.0 / 3.4.0 / 3.3.10 |
| fmt / spdlog | 8.1.1 / 1.10.0 |
| go-jsonnet / JsonCpp | 0.22.0 / 1.9.6 |
| Intel TBB / pkgconf | 2022.0.0 / 2.3.0 |
| bzip2 / zlib-ng | 1.0.8 / 2.2.4 |
| wire-cell-data | 0.2.0 |

To install or resume dependencies separately:

```bash
source local-build/setup.sh
spack -e "$WCT_SPACK_ENV" concretize
spack -e "$WCT_SPACK_ENV" install --fail-fast --show-log-on-error -j 4
spack -e "$WCT_SPACK_ENV" env view regenerate
```

After changing manifest versions or external packages, regenerate the graph
with `spack -e "$WCT_SPACK_ENV" concretize --force --fresh`.
Dependencies install into `local-build/spack-install`; the unified view is
`local-build/deps-view`. For runtime data, `activate.sh` also includes the
existing project `wire-cell-data` checkout, with the documented shared fallback.

## Build Instructions

Run the complete, resumable dependency installation and CMake build:

```bash
bash local-build/build.sh
```

[build.sh](build.sh) configures `Release`, selects GCC, and enables
`WITH_LIBTORCH=yes`, `WCT_WITH_SPNG=ON`, and `WCT_WITH_NVTX=ON`.
It uses CUDA architecture 80, four build workers, and disables the test suite.
NVTX3 headers come from CUDA 12.9; the patch supplies them to Pgraph and SPNG.
The script places fmt headers before Torch's bundled headers.

| Output | Location |
| --- | --- |
| CMake build | `local-build/build-gcc` |
| Installed executable and libraries | `local-build/install` |
| Configure / compile / install logs | `local-build/logs` |

Activate with `source local-build/activate.sh`, then follow the workflow steps
in [README.md](README.md#running-wire-cell-toolkit-spng-branch-locally-in-perlmutter).
