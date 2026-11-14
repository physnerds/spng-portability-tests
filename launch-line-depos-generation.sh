#!/bin/bash


export PROJECT_DIR="$PWD"
export IMAGE=/gpfs01/lbne/users/spng/abashyal/image-dir/
export LINE_DEPO_OUTPUT="$PROJECT_DIR/pdhd-line-depos-interactive"

test -r "$IMAGE"
test -d "$PROJECT_DIR/wire-cell-data"
test -r "$PROJECT_DIR/scaling/pdhd/generate_line_depos.py"

if [[ -z "${LINE_DEPO_OUTPUT:-}" || "$LINE_DEPO_OUTPUT" == "/" ]]; then
  echo "Refusing unsafe LINE_DEPO_OUTPUT: ${LINE_DEPO_OUTPUT:-<unset>}" >&2
  return 2 2>/dev/null || exit 2
fi

if [[ -e "$LINE_DEPO_OUTPUT" ]]; then
  rm -rf -- "$LINE_DEPO_OUTPUT"
fi

mkdir -p "$LINE_DEPO_OUTPUT"

apptainer exec \
  --bind "$PROJECT_DIR/wire-cell-data:/opt/wire-cell-data:ro" \
  --bind "$PROJECT_DIR:/project:ro" \
  --bind "$LINE_DEPO_OUTPUT:/work" \
  --nv \
  --pwd /work \
  "$IMAGE" \
  /usr/local/bin/wirecell-entrypoint bash -lc '
    set -euo pipefail

    for path in \
      /work/generated-depos.npz \
      /work/depo-generation.json \
      /work/line-depos
    do
      if [[ -e "$path" ]]; then
        echo "Refusing existing output: $path" >&2
        exit 2
      fi
    done

    /opt/wirecell-view/bin/python -m venv /tmp/my-venv
    source /tmp/my-venv/bin/activate
    pip install uv
    ls -lht
    export UV_CACHE_DIR=/tmp/uv-cache

    uv pip install --only-binary=gojsonnet \
      "git+https://github.com/WireCell/wire-cell-python.git"

    export WIRECELL_PATH=/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg:/opt/wire-cell-data
    export OMP_NUM_THREADS=1
    export MKL_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1

    command -v wcpy
    wcpy --help >/dev/null

    python /project/scaling/pdhd/generate_line_depos.py \
      --events 32 \
      --output /work/generated-depos.npz \
      --metadata /work/depo-generation.json \
      --workdir /work/line-depos \
      --template /project/scaling/pdhd/line-depo-template.sh.in

    test -s /work/generated-depos.npz
    test -s /work/depo-generation.json
    count=$(find /work/line-depos/pdhd/line/depo -name data.npz | wc -l)
    [[ "$count" -eq 32 ]] || {
      echo "Expected 32 line-deposit archives, found $count" >&2
      exit 2
    }
    echo "PASS: generated and merged $count distinct PDHD line deposits"
  ' > >(tee "$LINE_DEPO_OUTPUT/interactive-generation.log") 2>&1