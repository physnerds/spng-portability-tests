#!/usr/bin/env bash

set -euo pipefail

IMAGE="${IMAGE:-abashyal/wirecell-spng:cuda80}"
WORK_DIR="${WORK_DIR:-${PWD}/work}"

mkdir -p "${WORK_DIR}"

if ! command -v podman-hpc >/dev/null 2>&1; then
    echo "ERROR: podman-hpc is not available."
    exit 1
fi

echo "Starting Perlmutter Wire-Cell SPNG container"
echo "  Image:     ${IMAGE}"
echo "  Work dir:  ${WORK_DIR}"
echo

podman-hpc run \
    --rm \
    --interactive \
    --tty \
    --gpus=all \
    --entrypoint /bin/bash \
    --volume "${WORK_DIR}:/work" \
    --mount type=bind,source=/global/homes/a/abashyal/spng-portability-tests/wire-cell-data,target=/opt/wire-cell-toolkit/wire-cell-data,readonly \
    --mount type=bind,source=/global/homes/a/abashyal/spng-portability-tests/infiles,target=/opt/wire-cell-toolkit/infiles \
    --mount type=bind,source=/global/homes/a/abashyal/spng-portability-tests/outfiles,target=/opt/wire-cell-toolkit/outfiles \
    --ulimit stack=67108864 \
    --workdir /work \
    "${IMAGE}"
