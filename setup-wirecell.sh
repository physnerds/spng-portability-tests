#!/usr/bin/env bash

SCRIPT_PATH="${BASH_SOURCE[0]}"
PROJECT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

export http_proxy="${http_proxy:-http://proxy.sdcc.bnl.local:3128/}"
export https_proxy="${https_proxy:-http://proxy.sdcc.bnl.local:3128/}"

export SPACK_USER_CACHE_PATH="${PROJECT_DIR}/cache/user"
export SPACK_DISABLE_LOCAL_CONFIG=true

if [[ ! -f "${PROJECT_DIR}/spack/share/spack/setup-env.sh" ]]; then
    echo "Standalone Spack installation not found."
    echo "Run:"
    echo "  ${PROJECT_DIR}/bootstrap.sh"
    return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1091
source "${PROJECT_DIR}/spack/share/spack/setup-env.sh"

spack env activate -d "${PROJECT_DIR}"

export WCT_ENV="${PROJECT_DIR}"
export WCT_DEV="${PROJECT_DIR}/wire-cell-toolkit"
export SPACK_VIEW="${PROJECT_DIR}/.spack-env/view"

if [[ -d "${SPACK_VIEW}/bin" ]]; then
    export PATH="${SPACK_VIEW}/bin:${PATH}"
fi

if [[ -d "${SPACK_VIEW}/lib" ]]; then
    export LD_LIBRARY_PATH="${SPACK_VIEW}/lib:${LD_LIBRARY_PATH:-}"
fi

if [[ -d "${SPACK_VIEW}/lib64" ]]; then
    export LD_LIBRARY_PATH="${SPACK_VIEW}/lib64:${LD_LIBRARY_PATH:-}"
fi

echo "WireCell standalone environment activated"
echo "  Project:    ${PROJECT_DIR}"
echo "  Spack:      $(command -v spack)"
echo "  WCT source: ${WCT_DEV}"
echo "  View:       ${SPACK_VIEW}"