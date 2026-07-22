# syntax=docker/dockerfile:1.7

ARG DEPENDENCY_IMAGE=wirecell-spng-deps:cuda89
FROM ${DEPENDENCY_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG USE_CUSTOM_PACKAGE=false
ARG PACKAGE_RECIPE_REV=1

ENV SPACK_ROOT=/opt/spack
ENV SPACK_DISABLE_LOCAL_CONFIG=true
ENV SPACK_USER_CACHE_PATH=/opt/spack-cache/user

ENV PATH=/opt/spack/bin:/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

# WireCell's configure step requires the `diff` command.
RUN dnf --disablerepo=cuda install -y diffutils \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Docker cannot conditionally COPY a file based on a build argument.
# Therefore, keep wirecell-package/ in the build context even when the
# custom recipe is disabled.
COPY wirecell-package/ /tmp/wirecell-package/

RUN set -euo pipefail; \
    echo "WireCell recipe revision: ${PACKAGE_RECIPE_REV}"; \
    echo "USE_CUSTOM_PACKAGE: ${USE_CUSTOM_PACKAGE}"; \
    \
    case "${USE_CUSTOM_PACKAGE}" in \
        true|false) ;; \
        *) \
            echo "ERROR: USE_CUSTOM_PACKAGE must be true or false"; \
            exit 1; \
            ;; \
    esac; \
    \
    destination="/opt/wire-cell-spack/spack_repo/wirecell/packages/wire_cell_toolkit/package.py"; \
    override="/tmp/wirecell-package/package.py"; \
    \
    test -f "${destination}" || { \
        echo "ERROR: WireCell package recipe is missing from dependency image:"; \
        echo "  ${destination}"; \
        exit 1; \
    }; \
    \
    if [[ "${USE_CUSTOM_PACKAGE}" == "true" ]]; then \
        test -f "${override}" || { \
            echo "ERROR: USE_CUSTOM_PACKAGE=true but custom recipe is missing:"; \
            echo "  ${override}"; \
            exit 1; \
        }; \
        cp "${override}" "${destination}"; \
        echo "Installed custom package.py"; \
    else \
        echo "Using package.py stored in dependency image"; \
    fi; \
    \
    rm -rf /tmp/wirecell-package

# Print and validate the active WireCell recipe before starting the build.
RUN set -euo pipefail; \
    recipe="/opt/wire-cell-spack/spack_repo/wirecell/packages/wire_cell_toolkit/package.py"; \
    \
    echo "Active WireCell recipe:"; \
    sha256sum "${recipe}"; \
    \
    echo "NVTX configuration lines:"; \
    grep -n -A3 -B3 "with-nvtx" "${recipe}" || true; \
    \
    echo "Obsolete Boost patch references:"; \
    grep -n -A3 -B3 \
        "remove-boost-system-config-test.patch" \
        "${recipe}" || true; \
    \
    if grep -q -- "--with-nvtx=" "${recipe}"; then \
        echo "ERROR: package.py passes a value to --with-nvtx."; \
        echo "WireCell expects --with-nvtx as a Boolean flag."; \
        exit 1; \
    fi

# Confirm that required build commands are available.
RUN set -euo pipefail; \
    command -v diff; \
    command -v bash; \
    command -v python3; \
    diff --version | head -n1

# Install only wire-cell-toolkit. Its concretized dependencies already
# exist in the dependency image.
RUN --mount=type=cache,target=/opt/spack-cache \
    --mount=type=cache,target=/opt/spack-stage \
    source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack -e /opt/wirecell-env install \
        --verbose \
        --only package \
        --fail-fast \
        --show-log-on-error

# Verify installation and the environment view.
RUN source "${SPACK_ROOT}/share/spack/setup-env.sh" \
    && spack -e /opt/wirecell-env find -p wire-cell-toolkit \
    && test -x /opt/wirecell-view/bin/wire-cell \
    && /opt/wirecell-view/bin/wire-cell --version

COPY entrypoint.sh /usr/local/bin/wirecell-entrypoint

RUN chmod 0755 /usr/local/bin/wirecell-entrypoint

ENV WCT_ENV=/opt/wirecell-env
ENV SPACK_VIEW=/opt/wirecell-view

ENV PATH=/opt/wirecell-view/bin:/opt/spack/bin:/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/opt/wirecell-view/lib:/opt/wirecell-view/lib64:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/wirecell-entrypoint"]
CMD ["bash"]