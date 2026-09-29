#!/usr/bin/env bash

set -euo pipefail

# ----------------------------------------------------------------------
# Spack environment
# ----------------------------------------------------------------------

export SPACK_ROOT="/opt/spack"
export WCT_ENV_PATH="/opt/wirecell-env"

source "${SPACK_ROOT}/share/spack/setup-env.sh"

# The environment contains Wire-Cell dependencies, but PyTorch and CUDA
# come from the NERSC base image.
spack env activate "${WCT_ENV_PATH}"

# ----------------------------------------------------------------------
# Spack environment view
# ----------------------------------------------------------------------

export WIRECELL_VIEW="/opt/wirecell-view"
export PREFIX="${WIRECELL_VIEW}"

export PATH="${WIRECELL_VIEW}/bin:${PATH}"

export CPATH="${WIRECELL_VIEW}/include:${CPATH:-}"

export LIBRARY_PATH="${WIRECELL_VIEW}/lib:${WIRECELL_VIEW}/lib64:${LIBRARY_PATH:-}"

export LD_LIBRARY_PATH="${WIRECELL_VIEW}/lib:${WIRECELL_VIEW}/lib64:${LD_LIBRARY_PATH:-}"

export PKG_CONFIG_PATH="${WIRECELL_VIEW}/lib/pkgconfig:${WIRECELL_VIEW}/lib64/pkgconfig:${WIRECELL_VIEW}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

# ----------------------------------------------------------------------
# Go Jsonnet
# ----------------------------------------------------------------------

export GOJSONNET_PREFIX="$(
    spack -e "${WCT_ENV_PATH}" location -i go-jsonnet
)"

export CPATH="${GOJSONNET_PREFIX}/include:${CPATH}"

if [[ -d "${GOJSONNET_PREFIX}/lib" ]]; then
    export GOJSONNET_LIBDIR="${GOJSONNET_PREFIX}/lib"
elif [[ -d "${GOJSONNET_PREFIX}/lib64" ]]; then
    export GOJSONNET_LIBDIR="${GOJSONNET_PREFIX}/lib64"
else
    echo "ERROR: go-jsonnet library directory not found" >&2
    exit 1
fi

export LIBRARY_PATH="${GOJSONNET_LIBDIR}:${LIBRARY_PATH}"
export LD_LIBRARY_PATH="${GOJSONNET_LIBDIR}:${LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="${GOJSONNET_LIBDIR}/pkgconfig:${PKG_CONFIG_PATH}"

# ----------------------------------------------------------------------
# NERSC PyTorch / libtorch
#
# PyTorch is supplied by docker.io/nersc/pytorch:24.08.01.
# It is deliberately NOT installed through Spack.
# ----------------------------------------------------------------------

export TORCH_SITE="$(
    python - <<'PY'
import torch
print(torch.__path__[0])
PY
)"

export TDIR="${TORCH_SITE}"

if [[ ! -d "${TDIR}/include" ]]; then
    echo "ERROR: PyTorch include directory not found:"
    echo "  ${TDIR}/include"
    exit 1
fi

if [[ ! -d "${TDIR}/include/torch/csrc/api/include" ]]; then
    echo "ERROR: PyTorch C++ API headers not found:"
    echo "  ${TDIR}/include/torch/csrc/api/include"
    exit 1
fi

if [[ ! -d "${TDIR}/lib" ]]; then
    echo "ERROR: PyTorch library directory not found:"
    echo "  ${TDIR}/lib"
    exit 1
fi

export CPATH="${TDIR}/include:${TDIR}/include/torch/csrc/api/include:${CPATH}"

export LIBRARY_PATH="${TDIR}/lib:${LIBRARY_PATH}"
export LD_LIBRARY_PATH="${TDIR}/lib:${LD_LIBRARY_PATH}"

# ----------------------------------------------------------------------
# NERSC CUDA
# ----------------------------------------------------------------------

export CUDA_PREFIX="/usr/local/cuda"
export CUDA_TARGET="${CUDA_PREFIX}/targets/x86_64-linux"

export PATH="${CUDA_PREFIX}/bin:${PATH}"
export CPATH="${CUDA_TARGET}/include:${CPATH}"

if [[ -d "${CUDA_TARGET}/lib" ]]; then
    export CUDA_LIBDIR="${CUDA_TARGET}/lib"
elif [[ -d "${CUDA_TARGET}/lib64" ]]; then
    export CUDA_LIBDIR="${CUDA_TARGET}/lib64"
elif [[ -d "${CUDA_PREFIX}/lib64" ]]; then
    export CUDA_LIBDIR="${CUDA_PREFIX}/lib64"
else
    echo "ERROR: CUDA library directory not found" >&2
    exit 1
fi

export LIBRARY_PATH="${CUDA_LIBDIR}:${LIBRARY_PATH}"
export LD_LIBRARY_PATH="${CUDA_LIBDIR}:${LD_LIBRARY_PATH}"

# ----------------------------------------------------------------------
# Wire-Cell source and installed files
# ----------------------------------------------------------------------

export WIRECELL_DEV="/opt"
export WIRECELL_TOOLKIT="/opt/wire-cell-toolkit"

export WIRECELL_PATH="${WIRECELL_TOOLKIT}/cfg:${WIRECELL_VIEW}/share/wirecell"
export WIRECELL_PATH="${WIRECELL_TOOLKIT}/spng:${WIRECELL_PATH}"
export WIRECELL_PATH="${WIRECELL_TOOLKIT}/spng/cfg:${WIRECELL_PATH}"
export WIRECELL_PATH="${WIRECELL_TOOLKIT}/wire-cell-data:${WIRECELL_PATH}"

# Source-tree build paths, useful for development/debugging.
export PATH="${WIRECELL_TOOLKIT}/build/apps:${PATH}"
export LD_LIBRARY_PATH="${WIRECELL_TOOLKIT}/build/apps:${LD_LIBRARY_PATH}"

exec "$@"