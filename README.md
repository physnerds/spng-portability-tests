# WireCell SPNG Docker Build
This repository builds a standalone Docker image containing:

- Spack
- `wire-cell-spack`
- WireCell Toolkit SPNG
- CUDA-enabled PyTorch and dependencies
- An optional custom `package.py`

The build does not use a host-side Spack installation or packages installed by another user.

## Files

```
.
├── .dockerignore
├── .gitignore
├── Dockerfile # Dockerfile that builds wire-cell-toolkit based upon the image created from Dockerfile.dependencies
├── Dockerfile.dependencies #Base image that builds dependencies needed for wire-cell-toolkit
├── README.md # This file
├── STATUS.md # Few initial errors when building image were recorded here but not maintained. 
├── bootstrap.sh # One shot script to build wire-cell-toolkit (Two step build process)
├── build-dependencies.sh # Builds the image that contains dependencies for wire-cell
├── build-image.sh #Builds the container with wire-cell-toolkit installed. 
├── entrypoint.sh #Docker uses this script to setup wire-cell related environment variables.
├── run-container.sh # Launch this bash script to run the wire-cell-toolkit/spng container. 
├── setup-wirecell.sh #Obsolete but you can use this in the container to setup environment variables needed to launch apps fron jsonnet files. 
├── spack.yaml # spack.yaml is used to do spack build of wire-cell depdendencies using Dockerfile.dependencies.
└── wirecell-package/ # Obsolete. We do not use spack based wire-cell-toolkit build.
    └── package.py        # optional
```

## Build with default settings
Make the bootstrap script executable:

```
chmod +x bootstrap.sh
```
Build the image:

```
./bootstrap.sh
```
The default image tag is:

```
wirecell-spng:cuda89
```

## Building without a GPU
An NVIDIA GPU is not required to build the image.

The CUDA compiler, headers, and user-space libraries are supplied by the CUDA development base image. CUDA-enabled WireCell and PyTorch packages can therefore be compiled without GPU hardware.

Build normally:

```
./bootstrap.sh
```
Do not perform GPU runtime checks during `docker build`, such as:

```
nvidia-smi
```
or:

```
python3 -c 'import torch; assert torch.cuda.is_available()'
```

## Building with a GPU
The Docker image is built using the same command:

```
./bootstrap.sh
```
A GPU is not normally exposed during `docker build`.

After the image has been built, test GPU access with:

```
docker run --rm \
    --gpus all \
    wirecell-spng:cuda89 \
    nvidia-smi
```
Check CUDA-enabled PyTorch with:

```
docker run --rm \
    --gpus all \
    wirecell-spng:cuda89 \
    python3 -c '
import torch

print("PyTorch:", torch.__version__)
print("CUDA build:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
'
```

# Building the wire-cell-toolkit on existing wirecell-spng:cuda89 container
Rebuilding the wirecellospng:cuda89 is very time consuming since it builds everything from scratch including llvm, torch and cuda toolkit. 
So, if you want to test different variant of wire-cell-tookit only, just run the `build-image.sh` script. 
```bash
./build-image.sh # Caching is on. Previous Docker builds are cached during current build session
```

```bash
NO_CACHE=true ./build-image.sh # Caching is off. Previous Docker builds are not cached. So, the build session starts from the beginning. 
```

## CUDA version consistency
The CUDA version in the Docker base image must match the external CUDA version declared in `spack.yaml`.

For example, this Docker base image:

```
FROM nvidia/cuda:12.4.1-devel-rockylinux9
```
must be consistent with:

```
packages:
  cuda:
    externals:
      - spec: cuda@12.4
        prefix: /usr/local/cuda
    buildable: false
```
The versions do not need identical patch-level notation, but they must represent the same CUDA toolkit series.

This configuration is consistent:

```
Docker image:  CUDA 12.4.1
Spack external: cuda@12.4
```
This configuration is not consistent:

```
Docker image:  CUDA 12.6
Spack external: cuda@12.4
```
Verify the CUDA toolkit inside the built image:

```
docker run --rm \
    wirecell-spng:cuda89 \
    nvcc --version
```
Changing the CUDA base image may require updating:

- The CUDA external declaration in `spack.yaml`
- The concrete dependency graph
- `spack.lock`
- The supported NVIDIA driver version on the runtime host

## GPU architecture
The default build uses:

```
cuda_arch=89
```
This is appropriate for GPUs such as:

- NVIDIA L40S
- NVIDIA RTX 4090

Common alternatives are:

```
A100:                 cuda_arch=80
A10 or RTX 3090:      cuda_arch=86
L40S or RTX 4090:     cuda_arch=89
H100:                 cuda_arch=90
```
For another GPU architecture, update the WireCell specification in `spack.yaml`.

Changing `cuda_arch` requires reconcretizing the Spack environment and regenerating `spack.lock` when a lockfile is used.

## Build output
List the resulting image:

```
docker images wirecell-spng
```
Verify WireCell:

```
docker run --rm \
    wirecell-spng:cuda89 \
    bash -lc '
        which wire-cell
        wire-cell --version
    '
```

