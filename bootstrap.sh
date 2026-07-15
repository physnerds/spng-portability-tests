
#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

IMAGE_NAME="${IMAGE_NAME:-wirecell-spng}"
IMAGE_TAG="${IMAGE_TAG:-cuda89}"

SPACK_REF="${SPACK_REF:-v1.0.0}"
WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF:-master}"
WIRECELL_TOOLKIT_REF="${WIRECELL_TOOLKIT_REF:-spng}"

USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE:-false}"

HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

case "${USE_CUSTOM_PACKAGE}" in
    true|false)
        ;;
    *)
        echo "ERROR: USE_CUSTOM_PACKAGE must be either true or false."
        exit 1
        ;;
esac

if [[ "${USE_CUSTOM_PACKAGE}" == "true" ]] &&
   [[ ! -f "${PROJECT_DIR}/wirecell-package/package.py" ]]; then
    echo "ERROR: Custom package mode was requested, but this file is missing:"
    echo
    echo "  ${PROJECT_DIR}/wirecell-package/package.py"
    echo
    exit 1
fi

required_files=(
    Dockerfile
    spack.yaml
    entrypoint.sh
)

for required_file in "${required_files[@]}"; do
    if [[ ! -f "${PROJECT_DIR}/${required_file}" ]]; then
        echo "ERROR: Required file is missing:"
        echo
        echo "  ${PROJECT_DIR}/${required_file}"
        echo
        exit 1
    fi
done

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker was not found in PATH."
    exit 1
fi

echo "Building WireCell SPNG Docker image"
echo
echo "  Image:                 ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Spack reference:       ${SPACK_REF}"
echo "  wire-cell-spack ref:   ${WIRECELL_SPACK_REF}"
echo "  WireCell Toolkit ref:  ${WIRECELL_TOOLKIT_REF}"
echo "  Custom package.py:     ${USE_CUSTOM_PACKAGE}"
echo

sudo docker build \
    --progress=plain \
    --build-arg SPACK_REF="${SPACK_REF}" \
    --build-arg WIRECELL_SPACK_REF="${WIRECELL_SPACK_REF}" \
    --build-arg WIRECELL_TOOLKIT_REF="${WIRECELL_TOOLKIT_REF}" \
    --build-arg USE_CUSTOM_PACKAGE="${USE_CUSTOM_PACKAGE}" \
    --build-arg HTTP_PROXY="${HTTP_PROXY}" \
    --build-arg HTTPS_PROXY="${HTTPS_PROXY}" \
    --build-arg NO_PROXY="${NO_PROXY}" \
    --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
    "${PROJECT_DIR}"

echo
echo "Docker image built successfully:"
echo
echo "  ${IMAGE_NAME}:${IMAGE_TAG}"
echo
echo "Verify the installation with:"
echo
echo "  docker run --rm ${IMAGE_NAME}:${IMAGE_TAG} wire-cell --version"
