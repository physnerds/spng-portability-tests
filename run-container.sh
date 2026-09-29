#!/usr/bin/env bash

set -euo pipefail

IMAGE="${IMAGE:-wirecell-spng:cmake-nvtx}"
WORK_DIR="${WORK_DIR:-${PWD}/work}"

mkdir -p "${WORK_DIR}"

sudo docker run \
    --rm \
    --interactive \
    --tty \
    --gpus all \
    --ipc=host \
    --ulimit memlock=-1 \
    --mount type=bind,source=/home/amitbashyal/Documents/BNL-DUNE/wire-cell-spack-build-tests/wire-cell-data,target=/opt/wire-cell-toolkit/wire-cell-data,readonly \
    --mount type=bind,source=/home/amitbashyal/Documents/BNL-DUNE/wire-cell-spack-build-tests-2/spng-portability-tests/infiles,target=/opt/wire-cell-toolkit/infiles \
    --mount type=bind,source=/home/amitbashyal/Documents/BNL-DUNE/wire-cell-spack-build-tests-2/spng-portability-tests/outfiles,target=/opt/wire-cell-toolkit/outfiles \
    --ulimit stack=67108864 \
    --volume "${WORK_DIR}:/work" \
    --workdir /work \
    "${IMAGE}" \
    bash
