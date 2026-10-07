# Source from bash; keep all Spack state within this project.
WCT_LOCAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module load pytorch/2.8.0 cmake/3.30.2
export SPACK_ROOT=/global/common/software/nersc9/spack/1.0.4
export SPACK_PYTHON=/global/homes/a/abashyal/miniconda3/bin/python3
export SPACK_USER_CONFIG_PATH="$WCT_LOCAL_ROOT/spack-config"
export SPACK_USER_CACHE_PATH="$WCT_LOCAL_ROOT/spack-cache/user"
export SPACK_DISABLE_LOCAL_CONFIG=true
source "$SPACK_ROOT/share/spack/setup-env.sh"
export WCT_SPACK_ENV="$WCT_LOCAL_ROOT/spack-env"
