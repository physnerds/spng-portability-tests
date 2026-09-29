# syntax=docker/dockerfile:1

ARG DEPENDENCY_IMAGE=wirecell-spng-deps:perlmutter
FROM ${DEPENDENCY_IMAGE}

SHELL ["/bin/bash", "-c"]

# -----------------------------------------------------------------------------
# Build arguments
# -----------------------------------------------------------------------------

ARG WCT_REPOSITORY=https://github.com/WireCell/wire-cell-toolkit.git
ARG WCT_REF=spng
ARG BUILD_JOBS=16

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------

ENV SPACK_ROOT=/opt/spack
ENV WCT_ENV=/opt/wirecell-env
ENV SPACK_VIEW=/opt/wirecell-view
ENV WCT_SOURCE=/opt/wire-cell-toolkit

ENV CUDA_PREFIX=/usr/local/cuda
ENV CUDA_TARGET=/usr/local/cuda/targets/x86_64-linux

# NERSC Python contains the NERSC-provided PyTorch installation.
# Do not replace this with the Python from the Spack view.
ENV NERSC_PYTHON=/usr/bin/python

# Do NOT globally add /opt/wirecell-view/bin to PATH here.
# It contains a Spack Python which does not contain NERSC PyTorch.

ENV CPATH=/opt/wirecell-view/include
ENV LIBRARY_PATH=/opt/wirecell-view/lib:/opt/wirecell-view/lib64
ENV LD_LIBRARY_PATH=/opt/wirecell-view/lib:/opt/wirecell-view/lib64
ENV PKG_CONFIG_PATH=/opt/wirecell-view/lib/pkgconfig:/opt/wirecell-view/lib64/pkgconfig:/opt/wirecell-view/share/pkgconfig

# -----------------------------------------------------------------------------
# Verify CUDA supplied by the NERSC base image
# -----------------------------------------------------------------------------

RUN set -euo pipefail; \
    echo "=== CUDA ==="; \
    command -v nvcc; \
    nvcc --version; \
    test -d "${CUDA_TARGET}/include"; \
    if [[ -d "${CUDA_TARGET}/lib" ]]; then \
        echo "CUDA library directory: ${CUDA_TARGET}/lib"; \
    elif [[ -d "${CUDA_TARGET}/lib64" ]]; then \
        echo "CUDA library directory: ${CUDA_TARGET}/lib64"; \
    else \
        echo "ERROR: CUDA library directory not found" >&2; \
        exit 1; \
    fi

# -----------------------------------------------------------------------------
# Verify NERSC PyTorch
# -----------------------------------------------------------------------------

RUN set -euo pipefail; \
    echo "=== NERSC PyTorch ==="; \
    "${NERSC_PYTHON}" - <<'PY'
import os
import sys
import torch

torch_root = torch.__path__[0]

print("Python:", sys.executable)
print("Torch version:", torch.__version__)
print("Torch location:", torch_root)
print("Torch CUDA:", torch.version.cuda)
print("Torch CXX11 ABI:", torch.compiled_with_cxx11_abi())
print("CMake prefix:", torch.utils.cmake_prefix_path)

required = [
    os.path.join(torch_root, "include"),
    os.path.join(torch_root, "include", "torch", "csrc", "api", "include"),
    os.path.join(torch_root, "lib"),
]

for path in required:
    print("Checking:", path)
    if not os.path.isdir(path):
        raise RuntimeError(f"Missing PyTorch path: {path}")
PY

# -----------------------------------------------------------------------------
# Verify Spack dependency environment
# -----------------------------------------------------------------------------

RUN set -euo pipefail; \
    source "${SPACK_ROOT}/share/spack/setup-env.sh"; \
    spack env activate "${WCT_ENV}"; \
    echo "=== Spack environment ==="; \
    spack find; \
    echo "=== Checking that PyTorch was not installed by Spack ==="; \
    if spack find py-torch 2>/dev/null | grep -q 'py-torch'; then \
        echo "ERROR: Spack py-torch found" >&2; \
        exit 1; \
    else \
        echo "OK: no Spack py-torch"; \
    fi

# -----------------------------------------------------------------------------
# Clone Wire-Cell Toolkit
# -----------------------------------------------------------------------------

RUN set -euo pipefail; \
    git clone \
        --branch "${WCT_REF}" \
        --single-branch \
        "${WCT_REPOSITORY}" \
        "${WCT_SOURCE}"; \
    test "$(git -C "${WCT_SOURCE}" rev-parse --abbrev-ref HEAD)" = "${WCT_REF}"; \
    git -C "${WCT_SOURCE}" rev-parse HEAD

# -----------------------------------------------------------------------------
# Configure, build and install Wire-Cell Toolkit
# -----------------------------------------------------------------------------

