# syntax=docker/dockerfile:1.7

ARG CUDA_IMAGE=nvidia/cuda:12.4.1-devel-rockylinux9
FROM ${CUDA_IMAGE} AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG SPACK_REF=v1.0.0
ARG WIRECELL_SPACK_REF=master
ARG WIRECELL_TOOLKIT_REF=spng

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# Make copying of the customized package.py optional
ARG USE_CUSTOM_PACKAGE=false
COPY wirecell-package/package.py /tmp/wire-cell-toolkit-package.py

ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTPS_PROXY}
ENV no_proxy=${NO_PROXY}
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV NO_PROXY=${NO_PROXY}

ENV SPACK_ROOT=/opt/spack
ENV SPACK_USER_CACHE_PATH=/opt/spack-cache/user
ENV SPACK_DISABLE_LOCAL_CONFIG=true

ENV PATH=/opt/spack/bin:/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# Base build tools only. WireCell dependencies are installed by Spack.
RUN dnf install -y \
        bash \
        bzip2 \
        ca-certificates \
        curl \
        file \
        findutils \
        gcc \
        gcc-c++ \
        gcc-gfortran \
        git \
        gzip \
        hostname \
        make \
        patch \
        python3 \
        python3-pip \
        tar \
        unzip \
        which \
        xz \
    && dnf clean all

# Verify the expected system compiler.
RUN gcc --version \
    && g++ --version \
    && gfortran --version \
    && nvcc --version

# Install a private pinned Spack checkout.
RUN git clone https://github.com/spack/spack.git "${SPACK_ROOT}" \
    && git -C "${SPACK_ROOT}" checkout "${SPACK_REF}"

# Install a private pinned WireCell package repository.
RUN git clone \
        https://github.com/WireCell/wire-cell-spack.git \
        /opt/wire-cell-spack \
    && git -C /opt/wire-cell-spack checkout "${WIRECELL_SPACK_REF}"

# Replace the upstream recipe with the NVTX-enabled recipe.
RUN if [[ "${USE_CUSTOM_PACKAGE}" == "true" ]]; then \
        echo "Installing customized wire_cell_toolkit/package.py"; \
        cp /tmp/wire-cell-toolkit-package.py \
           /opt/wire-cell-spack/spack_repo/wirecell/packages/wire_cell_toolkit/package.py; \
    else \
        echo "Using package.py from the wire-cell-spack repository"; \
    fi \
    && rm -f /tmp/wire-cell-toolkit-package.py

# Add the Spack environment.
RUN mkdir -p \
        /opt/wirecell-env \
        /opt/spack-cache/source \
        /opt/spack-cache/misc \
        /opt/spack-cache/test \
        /opt/spack-cache/user \
        /opt/spack-stage \
        /opt/spack-install

COPY spack.yaml /opt/wirecell-env/spack.yaml

# Confirm that Spack sees the private repository and custom variants.
RUN source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack --version \
    && spack -e /opt/wirecell-env repo list \
    && spack -e /opt/wirecell-env info wire-cell-toolkit

# Make compiler discovery environment-local.
RUN source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack -e /opt/wirecell-env compiler find --scope env /usr \
    && spack -e /opt/wirecell-env compilers

# Concretize without consulting packages from other Spack installations.
RUN source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack -e /opt/wirecell-env concretize --fresh \
    && spack -e /opt/wirecell-env spec -Il

# Build WireCell Toolkit SPNG and its full dependency graph.
RUN --mount=type=cache,target=/opt/spack-cache \
    --mount=type=cache,target=/opt/spack-stage \
    source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack -e /opt/wirecell-env install \
        --fail-fast \
        --show-log-on-error \
        --verbose

# Record the complete installation for inspection.
RUN source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack -e /opt/wirecell-env find -dlv \
        > /opt/wirecell-env/installed-packages.txt \
    && spack -e /opt/wirecell-env location \
        -i wire-cell-toolkit \
        > /opt/wirecell-env/wirecell-prefix.txt

# Optional development source tree.
RUN git clone \
        https://github.com/WireCell/wire-cell-toolkit.git \
        /opt/wire-cell-toolkit \
    && git -C /opt/wire-cell-toolkit checkout "${WIRECELL_TOOLKIT_REF}"

COPY entrypoint.sh /usr/local/bin/wirecell-entrypoint
RUN chmod 0755 /usr/local/bin/wirecell-entrypoint

ENV WCT_ENV=/opt/wirecell-env
ENV WCT_DEV=/opt/wire-cell-toolkit
ENV SPACK_VIEW=/opt/wirecell-view

ENV PATH=/opt/wirecell-view/bin:/opt/spack/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/wirecell-view/lib:/opt/wirecell-view/lib64:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
ENV PYTHONPATH=/opt/wirecell-view/lib/python3/site-packages:${PYTHONPATH}

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/wirecell-entrypoint"]
CMD ["bash"]