#!/usr/bin/env bash

set -euo pipefail

IMAGE="${IMAGE:-wirecell-spng:perlmutter}"
WORK_DIR="${WORK_DIR:-${PWD}/work}"

mkdir -p "${WORK_DIR}"

if ! command -v podman-hpc >/dev/null 2>&1; then
    echo "ERROR: podman-hpc is not available."
    exit 1
fi

if ! podman-hpc image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: Image does not exist:"
    echo "  ${IMAGE}"
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
    --volume "${WORK_DIR}:/work" \
    --workdir /work \
    "${IMAGE}" \
    bash