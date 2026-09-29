# syntax=docker/dockerfile:1.7

# This image expects the dependency image produced by Dockerfile.dependencies.
# That image contains the concretized Spack environment but does not install
# Wire-Cell Toolkit itself.
ARG DEPENDENCY_IMAGE=wirecell-spng-deps:cuda89
FROM ${DEPENDENCY_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG WCT_REPOSITORY=https://github.com/WireCell/wire-cell-toolkit.git
ARG WCT_REF=spng-default-nvtx
ARG BUILD_JOBS=8
ARG with_nvtx=true

ENV SPACK_ROOT=/opt/spack
ENV SPACK_DISABLE_LOCAL_CONFIG=true
ENV SPACK_USER_CACHE_PATH=/opt/spack-cache/user

ENV WCT_ENV=/opt/wirecell-env
ENV SPACK_VIEW=/opt/wirecell-view
ENV WCT_SOURCE=/opt/wire-cell-toolkit
ENV WCT_BUILD=/opt/wire-cell-toolkit-build
ENV WCT_INSTALL=/opt/wirecell-view

ENV CUDA_PREFIX=/usr/local/cuda
ENV CUDA_TARGET=/usr/local/cuda/targets/x86_64-linux

# Keep system tools ahead of Spack libraries until the build environment is
# explicitly assembled.  The dependency image may carry an LD_LIBRARY_PATH
# that is incompatible with Rocky Linux system utilities.
ENV PATH=/opt/spack/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Native Jsonnet is required by Wire-Cell's build.  Add it only when it is not
# already installed, then regenerate the common Spack view.
RUN --mount=type=cache,target=/opt/spack-cache \
    --mount=type=cache,target=/opt/spack-stage \
    set -euo pipefail; \
    source "${SPACK_ROOT}/share/spack/setup-env.sh"; \
    if ! spack -e "${WCT_ENV}" find --format '{name}' jsonnet 2>/dev/null | grep -qx jsonnet; then \
        echo "Native jsonnet is missing; adding it to ${WCT_ENV}"; \
        spack -e "${WCT_ENV}" add jsonnet; \
        spack -e "${WCT_ENV}" concretize; \
        spack -e "${WCT_ENV}" install --fail-fast --show-log-on-error jsonnet; \
    else \
        echo "Native jsonnet is already installed"; \
    fi; \
    spack -e "${WCT_ENV}" env view enable "${SPACK_VIEW}"; \
    spack -e "${WCT_ENV}" env view regenerate; \
    JSONNET_PREFIX="$(spack -e "${WCT_ENV}" location -i jsonnet)"; \
    find "${JSONNET_PREFIX}" \( -name 'libjsonnet.so*' -o -name 'libjsonnet.a' \) -print -quit | grep -q .

# Clone the NVTX-enabled SPNG branch.  WCT_REF remains a build argument so a
# different branch or tag can be selected without editing the file.
COPY patches/wct-nvtx3-header-only.patch /tmp/wct-nvtx3-header-only.patch
RUN set -euo pipefail; \
    git clone --branch "${WCT_REF}" --single-branch \
        "${WCT_REPOSITORY}" "${WCT_SOURCE}"; \
    git -C "${WCT_SOURCE}" apply --check /tmp/wct-nvtx3-header-only.patch; \
    git -C "${WCT_SOURCE}" apply /tmp/wct-nvtx3-header-only.patch; \
    git -C "${WCT_SOURCE}" apply --reverse --check /tmp/wct-nvtx3-header-only.patch; \
    git -C "${WCT_SOURCE}" diff --check; \
    grep -Fq \
        'PATH_SUFFIXES include/nvtx3 targets/x86_64-linux/include/nvtx3 include)' \
        "${WCT_SOURCE}/cmake/WCTDependencies.cmake"; \
    if grep -Fq 'find_library(WCT_NVTX_LIBRARY' \
        "${WCT_SOURCE}/cmake/WCTDependencies.cmake"; then \
        echo "ERROR: legacy NVTX library detection remains after patching" >&2; \
        exit 1; \
    fi; \
    echo "Applied NVTX3 header-only CMake patch:"; \
    git -C "${WCT_SOURCE}" diff --stat; \
    git -C "${WCT_SOURCE}" rev-parse HEAD; \
    grep -RIlE 'NVTX|nvtx|nvToolsExt' \
        "${WCT_SOURCE}/CMakeLists.txt" \
        "${WCT_SOURCE}/cmake" \
        "${WCT_SOURCE}/spng" \
        "${WCT_SOURCE}/pgraph" \
        | sed -n '1,20p' \
        || true

# Configure, compile, and install with CMake.
#
# CMake is itself installed by Spack and is not assumed to be on PATH.  Its
# hashed installation prefix is resolved at build time instead of hard-coded.
#
# spdlog 1.10 in this environment was built against external fmt 8, while
# PyTorch carries fmt 12 headers.  Putting the Spack fmt include directory in
# CMAKE_CXX_FLAGS preserves the include order that fixed the basic_runtime
# compilation failure.
RUN --mount=type=cache,target=/opt/spack-cache \
    --mount=type=cache,target=/opt/spack-stage \
    set -euo pipefail; \
    source "${SPACK_ROOT}/share/spack/setup-env.sh"; \
    spack env activate "${WCT_ENV}"; \
    CMAKE_PREFIX="$(spack -e "${WCT_ENV}" location -i cmake)"; \
    CMAKE_BIN="${CMAKE_PREFIX}/bin/cmake"; \
    FMT_PREFIX="$(spack -e "${WCT_ENV}" location -i fmt)"; \
    SPDLOG_PREFIX="$(spack -e "${WCT_ENV}" location -i spdlog)"; \
    PYTORCH_PREFIX="$(spack -e "${WCT_ENV}" location -i py-torch)"; \
    PYTORCH_SITEPKG="$(find "${PYTORCH_PREFIX}" -type d -path '*/site-packages' -print -quit)"; \
    TORCH_SITE="${PYTORCH_SITEPKG}/torch"; \
    FMT_CONFIG="$(find "${FMT_PREFIX}" -type f \( -name 'fmt-config.cmake' -o -name 'fmtConfig.cmake' \) -print -quit)"; \
    SPDLOG_CONFIG="$(find "${SPDLOG_PREFIX}" -type f \( -name 'spdlogConfig.cmake' -o -name 'spdlog-config.cmake' \) -print -quit)"; \
    FMT_CMAKE_DIR="$(dirname "${FMT_CONFIG}")"; \
    SPDLOG_CMAKE_DIR="$(dirname "${SPDLOG_CONFIG}")"; \
    test -x "${CMAKE_BIN}"; \
    test -n "${FMT_CONFIG}"; \
    test -n "${SPDLOG_CONFIG}"; \
    test -d "${TORCH_SITE}/include"; \
    test -d "${TORCH_SITE}/share/cmake/Torch"; \
    case "${with_nvtx}" in \
        true) \
            NVTX_PREFIX="$(spack -e "${WCT_ENV}" location -i nvtx)"; \
            NVTX_INCLUDE_DIR="${NVTX_PREFIX}/include/nvtx3"; \
            test -f "${NVTX_INCLUDE_DIR}/nvToolsExt.h"; \
            NVTX_CMAKE_ARGS=( \
                -DWCT_WITH_NVTX=ON \
                "-DWCT_NVTX_INCLUDE_DIR=${NVTX_INCLUDE_DIR}" \
            ) \
            ;; \
        false) \
            NVTX_INCLUDE_DIR="disabled"; \
            NVTX_CMAKE_ARGS=() \
            ;; \
        *) echo "ERROR: with_nvtx must be true or false" >&2; exit 2 ;; \
    esac; \
    BUILD_LIBRARY_PATH="${TORCH_SITE}/lib:${CUDA_TARGET}/lib:${CUDA_TARGET}/lib64:${CUDA_PREFIX}/lib64:${SPACK_VIEW}/lib:${SPACK_VIEW}/lib64"; \
    BUILD_PKG_CONFIG_PATH="${SPACK_VIEW}/lib/pkgconfig:${SPACK_VIEW}/lib64/pkgconfig:${SPACK_VIEW}/share/pkgconfig"; \
    echo "Resolved CMake build tools and dependencies:"; \
    echo "  CMake:  ${CMAKE_BIN}"; \
    echo "  fmt:    ${FMT_PREFIX} (${FMT_CMAKE_DIR})"; \
    echo "  spdlog: ${SPDLOG_PREFIX} (${SPDLOG_CMAKE_DIR})"; \
    echo "  Torch:  ${TORCH_SITE}"; \
    echo "  NVTX:   ${NVTX_INCLUDE_DIR}"; \
    "${CMAKE_BIN}" --version; \
    rm -rf "${WCT_BUILD}"; \
    LD_LIBRARY_PATH="${BUILD_LIBRARY_PATH}" \
    PKG_CONFIG_PATH="${BUILD_PKG_CONFIG_PATH}" \
    "${CMAKE_BIN}" -S "${WCT_SOURCE}" -B "${WCT_BUILD}" \
        "${NVTX_CMAKE_ARGS[@]}" \
        -DWCT_WITH_SPNG=ON \
        -DWITH_LIBTORCH="${TORCH_SITE}" \
        -DWITH_SPDLOG="${SPDLOG_PREFIX}" \
        -Dfmt_DIR="${FMT_CMAKE_DIR}" \
        -Dspdlog_DIR="${SPDLOG_CMAKE_DIR}" \
        -DCMAKE_CXX_FLAGS="-I${FMT_PREFIX}/include" \
        -DCMAKE_PREFIX_PATH="${SPDLOG_PREFIX};${FMT_PREFIX};${SPACK_VIEW}" \
        -DCMAKE_INSTALL_PREFIX="${WCT_INSTALL}" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON; \
    LIBRARY_PATH="${BUILD_LIBRARY_PATH}" \
    LD_LIBRARY_PATH="${BUILD_LIBRARY_PATH}" \
    PKG_CONFIG_PATH="${BUILD_PKG_CONFIG_PATH}" \
    "${CMAKE_BIN}" --build "${WCT_BUILD}" --parallel "${BUILD_JOBS}"; \
    LD_LIBRARY_PATH="${BUILD_LIBRARY_PATH}" \
    "${CMAKE_BIN}" --install "${WCT_BUILD}"

# Add runtime paths only after system-package operations and compilation have
# completed.  The Spack view is also the CMake installation prefix.
ENV PATH=/opt/wirecell-view/bin:/opt/spack/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/opt/wirecell-view/lib:/opt/wirecell-view/lib64:/usr/local/cuda/targets/x86_64-linux/lib:/usr/local/cuda/lib64

RUN set -euo pipefail; \
    test -x "${WCT_INSTALL}/bin/wire-cell"; \
    "${WCT_INSTALL}/bin/wire-cell" --version; \
    if ldd "${WCT_INSTALL}/bin/wire-cell" | grep -q 'not found'; then \
        ldd "${WCT_INSTALL}/bin/wire-cell"; \
        exit 1; \
    fi

COPY entrypoint.sh /usr/local/bin/wirecell-entrypoint
RUN chmod 0755 /usr/local/bin/wirecell-entrypoint

ENV WCT_DEV=/opt/wire-cell-toolkit
ENV WIRECELL_PATH=/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng:/opt/wire-cell-toolkit/spng/cfg:/opt/wire-cell-toolkit/wire-cell-data:/opt/wirecell-view/share/wirecell

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/wirecell-entrypoint"]
CMD ["bash"]
