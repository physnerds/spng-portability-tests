# Source this file to use the native installation.
source "$(dirname "${BASH_SOURCE[0]}")/setup.sh"
export PATH="$WCT_LOCAL_ROOT/install/bin:$PATH:$WCT_LOCAL_ROOT/deps-view/bin"
export LD_LIBRARY_PATH="$WCT_LOCAL_ROOT/install/lib:$WCT_LOCAL_ROOT/install/lib64:$WCT_LOCAL_ROOT/deps-view/lib:$WCT_LOCAL_ROOT/deps-view/lib64:${LD_LIBRARY_PATH:-}"
if [[ -z "${WCT_DATA_DIR:-}" ]]; then
    if [[ -d "$WCT_LOCAL_ROOT/../wire-cell-data" ]]; then
        export WCT_DATA_DIR="$WCT_LOCAL_ROOT/../wire-cell-data"
    else
        export WCT_DATA_DIR=/global/homes/a/abashyal/spng-portability-tests/wire-cell-data
    fi
fi
export WCT_DATA_DIR
export WIRECELL_PATH="$WCT_DATA_DIR:$WCT_LOCAL_ROOT/wire-cell-toolkit/cfg:$WCT_LOCAL_ROOT/wire-cell-toolkit/spng/cfg:$WCT_LOCAL_ROOT/install/share/wirecell:$WCT_LOCAL_ROOT/deps-view/share/wirecell:${WIRECELL_PATH:-}"
