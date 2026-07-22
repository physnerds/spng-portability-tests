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
├── Dockerfile
├── Dockerfile.dependencies
├── README.md
├── STATUS.md
├── bootstrap.sh
├── build-dependencies.sh
├── build-image.sh
├── entrypoint.sh
├── run-container.sh
├── setup-wirecell.sh
├── spack.yaml
└── wirecell-package/
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
By default, the build uses the `package.py` provided by the cloned `wire-cell-spack` repository.

## Docker network workaround
Some Docker installations may fail to resolve the Rocky Linux package mirrors during the `dnf install` step:

```
Failed to download metadata for repo 'baseos'
Curl error (28): Timeout was reached
```
The affected URL can be tested with:

```
sudo docker run --rm \
    nvidia/cuda:12.4.1-devel-rockylinux9 \
    curl -v --connect-timeout 30 \
    'https://mirrors.rockylinux.org/mirrorlist?arch=x86_64&repo=BaseOS-9'
```
When the default Docker build network cannot reach the mirror, build using the host network:

```
DOCKER_BUILD_NETWORK=host ./bootstrap.sh
```
When Docker requires elevated privileges:

```
sudo -E env \
    DOCKER_BUILD_NETWORK=host \
    ./bootstrap.sh
```
The `-E` option preserves environment variables such as site-specific proxy settings.

## Build with a custom `package.py`
Place the custom recipe at:

```
wirecell-package/package.py
```
Then run:

```
USE_CUSTOM_PACKAGE=true ./bootstrap.sh
```
To combine the custom recipe with the Docker host-network workaround:

```
USE_CUSTOM_PACKAGE=true \
DOCKER_BUILD_NETWORK=host \
./bootstrap.sh
```
Custom package mode may be used for recipe changes such as an added `+nvtx` variant or changes to WireCell patch conditions.

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
Additional runtime, profiling, troubleshooting, proxy, image-transfer, and Spack lockfile instructions are documented in `Instructions.md`.
