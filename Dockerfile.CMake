# Build from the prepared Spack dependency image; see local-build/Installation.md.
ARG dependency_image=wirecell-spng-deps:cuda80
FROM ${dependency_image}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG wct_ref=1cee1141436a3d2f322aa54c4f0ebe4f6bf49a5c
ARG build_jobs=4
ARG with_nvtx=ON
ARG cuda_arch=80
ARG torch_cuda_arch=8.0
COPY local-build/patches/wct-nvtx3-header-only.patch /tmp/wct-nvtx3-header-only.patch
RUN set -eu; \
    git init /opt/wire-cell-toolkit; \
    cd /opt/wire-cell-toolkit; \
    git remote add origin https://github.com/WireCell/wire-cell-toolkit.git; \
    git fetch --depth 1 origin "${wct_ref}"; \
    git checkout --detach FETCH_HEAD; \
    git rev-parse HEAD > /opt/wct-source-revision.txt; \
    case "${with_nvtx}" in \
      ON) git apply --check /tmp/wct-nvtx3-header-only.patch; \
          git apply /tmp/wct-nvtx3-header-only.patch ;; \
      OFF) ;; \
      *) echo 'with_nvtx must be ON or OFF' >&2; exit 1 ;; \
    esac
RUN set -eu; \
    source /opt/spack/share/spack/setup-env.sh; \
    spack env activate /opt/wirecell-env; \
    cmake_prefix=$(spack location -i cmake); \
    fmt_prefix=$(spack location -i fmt); \
    spdlog_prefix=$(spack location -i spdlog); \
    python_prefix=$(spack location -i python); \
    export PATH="${python_prefix}/bin:${PATH}"; \
    torch_prefix=$(python3 -c 'import torch; print(torch.utils.cmake_prefix_path)'); \
    nvtx_args=(); \
    if [[ "${with_nvtx}" == ON ]]; then \
      nvtx_prefix=$(spack location -i nvtx 2>/dev/null || spack location -i cuda); \
      nvtx_include="${nvtx_prefix}/include/nvtx3"; \
      if [[ ! -r "${nvtx_include}/nvToolsExt.h" ]]; then \
        nvtx_include="${nvtx_prefix}/targets/x86_64-linux/include/nvtx3"; \
      fi; \
      test -r "${nvtx_include}/nvToolsExt.h"; \
      nvtx_args+=("-DWCT_NVTX_INCLUDE_DIR=${nvtx_include}"); \
    fi; \
    "${cmake_prefix}/bin/cmake" \
      -S /opt/wire-cell-toolkit -B /opt/wire-cell-toolkit-build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/wirecell-view \
      "-DCMAKE_PREFIX_PATH=/opt/wirecell-view;${torch_prefix};${fmt_prefix};${spdlog_prefix}" \
      "-DPython3_EXECUTABLE=${python_prefix}/bin/python3" \
      "-DPYTHON_EXECUTABLE=${python_prefix}/bin/python3" \
      "-DCMAKE_CXX_FLAGS=-I${fmt_prefix}/include" \
      "-DCMAKE_CUDA_ARCHITECTURES=${cuda_arch}" \
      "-DTORCH_CUDA_ARCH_LIST=${torch_cuda_arch}" \
      -DWITH_LIBTORCH=yes -DWCT_WITH_SPNG=ON \
      "-DWCT_WITH_NVTX=${with_nvtx}" "${nvtx_args[@]}" \
      -DWCT_WITH_TESTS=OFF -DWCT_INSTALL_CONFIG=all \
      -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
      '-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib'; \
    "${cmake_prefix}/bin/cmake" --build /opt/wire-cell-toolkit-build --parallel "${build_jobs}"; \
    "${cmake_prefix}/bin/cmake" --install /opt/wire-cell-toolkit-build
ENV PATH="/opt/wirecell-view/bin:${PATH}"
ENV WIRECELL_PATH="/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg"
WORKDIR /opt/wire-cell-toolkit
CMD ["wire-cell", "--version"]
