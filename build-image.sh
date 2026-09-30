#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

DEPENDENCY_IMAGE="${DEPENDENCY_IMAGE:-docker.io/abashyal/wirecell-spng-deps:cuda80}"

IMAGE_NAME="${IMAGE_NAME:-wirecell-spng}"
IMAGE_TAG="${IMAGE_TAG:-cuda80}"

WCT_REPOSITORY="${WCT_REPOSITORY:-https://github.com/WireCell/wire-cell-toolkit.git}"
WCT_REF="${WCT_REF:-spng}"

BUILD_JOBS="${BUILD_JOBS:-4}"
PODMAN_BUILD_NETWORK="${PODMAN_BUILD_NETWORK:-host}"
NO_CACHE="${NO_CACHE:-false}"

if ! [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: BUILD_JOBS must be a positive integer."
    exit 1
fi

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

if ! podman-hpc image inspect "${DEPENDENCY_IMAGE}" >/dev/null 2>&1; then
    echo "Dependency image not found locally:"
    echo "  ${DEPENDENCY_IMAGE}"
    echo
    echo "Attempting to pull dependency image..."

    if ! podman-hpc pull "${DEPENDENCY_IMAGE}"; then
        echo
        echo "ERROR: Dependency image was not found locally and could not be pulled:"
        echo "  ${DEPENDENCY_IMAGE}"
        exit 1
    fi

    echo
    echo "Successfully pulled:"
    echo "  ${DEPENDENCY_IMAGE}"
fi

BUILD_ARGS=(
    --network="${PODMAN_BUILD_NETWORK}"
    --file Dockerfile
    --build-arg "DEPENDENCY_IMAGE=${DEPENDENCY_IMAGE}"
    --build-arg "WCT_REPOSITORY=${WCT_REPOSITORY}"
    --build-arg "WCT_REF=${WCT_REF}"
    --build-arg "BUILD_JOBS=${BUILD_JOBS}"
    --tag "${IMAGE_NAME}:${IMAGE_TAG}"
)

if [[ "${NO_CACHE}" == "true" ]]; then
    BUILD_ARGS+=(--no-cache)
fi

echo "Building final Perlmutter Wire-Cell SPNG image"
echo "  Dependency image: ${DEPENDENCY_IMAGE}"
echo "  Output image:     ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  WCT repository:   ${WCT_REPOSITORY}"
echo "  WCT ref:          ${WCT_REF}"
echo "  Build jobs:       ${BUILD_JOBS}"
echo "  Build network:    ${PODMAN_BUILD_NETWORK}"
echo "  No cache:         ${NO_CACHE}"
echo

podman-hpc build "${BUILD_ARGS[@]}" .

echo
echo "Wire-Cell image built:"
echo "  ${IMAGE_NAME}:${IMAGE_TAG}"