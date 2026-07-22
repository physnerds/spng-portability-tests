#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

chmod +x build-dependencies.sh build-image.sh

DEPENDENCY_IMAGE="${DEPENDENCY_IMAGE:-wirecell-spng-deps:cuda89}"

if ! docker image inspect "${DEPENDENCY_IMAGE}" >/dev/null 2>&1; then
    echo "Dependency image not found. Building LLVM, PyTorch, and dependencies."
    ./build-dependencies.sh
else
    echo "Using existing dependency image:"
    echo "  ${DEPENDENCY_IMAGE}"
fi

./build-image.sh