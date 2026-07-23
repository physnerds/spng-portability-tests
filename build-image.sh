#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

DEPENDENCY_IMAGE="${DEPENDENCY_IMAGE:-wirecell-spng-deps:cuda89}"
IMAGE_NAME="${IMAGE_NAME:-wirecell-spng}"
IMAGE_TAG="${IMAGE_TAG:-cuda89}"
WCT_REPOSITORY="${WCT_REPOSITORY:-https://github.com/WireCell/wire-cell-toolkit.git}"
WCT_REF="${WCT_REF:-spng}"
BUILD_JOBS="${BUILD_JOBS:-16}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-default}"
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

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
else
    echo "ERROR: Cannot access the Docker daemon."
    echo "Try: sudo docker info"
    exit 1
fi

if ! "${DOCKER[@]}" image inspect "${DEPENDENCY_IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: Dependency image does not exist: ${DEPENDENCY_IMAGE}"
    echo "Available dependency images:"
    "${DOCKER[@]}" images --format '{{.Repository}}:{{.Tag}}' | grep '^wirecell-spng-deps:' || true
    exit 1
fi

BUILD_ARGS=(
    --network="${DOCKER_BUILD_NETWORK}"
    --file Dockerfile
    --progress=plain
    --build-arg "DEPENDENCY_IMAGE=${DEPENDENCY_IMAGE}"
    --build-arg "WCT_REPOSITORY=${WCT_REPOSITORY}"
    --build-arg "WCT_REF=${WCT_REF}"
    --build-arg "BUILD_JOBS=${BUILD_JOBS}"
    --tag "${IMAGE_NAME}:${IMAGE_TAG}"
)

if [[ "${NO_CACHE}" == "true" ]]; then
    BUILD_ARGS+=(--no-cache)
fi

echo "Building final Wire-Cell SPNG image"
echo "  Dependency image: ${DEPENDENCY_IMAGE}"
echo "  Output image:     ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  WCT repository:   ${WCT_REPOSITORY}"
echo "  WCT ref:          ${WCT_REF}"
echo "  Build jobs:       ${BUILD_JOBS}"
echo "  Build network:    ${DOCKER_BUILD_NETWORK}"
echo "  No cache:         ${NO_CACHE}"

"${DOCKER[@]}" build "${BUILD_ARGS[@]}" .

echo
echo "Wire-Cell image built: ${IMAGE_NAME}:${IMAGE_TAG}"
