#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/setup.sh"
cd "$WCT_LOCAL_ROOT"
mkdir -p logs patches
spack -e "$WCT_SPACK_ENV" concretize
spack -e "$WCT_SPACK_ENV" install --fail-fast --show-log-on-error -j 4
spack -e "$WCT_SPACK_ENV" env view regenerate
spack -e "$WCT_SPACK_ENV" find -dlv > logs/installed-dependencies.txt
if spack -e "$WCT_SPACK_ENV" find --format '{name}' | grep -qx py-torch; then
    echo 'Unexpected Spack py-torch installation' >&2
    exit 1
fi
export PATH="$PATH:$WCT_LOCAL_ROOT/deps-view/bin"
export PKG_CONFIG_PATH="$WCT_LOCAL_ROOT/deps-view/lib/pkgconfig:$WCT_LOCAL_ROOT/deps-view/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
torch_prefix=$(python -c 'import torch; print(torch.utils.cmake_prefix_path)')
fmt_prefix=$(spack -e "$WCT_SPACK_ENV" location -i fmt)
cmake -S wire-cell-toolkit -B build-gcc \
    -DCMAKE_BUILD_TYPE=Release \
    -DPython3_EXECUTABLE=/global/common/software/nersc9/pytorch/2.8.0/bin/python \
    -DPYTHON_EXECUTABLE=/global/common/software/nersc9/pytorch/2.8.0/bin/python \
    -DPython3_ROOT_DIR=/global/common/software/nersc9/pytorch/2.8.0 \
    -DPKG_CONFIG_EXECUTABLE="$WCT_LOCAL_ROOT/deps-view/bin/pkgconf" \
    -DCMAKE_CXX_COMPILER=/opt/cray/pe/gcc-native/13/bin/g++ \
    -DCMAKE_INSTALL_PREFIX="$WCT_LOCAL_ROOT/install" \
    -DCMAKE_PREFIX_PATH="$WCT_LOCAL_ROOT/deps-view;$torch_prefix" \
    -DCMAKE_CXX_FLAGS="-I$fmt_prefix/include" \
    -DCUDAToolkit_ROOT=/opt/nvidia/hpc_sdk/Linux_x86_64/25.5/cuda/12.9 \
    -DCMAKE_CUDA_ARCHITECTURES=80 -DTORCH_CUDA_ARCH_LIST=8.0 \
    -DWITH_LIBTORCH=yes -DWCT_WITH_SPNG=ON -DWCT_WITH_NVTX=ON \
    -DWCT_NVTX_INCLUDE_DIR=/opt/nvidia/hpc_sdk/Linux_x86_64/25.5/cuda/12.9/include/nvtx3 \
    -DWCT_WITH_TESTS=OFF -DWCT_INSTALL_CONFIG=all \
    -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
    '-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib' \
    2>&1 | tee logs/configure.log
cmake --build build-gcc --parallel 4 2>&1 | tee logs/compile.log
cmake --install build-gcc 2>&1 | tee logs/install.log
git -C wire-cell-toolkit diff > patches/wct-cmake-nvtx3.patch