RUN set -euo pipefail; \
    \
    source "${SPACK_ROOT}/share/spack/setup-env.sh"; \
    spack env activate "${WCT_ENV}"; \
    \
    # Resolve dependency prefixes
    BOOST_PREFIX="$(spack location -i boost)"; \
    BZIP2_PREFIX="$(spack location -i bzip2)"; \
    FFTW_PREFIX="$(spack location -i fftw)"; \
    TBB_PREFIX="$(spack location -i intel-tbb)"; \
    ZLIB_PREFIX="$(spack location -i zlib-ng)"; \
    GOJSONNET_PREFIX="$(spack location -i go-jsonnet)"; \
    \
    # Resolve NERSC PyTorch before adding Spack's bin directory to PATH.
    TDIR="$("${NERSC_PYTHON}" -c 'import torch; print(torch.__path__[0])')"; \
    \
    # Resolve Boost library directory
    BOOST_LIBDIR="$( \
        for directory in "${BOOST_PREFIX}/lib" "${BOOST_PREFIX}/lib64"; do \
            if compgen -G "${directory}/libboost_filesystem*" >/dev/null; then \
                echo "${directory}"; \
                break; \
            fi; \
        done \
    )"; \
    \
    # Resolve Bzip2 library directory
    BZIP2_LIBDIR="$( \
        for directory in "${BZIP2_PREFIX}/lib" "${BZIP2_PREFIX}/lib64"; do \
            if compgen -G "${directory}/libbz2.so*" >/dev/null || \
               [[ -f "${directory}/libbz2.a" ]]; then \
                echo "${directory}"; \
                break; \
            fi; \
        done \
    )"; \
    \
    # Resolve FFTW library directory
    FFTW_LIBDIR="$( \
        for directory in "${FFTW_PREFIX}/lib" "${FFTW_PREFIX}/lib64"; do \
            if compgen -G "${directory}/libfftw3.so*" >/dev/null || \
               [[ -f "${directory}/libfftw3.a" ]]; then \
                echo "${directory}"; \
                break; \
            fi; \
        done \
    )"; \
    \
    # Resolve TBB library directory
    TBB_LIBDIR="$( \
        for directory in "${TBB_PREFIX}/lib" "${TBB_PREFIX}/lib64"; do \
            if compgen -G "${directory}/libtbb.so*" >/dev/null; then \
                echo "${directory}"; \
                break; \
            fi; \
        done \
    )"; \
    \
    # Resolve GoJsonnet library directory
    GOJSONNET_LIBDIR="$( \
        for directory in "${GOJSONNET_PREFIX}/lib" "${GOJSONNET_PREFIX}/lib64"; do \
            if compgen -G "${directory}/libgojsonnet.so*" >/dev/null || \
               [[ -f "${directory}/libgojsonnet.a" ]]; then \
                echo "${directory}"; \
                break; \
            fi; \
        done \
    )"; \
    \
    # Resolve Zlib library directory
    ZLIB_LIBDIR="$( \
        for directory in "${ZLIB_PREFIX}/lib" "${ZLIB_PREFIX}/lib64"; do \
            if compgen -G "${directory}/libz.so*" >/dev/null || \
               [[ -f "${directory}/libz.a" ]]; then \
                echo "${directory}"; \
                break; \
            fi; \
        done \
    )"; \
    \
    # Resolve CUDA library directory
    if [[ -d "${CUDA_TARGET}/lib" ]]; then \
        CUDA_LIBDIR="${CUDA_TARGET}/lib"; \
    elif [[ -d "${CUDA_TARGET}/lib64" ]]; then \
        CUDA_LIBDIR="${CUDA_TARGET}/lib64"; \
    elif [[ -d "${CUDA_PREFIX}/lib64" ]]; then \
        CUDA_LIBDIR="${CUDA_PREFIX}/lib64"; \
    else \
        echo "ERROR: CUDA runtime library directory not found" >&2; \
        exit 1; \
    fi; \
    \
    # Validate dependency locations
    test -n "${BOOST_LIBDIR}"; \
    test -n "${BZIP2_LIBDIR}"; \
    test -n "${FFTW_LIBDIR}"; \
    test -n "${TBB_LIBDIR}"; \
    test -n "${GOJSONNET_LIBDIR}"; \
    test -n "${ZLIB_LIBDIR}"; \
    test -d "${TDIR}/include"; \
    test -d "${TDIR}/include/torch/csrc/api/include"; \
    test -d "${TDIR}/lib"; \
    test -d "${CUDA_TARGET}/include"; \
    \
    # Expose Spack tools only for the WCT build.
    export PATH="${SPACK_VIEW}/bin:${GOJSONNET_PREFIX}/bin:${PATH}"; \
    export CPATH="${SPACK_VIEW}/include:${CPATH:-}"; \
    \
    export PKG_CONFIG_PATH="${FFTW_PREFIX}/lib/pkgconfig:${FFTW_PREFIX}/lib64/pkgconfig:${SPACK_VIEW}/lib/pkgconfig:${SPACK_VIEW}/lib64/pkgconfig:${SPACK_VIEW}/share/pkgconfig:${PKG_CONFIG_PATH:-}"; \
    \
    BUILD_LIBRARY_PATH="${BOOST_LIBDIR}:${BZIP2_LIBDIR}:${FFTW_LIBDIR}:${TBB_LIBDIR}:${GOJSONNET_LIBDIR}:${TDIR}/lib:${CUDA_LIBDIR}:${ZLIB_LIBDIR}:${SPACK_VIEW}/lib:${SPACK_VIEW}/lib64"; \
    \
    export LIBRARY_PATH="${BUILD_LIBRARY_PATH}:${LIBRARY_PATH:-}"; \
    export LD_LIBRARY_PATH="${BUILD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"; \
    \
    # Print resolved dependencies
    echo "=== Resolved build dependencies ==="; \
    echo "Boost:      ${BOOST_PREFIX}"; \
    echo "Bzip2:      ${BZIP2_PREFIX}"; \
    echo "FFTW:       ${FFTW_PREFIX}"; \
    echo "TBB:        ${TBB_PREFIX}"; \
    echo "GoJsonnet:  ${GOJSONNET_PREFIX}"; \
    echo "Zlib:       ${ZLIB_PREFIX}"; \
    echo "Torch:      ${TDIR}"; \
    echo "CUDA:       ${CUDA_PREFIX}"; \
    echo "CUDA libs:  ${CUDA_LIBDIR}"; \
    \
    # Verify Jsonnet
    echo "=== Jsonnet ==="; \
    command -v jsonnet; \
    jsonnet --version; \
    \
    # Verify FFTW pkg-config
    echo "=== FFTW pkg-config ==="; \
    pkg-config --modversion fftw3; \
    pkg-config --libs fftw3; \
    pkg-config --modversion fftw3f; \
    pkg-config --libs fftw3f; \
    \
    # Verify we still use NERSC PyTorch
    echo "=== NERSC PyTorch ==="; \
    "${NERSC_PYTHON}" -c \
        'import torch; print("Using PyTorch:", torch.__version__); print("From:", torch.__path__[0]); print("Built for CUDA:", torch.version.cuda)'; \
    \
    # Configure WCT
    cd "${WCT_SOURCE}"; \
    rm -rf build; \
    \
    ./wcb configure \
        --prefix="${SPACK_VIEW}" \
        --boost-mt \
        --boost-libs="${BOOST_LIBDIR}" \
        --boost-includes="${BOOST_PREFIX}/include" \
        --with-tbb="${TBB_PREFIX}" \
        --with-tbb-include="${TBB_PREFIX}/include" \
        --with-tbb-lib="${TBB_LIBDIR}" \
        --with-tbb-libs=tbb \
        --with-zlib="${ZLIB_PREFIX}" \
        --with-zlib-include="${ZLIB_PREFIX}/include" \
        --with-zlib-lib="${ZLIB_LIBDIR}" \
        --with-zlib-libs=z \
        --with-jsonnet="${GOJSONNET_PREFIX}" \
        --with-jsonnet-include="${GOJSONNET_PREFIX}/include" \
        --with-jsonnet-lib="${GOJSONNET_LIBDIR}" \
        --with-jsonnet-libs=gojsonnet \
        --with-bzip2="${BZIP2_PREFIX}" \
        --with-bzip2-include="${BZIP2_PREFIX}/include" \
        --with-bzip2-lib="${BZIP2_LIBDIR}" \
        --with-bzip2-libs=bz2 \
        --with-cuda="${CUDA_TARGET}" \
        --with-libtorch="${TDIR}" \
        --with-libtorch-include="${TDIR}/include,${TDIR}/include/torch/csrc/api/include,${CUDA_TARGET}/include" \
        --with-libtorch-lib="${TDIR}/lib,${CUDA_LIBDIR}"; \
    \
    # Build and install
    ./wcb -j "${BUILD_JOBS}"; \
    ./wcb install

# -----------------------------------------------------------------------------
# Runtime environment
# -----------------------------------------------------------------------------

ENV WIRECELL_PATH=/opt/wire-cell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg

ENV PATH=/opt/wire-cell-toolkit/build/apps:/opt/wirecell-view/bin:${PATH}

ENV LD_LIBRARY_PATH=/usr/local/lib/python3.10/dist-packages/torch/lib:/usr/local/cuda/targets/x86_64-linux/lib:/opt/wirecell-view/lib:/opt/wirecell-view/lib64:${LD_LIBRARY_PATH}

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------

RUN set -euo pipefail; \
    echo "=== Wire-Cell installation ==="; \
    which wire-cell; \
    wire-cell --version; \
    echo "=== NERSC PyTorch ==="; \
    "${NERSC_PYTHON}" -c \
        'import torch; print("Torch:", torch.__version__); print("CUDA:", torch.version.cuda)'

WORKDIR /workspace

CMD ["/bin/bash"]