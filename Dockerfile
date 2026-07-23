# syntax=docker/dockerfile:1.7

ARG DEPENDENCY_IMAGE=wirecell-spng-deps:cuda89
FROM ${DEPENDENCY_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG WCT_REPOSITORY=https://github.com/WireCell/wire-cell-toolkit.git
ARG WCT_REF=spng
ARG BUILD_JOBS=16

ENV SPACK_ROOT=/opt/spack
ENV SPACK_DISABLE_LOCAL_CONFIG=true
ENV SPACK_USER_CACHE_PATH=/opt/spack-cache/user

ENV WCT_ENV=/opt/wirecell-env
ENV SPACK_VIEW=/opt/wirecell-view
ENV WCT_SOURCE=/opt/wire-cell-toolkit

ENV CUDA_PREFIX=/usr/local/cuda
ENV CUDA_TARGET=/usr/local/cuda/targets/x86_64-linux

# Keep build-time PATH minimal and safe. Do not expose the Spack view through
# LD_LIBRARY_PATH globally before running system tools such as dnf and diff.
ENV PATH=/opt/spack/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Wire-Cell's configure step requires the `diff` command.
#
# Run dnf and diff with LD_LIBRARY_PATH explicitly cleared. The dependency
# image may define LD_LIBRARY_PATH with Spack libraries that are incompatible
# with Rocky Linux system commands and can cause exit code 139.
RUN set -euo pipefail; \
    if ! env -u LD_LIBRARY_PATH command -v diff >/dev/null 2>&1; then \
        env -u LD_LIBRARY_PATH dnf --disablerepo=cuda install -y diffutils; \
        env -u LD_LIBRARY_PATH dnf clean all; \
        rm -rf /var/cache/dnf; \
    fi; \
    env -u LD_LIBRARY_PATH command -v diff; \
    env -u LD_LIBRARY_PATH diff --version > /tmp/diff-version.txt; \
    sed -n '1p' /tmp/diff-version.txt; \
    rm -f /tmp/diff-version.txt

# Add native Jsonnet only when it is missing from the environment.
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

# Clone Wire-Cell Toolkit directly from the SPNG branch.
RUN set -euo pipefail; \
    git clone --branch "${WCT_REF}" --single-branch "${WCT_REPOSITORY}" "${WCT_SOURCE}"; \
    test "$(git -C "${WCT_SOURCE}" rev-parse --abbrev-ref HEAD)" = "${WCT_REF}"; \
    git -C "${WCT_SOURCE}" rev-parse HEAD

# Resolve dependency locations from Spack, configure, build and install
# Wire-Cell into /opt/wirecell-view.
RUN --mount=type=cache,target=/opt/spack-cache \
    --mount=type=cache,target=/opt/spack-stage \
    set -euo pipefail; \
    source "${SPACK_ROOT}/share/spack/setup-env.sh"; \
    spack env activate "${WCT_ENV}"; \
    BOOST_PREFIX="$(spack -e "${WCT_ENV}" location -i boost)"; \
    JSONNET_PREFIX="$(spack -e "${WCT_ENV}" location -i jsonnet)"; \
    BZIP2_PREFIX="$(spack -e "${WCT_ENV}" location -i bzip2)"; \
    TBB_PREFIX="$(spack -e "${WCT_ENV}" location -i intel-tbb)"; \
    PYTORCH_PREFIX="$(spack -e "${WCT_ENV}" location -i py-torch)"; \
    ZLIB_PREFIX="$(spack -e "${WCT_ENV}" location -i zlib-ng)"; \
    ZLIB_LIBDIR="${ZLIB_PREFIX}/lib"; \
    BOOST_LIBDIR="$(for directory in "${BOOST_PREFIX}/lib" "${BOOST_PREFIX}/lib64"; do if compgen -G "${directory}/libboost_filesystem*" >/dev/null; then echo "${directory}"; break; fi; done)"; \
    JSONNET_LIBDIR="$(for directory in "${JSONNET_PREFIX}/lib" "${JSONNET_PREFIX}/lib64"; do if compgen -G "${directory}/libjsonnet.so*" >/dev/null || [[ -f "${directory}/libjsonnet.a" ]]; then echo "${directory}"; break; fi; done)"; \
    BZIP2_LIBDIR="$(for directory in "${BZIP2_PREFIX}/lib" "${BZIP2_PREFIX}/lib64"; do if compgen -G "${directory}/libbz2.so*" >/dev/null || [[ -f "${directory}/libbz2.a" ]]; then echo "${directory}"; break; fi; done)"; \
    TBB_LIBDIR="$(for directory in "${TBB_PREFIX}/lib" "${TBB_PREFIX}/lib64"; do if compgen -G "${directory}/libtbb.so*" >/dev/null; then echo "${directory}"; break; fi; done)"; \
    PYTORCH_SITEPKG="$(find "${PYTORCH_PREFIX}" -type d -path '*/site-packages' -print -quit)"; \
    TDIR="${PYTORCH_SITEPKG}/torch"; \
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
    CUDA_STUBDIR=""; \
    for directory in \
    "${CUDA_TARGET}/lib/stubs" \
    "${CUDA_TARGET}/lib64/stubs" \
    "${CUDA_PREFIX}/lib64/stubs"; \
    do \
    if [[ -f "${directory}/libcuda.so" ]]; then \
        CUDA_STUBDIR="${directory}"; \
        break; \
    fi; \
    done; \
    \
    if [[ -z "${CUDA_STUBDIR}" ]]; then \
    echo "ERROR: CUDA stub library libcuda.so not found" >&2; \
    find "${CUDA_PREFIX}" -name 'libcuda.so*' -print >&2; \
    exit 1; \
    fi; \
    test -n "${BOOST_LIBDIR}"; \
    test -n "${JSONNET_LIBDIR}"; \
    test -n "${BZIP2_LIBDIR}"; \
    test -n "${TBB_LIBDIR}"; \
    test -d "${TDIR}/include"; \
    test -d "${TDIR}/include/torch/csrc/api/include"; \
    test -d "${TDIR}/lib"; \
    test -d "${CUDA_TARGET}/include"; \
    BUILD_LIBRARY_PATH="${BOOST_LIBDIR}:${JSONNET_LIBDIR}:${BZIP2_LIBDIR}:${TBB_LIBDIR}:${TDIR}/lib:${CUDA_LIBDIR}:${CUDA_STUBDIR}:${ZLIB_LIBDIR}:${SPACK_VIEW}/lib:${SPACK_VIEW}/lib64"; \
    echo "Resolved build dependencies:"; \
    echo "  Boost:   ${BOOST_PREFIX} (${BOOST_LIBDIR})"; \
    echo "  Jsonnet: ${JSONNET_PREFIX} (${JSONNET_LIBDIR})"; \
    echo "  Bzip2:   ${BZIP2_PREFIX} (${BZIP2_LIBDIR})"; \
    echo "  TBB:     ${TBB_PREFIX} (${TBB_LIBDIR})"; \
    echo "  Torch:   ${TDIR}"; \
    echo "  CUDA:    ${CUDA_TARGET} (${CUDA_LIBDIR})"; \
    cd "${WCT_SOURCE}"; \
    rm -rf build; \
    LD_LIBRARY_PATH="${BUILD_LIBRARY_PATH}" ./wcb configure \
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
        --with-jsonnet="${JSONNET_PREFIX}" \
        --with-jsonnet-include="${JSONNET_PREFIX}/include" \
        --with-jsonnet-lib="${JSONNET_LIBDIR}" \
        --with-jsonnet-libs=jsonnet \
        --with-bzip2="${BZIP2_PREFIX}" \
        --with-bzip2-include="${BZIP2_PREFIX}/include" \
        --with-bzip2-lib="${BZIP2_LIBDIR}" \
        --with-bzip2-libs=bz2 \
        --with-cuda="${CUDA_TARGET}" \
        --with-libtorch="${TDIR}" \
        --with-libtorch-include="${TDIR}/include,${TDIR}/include/torch/csrc/api/include,${CUDA_TARGET}/include" \
        --with-libtorch-lib="${TDIR}/lib,${CUDA_LIBDIR}"; \
    LIBRARY_PATH="${BUILD_LIBRARY_PATH}" \
    LD_LIBRARY_PATH="${BUILD_LIBRARY_PATH}" ./wcb -j "${BUILD_JOBS}"; \
    ./wcb install;
# Runtime paths are added only after all system-package operations and the
# Wire-Cell build have completed.
ENV PATH=/opt/wirecell-view/bin:/opt/spack/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/opt/wirecell-view/lib:/opt/wirecell-view/lib64:/usr/local/cuda/lib64

RUN set -euo pipefail; \
    test -x "${SPACK_VIEW}/bin/wire-cell"; \
    "${SPACK_VIEW}/bin/wire-cell" --version; \
    if ldd "${SPACK_VIEW}/bin/wire-cell" | grep -q 'not found'; then \
        ldd "${SPACK_VIEW}/bin/wire-cell"; \
        exit 1; \
    fi

COPY entrypoint.sh /usr/local/bin/wirecell-entrypoint
RUN chmod 0755 /usr/local/bin/wirecell-entrypoint

ENV WCT_DEV=/opt/wire-cell-toolkit
ENV WIRECELL_PATH=/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng:/opt/wire-cell-toolkit/spng/cfg:/opt/wire-cell-toolkit/wire-cell-data:/opt/wirecell-view/share/wirecell

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/wirecell-entrypoint"]
CMD ["bash"]
