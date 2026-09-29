#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

IMAGE_NAME="${DEPENDENCY_IMAGE_NAME:-wirecell-spng-deps}"
IMAGE_TAG="${DEPENDENCY_IMAGE_TAG:-perlmutter}"

NERSC_PYTORCH_IMAGE="${NERSC_PYTORCH_IMAGE:-docker.io/nersc/pytorch:24.08.01}"

SPACK_REF="${SPACK_REF:-v1.0.0}"
WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF:-master}"

HTTP_PROXY_VALUE="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY_VALUE="${HTTPS_PROXY:-${https_proxy:-}}"
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-}}"

PODMAN_BUILD_NETWORK="${PODMAN_BUILD_NETWORK:-host}"
NO_CACHE="${NO_CACHE:-false}"

case "${NO_CACHE}" in
    true|false) ;;
    *)
        echo "ERROR: NO_CACHE must be true or false."
        exit 1
        ;;
esac

if ! command -v podman-hpc >/dev/null 2>&1; then
    echo "ERROR: podman-hpc is not available."
    exit 1
fi

BUILD_ARGS=(
    --network="${PODMAN_BUILD_NETWORK}"
    --file Dockerfile.dependencies
    --build-arg "NERSC_PYTORCH_IMAGE=${NERSC_PYTORCH_IMAGE}"
    --build-arg "SPACK_REF=${SPACK_REF}"
    --build-arg "WIRECELL_SPACK_REF=${WIRECELL_SPACK_REF}"
    --build-arg "HTTP_PROXY=${HTTP_PROXY_VALUE}"
    --build-arg "HTTPS_PROXY=${HTTPS_PROXY_VALUE}"
    --build-arg "NO_PROXY=${NO_PROXY_VALUE}"
    --tag "${IMAGE_NAME}:${IMAGE_TAG}"
)

if [[ "${NO_CACHE}" == "true" ]]; then
    BUILD_ARGS+=(--no-cache)
fi

echo "Building Perlmutter Wire-Cell dependency image"
echo "  Base image:       ${NERSC_PYTORCH_IMAGE}"
echo "  Output image:     ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Spack ref:        ${SPACK_REF}"
echo "  WireCell Spack:   ${WIRECELL_SPACK_REF}"
echo "  Build network:    ${PODMAN_BUILD_NETWORK}"
echo "  No cache:         ${NO_CACHE}"
echo

podman-hpc build "${BUILD_ARGS[@]}" .

echo
echo "Dependency image built:"
echo "  ${IMAGE_NAME}:${IMAGE_TAG}"