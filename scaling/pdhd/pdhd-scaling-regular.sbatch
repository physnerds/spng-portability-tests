#!/bin/bash
#SBATCH --account=m5037_g
#SBATCH --qos=regular
#SBATCH --constraint=gpu
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=4
#SBATCH --cpus-per-task=8
#SBATCH --gpus-per-node=4
#SBATCH --time=02:00:00
#SBATCH --job-name=pdhd-scaling
#SBATCH --output=pdhd-scaling-%j.log

set -euo pipefail
export PROJECT_DIR=${PROJECT_DIR:-/global/u2/a/abashyal/spng-portability-tests}
export DATASET=${DATASET:-$SCRATCH/pdhd-runner-review-61007458/data}
export IMAGE=${IMAGE:-docker.io/abashyal/wirecell-spng:cuda80}
export CAMPAIGN="$SCRATCH/pdhd-scaling-regular-$SLURM_JOB_ID"
cd "$PROJECT_DIR"
command -v python3
command -v podman-hpc
printf 'Job %s; campaign %s\n' "$SLURM_JOB_ID" "$CAMPAIGN"

# Prepare/shard on one compute node; this step exits before measured steps.
srun --nodes=1 --ntasks=1 --cpus-per-task=8 --gpus-per-task=1 \
  --cpu-bind=cores --exact \
  podman-hpc run --rm --gpu --net=slirp4netns \
  --entrypoint /usr/bin/python3 \
  --volume "$PROJECT_DIR:$PROJECT_DIR:ro" \
  --volume "$DATASET:$DATASET:ro" --volume "$SCRATCH:$SCRATCH" \
  --workdir "$PROJECT_DIR" "$IMAGE" scaling/pdhd/pdhd.py plan \
  --dataset "$DATASET" \
  --model "$PROJECT_DIR/infiles/legacy_roiuniter_090326.ts" \
  --image "$IMAGE" --profile perlmutter --launcher slurm \
  --nodes 1 --processes 1 2 4 --threads 1 2 4 --cores-per-process 4 \
  --gpus-per-node 4 --warmups 1 --repeats 5 \
  --timeout 1800 --barrier-timeout 300 \
  --wirecell-data "$PROJECT_DIR/wire-cell-data" --output "$CAMPAIGN"

# The batch shell coordinates; the runner launches its own Slurm steps.
python3 "$CAMPAIGN/suite/pdhd.py" run --campaign "$CAMPAIGN" \
  > "$CAMPAIGN/run.log" 2>&1
cat "$CAMPAIGN/scaling-summary.json"
