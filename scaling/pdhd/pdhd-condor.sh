#!/usr/bin/env bash
# HTCondor entry point for the sgpu PDHD scaling and telemetry tests.
set -euo pipefail

: "${PROJECT_DIR:?Set PROJECT_DIR to the shared spng-portability-tests checkout}"
: "${DATASET:?Set DATASET to a prepared PDHD dataset on shared storage}"
: "${IMAGE:?Set IMAGE to the shared Wire-Cell .sif image}"
: "${RESULTS_DIR:?Set RESULTS_DIR to shared output storage}"

job_tag=${1:?usage: pdhd-condor.sh CLUSTER.PROCESS}
export PDHD_CONDOR_JOB_ID="$job_tag"
mode=${MODE:-scaling}
gpus=${GPUS:-1}
sample_ms=${SAMPLE_MS:-500}
run_dir="$RESULTS_DIR/pdhd-${mode}-${job_tag}"

case "$mode" in
    functional)
        processes=(1 4)
        threads=(1)
        cores_per_process=1
        warmups=0
        repeats=1
        timeout=300
        barrier_timeout=120
        ;;
    scaling)
        processes=(1 2 4)
        threads=(1 2 4)
        cores_per_process=4
        warmups=1
        repeats=${REPEATS:-5}
        timeout=1800
        barrier_timeout=300
        ;;
    *)
        echo "Unknown MODE=$mode (expected functional or scaling)" >&2
        exit 2
        ;;
esac

if [[ "$gpus" -eq 1 ]]; then
    study=one-gpu-packing
elif [[ "$gpus" -ge 4 ]]; then
    study=multi-gpu
else
    echo 'GPUS must be 1 for packing or at least 4 for this scaling matrix' >&2
    exit 2
fi

exec python3 "$PROJECT_DIR/scaling/pdhd/tests/condor_campaign.py" \
    --project "$PROJECT_DIR" \
    --dataset "$DATASET" \
    --image "$IMAGE" \
    --output "$run_dir" \
    --gpus "$gpus" \
    --study "$study" \
    --processes "${processes[@]}" \
    --threads "${threads[@]}" \
    --cores-per-process "$cores_per_process" \
    --warmups "$warmups" \
    --repeats "$repeats" \
    --sample-ms "$sample_ms" \
    --timeout "$timeout" \
    --barrier-timeout "$barrier_timeout"
