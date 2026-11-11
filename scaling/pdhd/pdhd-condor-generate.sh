#!/usr/bin/env bash
# Optional HTCondor stage: generate PDHD ADC inputs and a scaling dataset.
set -euo pipefail

: "${PROJECT_DIR:?Set PROJECT_DIR to the shared spng-portability-tests checkout}"
: "${DATASET:?Set DATASET to the desired shared dataset directory}"
: "${IMAGE:?Set IMAGE to the shared Wire-Cell .sif image}"
: "${RESULTS_DIR:?Set RESULTS_DIR to shared output storage}"

job_tag=${1:?usage: pdhd-condor-generate.sh CLUSTER.PROCESS}
dataset_events=${DATASET_EVENTS:-32}
source_events=${SOURCE_EVENTS:-1}
repeat_input=${REPEAT_INPUT:-1}
run_dir="$RESULTS_DIR/pdhd-generation-$job_tag"

[[ "$dataset_events" =~ ^[1-9][0-9]*$ ]] || {
    echo 'DATASET_EVENTS must be a positive integer' >&2; exit 2;
}
[[ "$source_events" =~ ^[1-9][0-9]*$ ]] || {
    echo 'SOURCE_EVENTS must be a positive integer' >&2; exit 2;
}
(( source_events <= 42 )) || {
    echo 'SOURCE_EVENTS must not exceed the 42 upstream line configurations' >&2; exit 2;
}
[[ "$repeat_input" == 0 || "$repeat_input" == 1 ]] || {
    echo 'REPEAT_INPUT must be 0 or 1' >&2; exit 2;
}
if [[ "$repeat_input" == 0 ]] && (( dataset_events > source_events )); then
    echo 'DATASET_EVENTS must not exceed SOURCE_EVENTS when REPEAT_INPUT=0' >&2
    exit 2
fi

# A complete-looking existing dataset makes this optional stage a no-op. The
# scaling planner subsequently validates its manifest, archive structure, and
# hashes before any measured work begins.
complete=1
for path in "$DATASET/dataset.json" \
            "$DATASET/adc-tpc0.npz" "$DATASET/adc-tpc1.npz" \
            "$DATASET/adc-tpc2.npz" "$DATASET/adc-tpc3.npz"; do
    [[ -r "$path" ]] || complete=0
done
if [[ $complete -eq 1 ]]; then
    printf 'SKIP: complete dataset files already exist at %s\n' "$DATASET"
    exit 0
fi
if [[ -e "$DATASET" ]]; then
    echo "Refusing partial/existing dataset path: $DATASET" >&2
    exit 2
fi

test -r "$IMAGE"
test -d "$PROJECT_DIR/wire-cell-data"
for command in python3 apptainer sha256sum; do
    command -v "$command" >/dev/null || {
        echo "Missing command: $command" >&2; exit 2;
    }
done

mkdir -p "$RESULTS_DIR" "$(dirname "$DATASET")"
mkdir "$run_dir"
cp "$PROJECT_DIR/scaling/pdhd/"{pdhd.jsonnet,npz_events.py,generation_check.py,generate_line_depos.py} "$run_dir/"

exec > >(tee -a "$run_dir/job.stdout") \
     2> >(tee -a "$run_dir/job.stderr" >&2)

sha256sum "$IMAGE" | tee "$run_dir/image.sha256"

python3 - "$run_dir/preflight.json" "$job_tag" <<'PY'
import json, os, socket, sys
from pathlib import Path
record = dict(host=socket.gethostname(), condor_job_id=sys.argv[2],
              cpu_affinity=sorted(os.sched_getaffinity(0)),
              note='CPU-only Pgrapher event generation; no GPU requested.')
Path(sys.argv[1]).write_text(json.dumps(record, indent=2)+'\n')
PY

printf 'image=%s\ndepo_generator=%s\nsource_events=%s\ndataset_events=%s\nrepeat_input=%s\njob=%s\n' \
    "$IMAGE" 'spng/test/spng-ssss:line_depo' "$source_events" "$dataset_events" "$repeat_input" "$job_tag" \
    > "$run_dir/request.txt"

# Stage 1: run concrete targets through the existing spng-ssss line_depo DAG,
# then simulate and validate four matched APA ADC archives. Both are CPU-only.
apptainer exec --cleanenv \
    --env "SOURCE_EVENTS=$source_events" \
    --bind "$PROJECT_DIR/wire-cell-data:/wirecell-data:ro" \
    --bind "$run_dir:/work" \
    "$IMAGE" /bin/bash -c '
        set -euo pipefail
        export OMP_NUM_THREADS=1 MKL_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
        export WIRECELL_PATH=/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg:/wirecell-data
        /usr/bin/python3 -c "import numpy; print(numpy.__version__)" > /work/numpy-version.txt
        wire-cell --version > /work/wire-cell-version.txt 2>&1
        command -v wcpy > /work/wcpy-path.txt
        command -v snakemake > /work/snakemake-path.txt
        snakemake --version > /work/snakemake-version.txt 2>&1
        /usr/bin/python3 /work/generate_line_depos.py \
            --events "$SOURCE_EVENTS" --output /work/generated-depos.npz \
            --metadata /work/depo-generation.json --workdir /work/line-depos \
            --snakefile /opt/wire-cell-toolkit/spng/test/spng-ssss
        /usr/bin/python3 /work/generation_check.py prepare /work/generated-depos.npz "$SOURCE_EVENTS"
        wire-cell -l stdout -A stage=sim -A detname=pdhd -A napa=4 -A apa=-1 \
            -A engine=Pgrapher -A device=cpu -A input=/work/depos.npz \
            -A output=/work/adc.npz /work/pdhd.jsonnet
        /usr/bin/python3 /work/generation_check.py validate
    ' > "$run_dir/generation.log" 2>&1

# Stage 2: create the immutable dataset manifest and requested event count from
# the validated source archives. Repetition is explicit and recorded.
generate=(/usr/bin/python3 "$PROJECT_DIR/scaling/pdhd/pdhd.py" generate
    --adc "$run_dir/adc-tpc0.npz" "$run_dir/adc-tpc1.npz"
          "$run_dir/adc-tpc2.npz" "$run_dir/adc-tpc3.npz"
    --events "$dataset_events" --output "$DATASET")
if [[ "$repeat_input" == 1 ]]; then
    generate+=(--repeat)
fi
apptainer exec --cleanenv \
    --bind "$PROJECT_DIR:$PROJECT_DIR:ro" \
    --bind "$run_dir:$run_dir:ro" \
    --bind "$(dirname "$DATASET"):$(dirname "$DATASET")" \
    "$IMAGE" "${generate[@]}" > "$run_dir/dataset.log" 2>&1

test -r "$DATASET/dataset.json"
for apa in 0 1 2 3; do test -r "$DATASET/adc-tpc${apa}.npz"; done
printf 'PASS: generated %s-event dataset at %s\n' "$dataset_events" "$DATASET"
