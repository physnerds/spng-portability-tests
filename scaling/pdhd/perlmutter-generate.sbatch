#!/bin/bash
#SBATCH --job-name=pdhd-generation
#SBATCH --constraint=gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --gpus-per-task=1
#SBATCH --qos=regular
#SBATCH --time=00:30:00
#SBATCH --output=pdhd-generation-%j.log

# Submit with --account=<your GPU account>. See perlmutter-generation.md.
set -euo pipefail
: "${SLURM_JOB_ID:?Submit with sbatch or run inside a GPU allocation}"
: "${SCRATCH:?SCRATCH must be set}"
: "${PROJECT_DIR:?Set PROJECT_DIR to the spng-portability-tests directory}"
IMAGE=${IMAGE:-wirecell-spng:cuda80}
DEPOS=${DEPOS:-$PROJECT_DIR/infiles/muons.npz}
EVENTS=${EVENTS:-1}
WIRECELL_DATA=${WIRECELL_DATA:-$PROJECT_DIR/wire-cell-data}
RUN_DIR=${RUN_DIR:-$SCRATCH/pdhd-generation-$SLURM_JOB_ID}
[[ "$EVENTS" =~ ^[1-9][0-9]*$ ]] || { echo 'EVENTS must be a positive integer' >&2; exit 2; }
PROJECT_DIR=$(realpath "$PROJECT_DIR")
DEPOS=$(realpath -e "$DEPOS")
WIRECELL_DATA=$(realpath -e "$WIRECELL_DATA")
command -v podman-hpc >/dev/null
[[ -f "$DEPOS" && -d "$WIRECELL_DATA" ]]
# Refuse to overwrite any previous run. Snapshot the external configuration.
mkdir -p "$(dirname "$RUN_DIR")"
mkdir "$RUN_DIR"
RUN_DIR=$(realpath "$RUN_DIR")
cp "$PROJECT_DIR/scaling/pdhd/"{pdhd.jsonnet,npz_events.py,generation_check.py} "$RUN_DIR/"
printf 'image=%s\nsource=%s\nevents=%s\njob=%s\n' "$IMAGE" "$DEPOS" "$EVENTS" "$SLURM_JOB_ID" > "$RUN_DIR/request.txt"
# Migrated read-only images may be listed/run but unavailable to image inspect.
if ! podman-hpc image inspect "$IMAGE" > "$RUN_DIR/image-inspect.json" 2> "$RUN_DIR/image-inspect.stderr"; then
    podman-hpc images --format json > "$RUN_DIR/image-list.json"
    echo 'Image inspect unavailable; retained image listing and error.' >&2
fi
printf 'Output directory: %s\n' "$RUN_DIR"
# Simulation uses CPU detector-response components. The GPU is exposed to
# exercise the same container launch environment intended for later SPNG runs.
# An interactive srun shell already owns the task resources; avoid nesting a step.
launcher=(srun --nodes=1 --ntasks=1 --cpus-per-task=8 --gpus-per-task=1
          --gpu-bind=single:1 --cpu-bind=cores --exact)
if [[ -n "${SLURM_STEP_ID:-}" && "${SLURM_STEP_ID}" != batch && "${SLURM_STEP_ID}" != extern ]]; then
    launcher=()
fi
if "${launcher[@]}" podman-hpc run --rm --gpu --net=slirp4netns --entrypoint /bin/bash \
    --volume "$DEPOS:/input/depos.npz:ro" \
    --volume "$WIRECELL_DATA:/wirecell-data:ro" \
    --volume "$RUN_DIR:/work" --workdir /work \
    --env EVENTS="$EVENTS" --env CONTAINER_PYTHON="${CONTAINER_PYTHON:-/usr/bin/python3}" \
    --env OMP_NUM_THREADS=1 --env MKL_NUM_THREADS=1 --env OPENBLAS_NUM_THREADS=1 \
    --env WIRECELL_PATH=/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg:/wirecell-data \
    "$IMAGE" -c '
        set -euo pipefail
        "$CONTAINER_PYTHON" -c "import numpy; print(numpy.__version__)" > /work/numpy-version.txt
        wire-cell --version > /work/wire-cell-version.txt 2>&1
        nvidia-smi > /work/nvidia-smi.txt
        "$CONTAINER_PYTHON" /work/generation_check.py prepare /input/depos.npz "$EVENTS"
        wire-cell -l stdout -A stage=sim -A detname=pdhd -A napa=4 -A apa=-1 \
            -A engine=Pgrapher -A device=cpu \
            -A input=/work/depos.npz -A output=/work/adc.npz /work/pdhd.jsonnet
        "$CONTAINER_PYTHON" /work/generation_check.py validate
    ' > "$RUN_DIR/stdio.log" 2>&1; then
    echo "PASS: four matched APA archives; see $RUN_DIR/validation.json"
else
    status=$?
    printf 'FAIL (exit %s): inspect %s/stdio.log\n' "$status" "$RUN_DIR" >&2
    exit "$status"
fi
