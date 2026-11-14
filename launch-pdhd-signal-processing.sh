#!/usr/bin/env bash
# Run the PDHD deposit -> ADC -> SPNG workflow in Apptainer on SGPU.
# All host-side inputs, outputs, and the SIF must be on Condor-visible /gpfs.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: launch-pdhd-signal-processing.sh DEVICE [OUTPUT_DIR]

DEVICE is cpu or gpu.  The default input is the 32-event archive produced by
launch-line-depos-generation.sh.  Override paths/settings with:

  PROJECT_DIR       /gpfs/.../spng-portability-tests
  IMAGE             /gpfs/.../wirecell-spng-cuda89.sif
  LINE_DEPO_INPUT   /gpfs/.../generated-depos.npz
  MODEL             /gpfs/.../legacy_roiuniter_091026_5epochs.ts
  EVENTS            number of deposit events to process (default: 32)
  WC_CORES          TbbFlow threads for SPNG (default: 4)
  TORCH_THREADS     Torch/BLAS threads (default: 1)

For DEVICE=gpu, the job must receive exactly one CUDA_VISIBLE_DEVICES token.
EOF
}

device=${1:-}
case "$device" in
    cpu|gpu) ;;
    -h|--help|'') usage; exit 0 ;;
    *) echo "DEVICE must be cpu or gpu, got: $device" >&2; usage >&2; exit 2 ;;
esac

PROJECT_DIR=${PROJECT_DIR:-/gpfs/mnt/gpfs01/lbne/users/spng/abashyal/spng-portability-tests}
IMAGE=${IMAGE:-/gpfs/mnt/gpfs01/lbne/users/spng/abashyal/image-dir/wirecell-spng-cuda89.sif}
LINE_DEPO_INPUT=${LINE_DEPO_INPUT:-$PROJECT_DIR/pdhd-line-depos-interactive/generated-depos.npz}
MODEL=${MODEL:-$PROJECT_DIR/model-files/legacy_roiuniter_091026_5epochs.ts}
OUTPUT_DIR=${2:-${OUTPUT_DIR:-$PROJECT_DIR/pdhd-signal-processing-$device}}
EVENTS=${EVENTS:-32}
WC_CORES=${WC_CORES:-4}
TORCH_THREADS=${TORCH_THREADS:-1}

require_positive_integer() {
    local name=$1 value=$2
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "$name must be a positive integer, got: $value" >&2
        exit 2
    }
}

