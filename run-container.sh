#!/usr/bin/env bash

set -euo pipefail

IMAGE="${IMAGE:-wirecell-spng:cuda89}"
WORK_DIR="${WORK_DIR:-${PWD}/work}"

mkdir -p "${WORK_DIR}"

docker run \
    --rm \
    --interactive \
    --tty \
    --gpus all \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --volume "${WORK_DIR}:/work" \
    --workdir /work \
    "${IMAGE}" \
    bash