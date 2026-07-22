#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

IMAGE_NAME="${DEPENDENCY_IMAGE_NAME:-wirecell-spng-deps}"
IMAGE_TAG="${DEPENDENCY_IMAGE_TAG:-cuda89}"

CUDA_IMAGE="${CUDA_IMAGE:-nvidia/cuda:12.4.1-devel-rockylinux9}"
SPACK_REF="${SPACK_REF:-v1.0.0}"
WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF:-master}"
USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE:-true}"

HTTP_PROXY_VALUE="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY_VALUE="${HTTPS_PROXY:-${https_proxy:-}}"
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-}}"

DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-default}"

if [[ "${USE_CUSTOM_PACKAGE}" == "true" ]] &&
   [[ ! -f wirecell-package/package.py ]]; then
    echo "ERROR: wirecell-package/package.py is missing"
    exit 1
fi

sudo docker build \
    --network="${DOCKER_BUILD_NETWORK}" \
    --file Dockerfile.dependencies \
    --progress=plain \
    --build-arg CUDA_IMAGE="${CUDA_IMAGE}" \
    --build-arg SPACK_REF="${SPACK_REF}" \
    --build-arg WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF}" \
    --build-arg USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE}" \
    --build-arg HTTP_PROXY="${HTTP_PROXY_VALUE}" \
    --build-arg HTTPS_PROXY="${HTTPS_PROXY_VALUE}" \
    --build-arg NO_PROXY="${NO_PROXY_VALUE}" \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    .

echo
echo "Dependency image built:"
echo "  ${IMAGE_NAME}:${IMAGE_TAG}"