require_gpfs_path() {
    local name=$1 value=$2
    case "$value" in
        /gpfs|/gpfs/*) ;;
        *) echo "$name must be an absolute path under /gpfs, got: $value" >&2; exit 2 ;;
    esac
}

require_positive_integer EVENTS "$EVENTS"
require_positive_integer WC_CORES "$WC_CORES"
require_positive_integer TORCH_THREADS "$TORCH_THREADS"

require_gpfs_path PROJECT_DIR "$PROJECT_DIR"
require_gpfs_path IMAGE "$IMAGE"
require_gpfs_path LINE_DEPO_INPUT "$LINE_DEPO_INPUT"
require_gpfs_path MODEL "$MODEL"
require_gpfs_path OUTPUT_DIR "$OUTPUT_DIR"

test -d "$PROJECT_DIR"
test -r "$IMAGE"
test -r "$LINE_DEPO_INPUT"
test -r "$MODEL"
test -d "$PROJECT_DIR/wire-cell-data"
test -r "$PROJECT_DIR/scaling/pdhd/pdhd.jsonnet"
test -r "$PROJECT_DIR/scaling/pdhd/generation_check.py"
test -r "$PROJECT_DIR/scaling/pdhd/npz_events.py"
command -v apptainer >/dev/null

wirecell_device=cpu
apptainer_gpu_args=()
if [[ "$device" == gpu ]]; then
    command -v nvidia-smi >/dev/null
    visible=${CUDA_VISIBLE_DEVICES:-}
    if [[ -z "$visible" || "$visible" == *,* ]]; then
        echo 'DEVICE=gpu requires exactly one CUDA_VISIBLE_DEVICES allocation token.' >&2
        exit 2
    fi
    wirecell_device=gpu0
    apptainer_gpu_args=(--nv --env "CUDA_VISIBLE_DEVICES=$visible")
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    echo "Refusing existing OUTPUT_DIR: $OUTPUT_DIR" >&2
    echo 'Choose a fresh path or move the previous output aside.' >&2
    exit 2
fi
mkdir -p "$(dirname "$OUTPUT_DIR")"
mkdir "$OUTPUT_DIR"

if [[ "$device" == gpu ]]; then
    nvidia-smi -L > "$OUTPUT_DIR/nvidia-smi-L.txt"
    printf '%s\n' "$visible" > "$OUTPUT_DIR/cuda-visible-devices.txt"
fi

cat > "$OUTPUT_DIR/request.txt" <<EOF
device=$device
wirecell_device=$wirecell_device
events=$EVENTS
wc_cores=$WC_CORES
torch_threads=$TORCH_THREADS
project_dir=$PROJECT_DIR
image=$IMAGE
line_depo_input=$LINE_DEPO_INPUT
model=$MODEL
output_dir=$OUTPUT_DIR
EOF

set -o pipefail
apptainer exec --cleanenv \
    "${apptainer_gpu_args[@]}" \
    --env "PDHD_DEVICE=$wirecell_device" \
    --env "PDHD_EVENTS=$EVENTS" \
    --env "PDHD_WC_CORES=$WC_CORES" \
    --env "PDHD_TORCH_THREADS=$TORCH_THREADS" \
    --env "PDHD_INPUT_NAME=$(basename "$LINE_DEPO_INPUT")" \
    --env "PDHD_MODEL_NAME=$(basename "$MODEL")" \
    --bind "$PROJECT_DIR:/project:ro" \
    --bind "$(dirname "$LINE_DEPO_INPUT"):/input:ro" \
    --bind "$(dirname "$MODEL"):/model:ro" \
    --bind "$OUTPUT_DIR:/work" \
    "$IMAGE" /bin/bash -c '
        set -euo pipefail

        export WIRECELL_PATH=/project/scaling/pdhd:/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg:/project/wire-cell-data
        export OMP_NUM_THREADS="$PDHD_TORCH_THREADS"
        export MKL_NUM_THREADS="$PDHD_TORCH_THREADS"
        export OPENBLAS_NUM_THREADS="$PDHD_TORCH_THREADS"
        export OMP_DYNAMIC=FALSE

        wire-cell --version > /work/wire-cell-version.txt 2>&1

        # Stage 1: validate/select the line deposits, then simulate all four
        # PDHD APAs.  This matches the factored workflow used by pdhd.py.
        /usr/bin/python3 /project/scaling/pdhd/generation_check.py \
            prepare "/input/$PDHD_INPUT_NAME" "$PDHD_EVENTS"

        wire-cell -l /work/simulation.wirecell.log -L info \
            -c /project/scaling/pdhd/pdhd.jsonnet \
            -A stage=sim -A detname=pdhd -A napa=4 -A apa=-1 \
            -A engine=Pgrapher -A device=cpu \
            -A input=/work/depos.npz -A output=/work/adc.npz \
            > /work/simulation.stdout.log 2>&1

        /usr/bin/python3 /project/scaling/pdhd/generation_check.py validate \
            > /work/validation.stdout.log 2>&1

        # Stage 2: run the same four-APA SPNG graph used by pdhd.py.  The four
        # adc-tpcN inputs and spng-tpcN outputs are derived from these bases.
        wire-cell -l /work/spng.wirecell.log -L info \
            -c /project/scaling/pdhd/pdhd.jsonnet \
            -A stage=spng -A detname=pdhd -A napa=4 -A apa=-1 \
            -A engine=TbbFlow -A wc_cores="$PDHD_WC_CORES" \
            -A device="$PDHD_DEVICE" -A gpu_scheme=none -A ngpu=1 \
            -A "model_file=/model/$PDHD_MODEL_NAME" \
            -A input=/work/adc.npz -A output=/work/spng.npz \
            -A timeline=/work/spng.timeline.json \
            > /work/spng.stdout.log 2>&1

        for apa in 0 1 2 3; do
            test -s "/work/adc-tpc${apa}.npz"
            test -s "/work/spng-tpc${apa}.npz"
        done
    ' 2>&1 | tee "$OUTPUT_DIR/container.log"

printf 'PASS: PDHD deposit -> ADC -> SPNG completed on %s; outputs: %s\n' \
    "$device" "$OUTPUT_DIR"
