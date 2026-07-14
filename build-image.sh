#!/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-wirecell-spng}"
IMAGE_TAG="${IMAGE_TAG:-cuda89}"

SPACK_REF="${SPACK_REF:-v1.0.0}"
WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF:-master}"
WIRECELL_TOOLKIT_REF="${WIRECELL_TOOLKIT_REF:-spng}"

USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE:-false}"

HTTP_PROXY="${HTTP_PROXY:-}"
HTTPS_PROXY="${HTTPS_PROXY:-}"
NO_PROXY="${NO_PROXY:-}"

if [[ "${USE_CUSTOM_PACKAGE}" == "true" ]] &&
   [[ ! -f "wirecell-package/package.py" ]]; then
    echo "ERROR: USE_CUSTOM_PACKAGE=true, but this file is missing:"
    echo "  wirecell-package/package.py"
    exit 1
fi

docker build \
    --progress=plain \
    --build-arg SPACK_REF="${SPACK_REF}" \
    --build-arg WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF}" \
    --build-arg WIRECELL_TOOLKIT_REF="${WIRECELL_TOOLKIT_REF}" \
    --build-arg USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE}" \
    --build-arg HTTP_PROXY="${HTTP_PROXY}" \
    --build-arg HTTPS_PROXY="${HTTPS_PROXY}" \
    --build-arg NO_PROXY="${NO_PROXY}" \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    .