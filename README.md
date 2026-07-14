# WireCell SPNG Docker Build

This repository builds a standalone Docker image containing:

* Spack
* `wire-cell-spack`
* WireCell Toolkit SPNG
* CUDA-enabled PyTorch and dependencies
* An optional custom `package.py`

The build does not use a host-side Spack installation or packages installed by another user.

## Files

```text
.
├── Dockerfile
├── README.md
├── Instructions.md
├── bootstrap.sh
├── build-image.sh
├── entrypoint.sh
├── run-container.sh
├── setup-wirecell.sh
├── spack.yaml
└── wirecell-package/
    └── package.py        # optional
```

## Build with default settings

Run:

```bash
chmod +x bootstrap.sh
./bootstrap.sh
```

The default image is:

```text
wirecell-spng:cuda89
```

By default, the build uses the `package.py` provided by the cloned `wire-cell-spack` repository.

## Build with a custom `package.py`

Place the custom recipe at:

```text
wirecell-package/package.py
```

Then run:

```bash
USE_CUSTOM_PACKAGE=false ./bootstrap.sh
```

Turning this mode on may be used for local recipe changes such as an added `+nvtx` variant.

## Building on a machine without a GPU

An NVIDIA GPU is not required to build the image.

The CUDA compiler, headers, and user-space libraries are supplied by the CUDA development base image. CUDA-enabled WireCell and PyTorch packages can therefore be compiled without GPU hardware.

Build normally:

```bash
./bootstrap.sh
```

Do not perform GPU runtime checks during `docker build`, such as:

```bash
nvidia-smi
```

or:

```bash
python3 -c 'import torch; assert torch.cuda.is_available()'
```

## Building on a machine with a GPU

The image is built using the same command:

```bash
./bootstrap.sh
```

A GPU is still not normally exposed during `docker build`.

After the image has been built, GPU access can be tested with:

```bash
docker run --rm \
    --gpus all \
    wirecell-spng:cuda89 \
    nvidia-smi
```

Check CUDA-enabled PyTorch with:

```bash
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

```dockerfile
FROM nvidia/cuda:12.4.1-devel-rockylinux9
```

must be consistent with:

```yaml
packages:
  cuda:
    externals:
      - spec: cuda@12.4
        prefix: /usr/local/cuda
    buildable: false
```

The version numbers do not need to include the same patch-level notation, but they must represent the same CUDA toolkit series.

For example:

```text
Docker image: CUDA 12.4.1
Spack external: cuda@12.4
```

is consistent.

This would not be consistent:

```text
Docker image: CUDA 12.6
Spack external: cuda@12.4
```

Verify the toolkit in the built image with:

```bash
docker run --rm \
    wirecell-spng:cuda89 \
    nvcc --version
```

Changing the CUDA base image may require updating:

* The CUDA external declaration in `spack.yaml`
* The concrete dependency graph
* `spack.lock`
* The supported NVIDIA driver version on the runtime host

## GPU architecture

The default build uses:

```text
cuda_arch=89
```

This is appropriate for GPUs such as:

* NVIDIA L40S
* NVIDIA RTX 4090

For another GPU architecture, override the WireCell spec when building or modify `spack.yaml`.

Examples:

```text
A100: cuda_arch=80
A10 or RTX 3090: cuda_arch=86
L40S or RTX 4090: cuda_arch=89
H100: cuda_arch=90
```

Changing `cuda_arch` requires reconcretizing the Spack environment.

## Build outputs

The default Docker image tag is:

```text
wirecell-spng:cuda89
```

List the image with:

```bash
docker images wirecell-spng
```

Verify WireCell with:

```bash
docker run --rm \
    wirecell-spng:cuda89 \
    bash -lc '
        which wire-cell
        wire-cell --version
    '
```
