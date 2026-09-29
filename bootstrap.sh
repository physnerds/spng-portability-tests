#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

chmod +x \
    build-dependencies.sh \
    build-image.sh \
    run-container.sh \
    entrypoint.sh

DEPENDENCY_IMAGE="${DEPENDENCY_IMAGE:-wirecell-spng-deps:perlmutter}"

if ! command -v podman-hpc >/dev/null 2>&1; then
    echo "ERROR: podman-hpc is not available."
    exit 1
fi

if ! podman-hpc image inspect "${DEPENDENCY_IMAGE}" >/dev/null 2>&1; then
    echo "Dependency image not found:"
    echo "  ${DEPENDENCY_IMAGE}"
    echo
    echo "Building Perlmutter dependency image."
    ./build-dependencies.sh
else
    echo "Using existing dependency image:"
    echo "  ${DEPENDENCY_IMAGE}"
fi

echo
echo "Building final Wire-Cell SPNG image."
./build-image.sh