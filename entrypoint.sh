#!/usr/bin/env bash

set -e

export SPACK_ROOT=/opt/spack
export SPACK_DISABLE_LOCAL_CONFIG=true
export SPACK_USER_CACHE_PATH=/opt/spack-cache/user

# shellcheck disable=SC1091
source "${SPACK_ROOT}/share/spack/setup-env.sh"

spack env activate /opt/wirecell-env

export WCT_ENV=/opt/wirecell-env
export WCT_DEV=/opt/wire-cell-toolkit
export SPACK_VIEW=/opt/wirecell-view

export PATH="${SPACK_VIEW}/bin:${PATH}"
export LD_LIBRARY_PATH="${SPACK_VIEW}/lib:${SPACK_VIEW}/lib64:/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

exec "$@"