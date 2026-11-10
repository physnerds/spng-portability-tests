#!/bin/bash
# Run inside one GPU node with >=8 Slurm CPUs and >=2 assigned GPUs.
# This functional test uses a pre-generated, four-event dataset (copies allowed).
set -euo pipefail
: "${PROJECT_DIR:?Set the project root}"
: "${DATASET:?Set the host path to a prepared four-event dataset}"
: "${SLURM_JOB_ID:?Run in a GPU allocation}"
: "${SCRATCH:?}"
IMAGE=${IMAGE:-docker.io/abashyal/wirecell-spng:cuda80}
REVIEW_DIR=${REVIEW_DIR:-$SCRATCH/pdhd-runner-retest-$SLURM_JOB_ID}
mkdir "$REVIEW_DIR"
PROJECT_DIR=$(realpath "$PROJECT_DIR")
DATASET=$(realpath "$DATASET")
REVIEW_DIR=$(realpath "$REVIEW_DIR")
# An srun --pty shell occupies the enclosing step. Add --overlap only in
# this test harness to let the real runner launch sibling steps on its node.
# Production batch/salloc campaigns do not need this shim.
srun_path=$(command -v srun)
mkdir "$REVIEW_DIR/bin"
if [[ -n "${SLURM_STEP_ID:-}" && "$SLURM_STEP_ID" != batch && "$SLURM_STEP_ID" != extern ]]; then
    printf '#!/bin/bash\nexec %q --overlap "$@"\n' "$srun_path" > "$REVIEW_DIR/bin/srun"
    chmod u+x "$REVIEW_DIR/bin/srun"
fi
plan_case() {
    local label=$1
    shift
    podman-hpc run --rm --gpu --net=slirp4netns --entrypoint /usr/bin/python3 \
        --volume "$PROJECT_DIR:$PROJECT_DIR:ro" \
        --volume "$DATASET:$DATASET:ro" --volume "$REVIEW_DIR:$REVIEW_DIR" \
        --workdir "$PROJECT_DIR" "$IMAGE" scaling/pdhd/pdhd.py plan \
        --dataset "$DATASET" --model "$PROJECT_DIR/infiles/legacy_roiuniter_090326.ts" \
        --image "$IMAGE" --profile perlmutter --launcher slurm --nodes 1 \
        --threads 1 --cores-per-process 1 --gpus-per-node 2 \
        --warmups 0 --repeats 1 --timeout 300 --barrier-timeout 120 \
        --wirecell-data "$PROJECT_DIR/wire-cell-data" --output "$REVIEW_DIR/$label" "$@"
}
plan_case normal --processes 1 4
PATH="$REVIEW_DIR/bin:$PATH" python3 "$REVIEW_DIR/normal/suite/pdhd.py" run \
    --campaign "$REVIEW_DIR/normal" > "$REVIEW_DIR/normal.log" 2>&1
plan_case cancel --processes 4
PATH="$REVIEW_DIR/bin:$PATH" python3 "$PROJECT_DIR/scaling/pdhd/tests/cancel_campaign.py" \
    --campaign "$REVIEW_DIR/cancel" --report "$REVIEW_DIR/cancellation.json"
printf 'PASS: normal Slurm cases and cancellation; evidence: %s\n' "$REVIEW_DIR"
