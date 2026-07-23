#!/usr/bin/env bash

set -e

# ----------------------------------------------------------------------
# Spack environment
# ----------------------------------------------------------------------

export SPACK_ROOT="/opt/spack"
export WCT_ENV_PATH="/opt/wirecell-env"

source "${SPACK_ROOT}/share/spack/setup-env.sh"
spack env activate "${WCT_ENV_PATH}"

# ----------------------------------------------------------------------
# Spack environment view
# ----------------------------------------------------------------------

export WIRECELL_VIEW="/opt/wirecell-view"
export PREFIX="${WIRECELL_VIEW}"

export PATH="${WIRECELL_VIEW}/bin:${PATH}"
export LD_LIBRARY_PATH="${WIRECELL_VIEW}/lib:${WIRECELL_VIEW}/lib64:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="${WIRECELL_VIEW}/lib/pkgconfig:${WIRECELL_VIEW}/lib64/pkgconfig:${WIRECELL_VIEW}/share/pkgconfig:${PKG_CONFIG_PATH:-}"

# ----------------------------------------------------------------------
# Native Jsonnet
# ----------------------------------------------------------------------

export JSONNET_PREFIX="$(
    spack -e "${WCT_ENV_PATH}" location -i jsonnet
)"

export CPATH="${JSONNET_PREFIX}/include:${CPATH:-}"
export LIBRARY_PATH="${JSONNET_PREFIX}/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${JSONNET_PREFIX}/lib:${LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="${JSONNET_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"

# ----------------------------------------------------------------------
# PyTorch / libtorch
# ----------------------------------------------------------------------

export PYTORCH_PREFIX="$(
    spack -e "${WCT_ENV_PATH}" location -i py-torch
)"

export PYTORCH_SITEPKG="$(
    find "${PYTORCH_PREFIX}" \
        -type d \
        -path '*/site-packages' \
        -print \
        -quit
)"

export TORCH_SITE="${PYTORCH_SITEPKG}/torch"
export TDIR="${TORCH_SITE}"

export PYTHONPATH="${PYTORCH_SITEPKG}:${PYTHONPATH:-}"
export CPATH="${TORCH_SITE}/include:${TORCH_SITE}/include/torch/csrc/api/include:${CPATH}"
export LIBRARY_PATH="${TORCH_SITE}/lib:${LIBRARY_PATH}"
export LD_LIBRARY_PATH="${TORCH_SITE}/lib:${LD_LIBRARY_PATH}"

# ----------------------------------------------------------------------
# CUDA
# ----------------------------------------------------------------------

export CUDA_PREFIX="/usr/local/cuda"
export CUDA_TARGET="${CUDA_PREFIX}/targets/x86_64-linux"

export PATH="${CUDA_PREFIX}/bin:${PATH}"
export CPATH="${CUDA_TARGET}/include:${CPATH}"
export LD_LIBRARY_PATH="${CUDA_TARGET}/lib:${CUDA_PREFIX}/lib64:${LD_LIBRARY_PATH}"

# ----------------------------------------------------------------------
# Wire-Cell source and installed files
# ----------------------------------------------------------------------

export WIRECELL_DEV="/opt"
export WIRECELL_TOOLKIT="/opt/wire-cell-toolkit"

export WIRECELL_PATH="${WIRECELL_TOOLKIT}/cfg:${WIRECELL_VIEW}/share/wirecell"
export WIRECELL_PATH="${WIRECELL_TOOLKIT}/spng:${WIRECELL_PATH}"
export WIRECELL_PATH="${WIRECELL_TOOLKIT}/spng/cfg:${WIRECELL_PATH}"
export WIRECELL_PATH="${WIRECELL_TOOLKIT}/wire-cell-data:${WIRECELL_PATH}"

# Source-tree build paths, useful for development and debugging.
export PATH="${WIRECELL_TOOLKIT}/build/apps:${PATH}"
export LD_LIBRARY_PATH="${WIRECELL_TOOLKIT}/build/apps:${LD_LIBRARY_PATH}"

exec "$@"