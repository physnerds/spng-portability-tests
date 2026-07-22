#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

DEPENDENCY_IMAGE="${DEPENDENCY_IMAGE:-wirecell-spng-deps:cuda89}"

IMAGE_NAME="${IMAGE_NAME:-wirecell-spng}"
IMAGE_TAG="${IMAGE_TAG:-cuda89}"

USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE:-true}"
PACKAGE_RECIPE_REV="${PACKAGE_RECIPE_REV:-1}"
DOCKER_BUILD_NETWORK="${DOCKER_BUILD_NETWORK:-default}"

case "${USE_CUSTOM_PACKAGE}" in
    true|false)
        ;;
    *)
        echo "ERROR: USE_CUSTOM_PACKAGE must be true or false."
        exit 1
        ;;
esac

if [[ "${USE_CUSTOM_PACKAGE}" == "true" ]] &&
   [[ ! -f wirecell-package/package.py ]]; then
    echo "ERROR: wirecell-package/package.py is missing"
    exit 1
fi

# Select Docker access consistently for both inspect and build.
if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
elif sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
else
    echo "ERROR: Cannot access the Docker daemon."
    echo
    echo "Try:"
    echo "  sudo docker info"
    exit 1
fi

if ! "${DOCKER[@]}" image inspect "${DEPENDENCY_IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: Dependency image does not exist:"
    echo "  ${DEPENDENCY_IMAGE}"
    echo
    echo "Available WireCell dependency images:"
    "${DOCKER[@]}" images \
        --format '{{.Repository}}:{{.Tag}}' \
        | grep '^wirecell-spng-deps:' || true
    exit 1
fi

echo "Building WireCell image"
echo "  Dependency image:  ${DEPENDENCY_IMAGE}"
echo "  Output image:      ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Custom package.py: ${USE_CUSTOM_PACKAGE}"
echo "  Recipe revision:   ${PACKAGE_RECIPE_REV}"
echo "  Build network:     ${DOCKER_BUILD_NETWORK}"

"${DOCKER[@]}" build \
    --network="${DOCKER_BUILD_NETWORK}" \
    --file Dockerfile \
    --progress=plain \
    --build-arg DEPENDENCY_IMAGE="${DEPENDENCY_IMAGE}" \
    --build-arg USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE}" \
    --build-arg PACKAGE_RECIPE_REV="${PACKAGE_RECIPE_REV}" \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    .

echo
echo "WireCell image built:"
echo "  ${IMAGE_NAME}:${IMAGE_TAG}"