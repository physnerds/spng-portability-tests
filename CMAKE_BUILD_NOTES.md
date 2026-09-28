# Wire-Cell Toolkit CMake Build Notes

These notes summarize the changes that made the CMake configuration of
Wire-Cell Toolkit succeed in the `wirecell-spng:cuda89` container.  They are
based on the successful configuration of the SPNG source tree under `/opt`.

## Build context

- Wire-Cell source: `/opt/wire-cell-toolkit`
- CMake build directory: `/opt/build`
- Install prefix: `/opt/install`
- Spack environment: `/opt/wirecell-env`
- Spack view: `/opt/wirecell-view`
- CUDA: `/usr/local/cuda` (CUDA 12.4)
- Compiler: GCC/G++ 11.5.0
- PyTorch: Spack `py-torch` 2.13.0 with CUDA support
- spdlog: Spack `spdlog` 1.10.0
- fmt required by Spack spdlog: Spack `fmt` 8.1.1

The tested source reported version `spng-0.35.0-1147-ga8d61722`.  Always
record the branch and commit because the intended build is from the
`spng-default-nvtx` branch, while the version string itself starts with
`spng`.

```bash
git -C /opt/wire-cell-toolkit branch --show-current
git -C /opt/wire-cell-toolkit rev-parse HEAD
```

## 1. Activate the dependency environment

The dependencies were already installed by Spack.  We activated that
environment and obtained the actual package prefixes from Spack instead of
assuming that every dependency could be found from `/opt/wirecell-view`.

```bash
source /opt/spack/share/spack/setup-env.sh
spack env activate /opt/wirecell-env

export FMT_PREFIX="$(spack -e /opt/wirecell-env location -i fmt)"
export SPDLOG_PREFIX="$(spack -e /opt/wirecell-env location -i spdlog)"
export PYTORCH_PREFIX="$(spack -e /opt/wirecell-env location -i py-torch)"
export PYTORCH_SITEPKG="$(find "$PYTORCH_PREFIX" \
    -type d -path '*/site-packages' -print -quit)"
export TORCH_SITE="$PYTORCH_SITEPKG/torch"
```

Useful checks before configuring:

```bash
test -f "$FMT_PREFIX/lib/cmake/fmt/fmt-config.cmake" || \
    test -f "$FMT_PREFIX/lib64/cmake/fmt/fmt-config.cmake"

find "$SPDLOG_PREFIX" -type f \
    \( -name 'spdlogConfig.cmake' -o -name 'spdlogConfigTargets.cmake' \) \
    -print

test -d "$TORCH_SITE/share/cmake/Torch"
```

In the tested installation, the CMake package directories were under `lib`,
so the successful configuration used the paths shown below.  If a future
Spack installation uses `lib64`, adjust `fmt_DIR` and `spdlog_DIR`.

## 2. Diagnose the spdlog/fmt mismatch

The old Waf build cache showed the combination that had already worked:

- spdlog used `SPDLOG_FMT_EXTERNAL`;
- spdlog included both its own headers and the Spack fmt 8 headers;
- spdlog linked both `spdlog` and `fmt`.

The Spack-generated `spdlogConfigTargets.cmake` also showed that
`spdlog::spdlog` links to `fmt::fmt`, and `spdlogConfig.cmake` calls
`find_dependency(fmt CONFIG)`.

The CMake build initially encountered a fmt header/version conflict.  PyTorch
contains bundled fmt 12 headers, but the Spack spdlog package was compiled
against external fmt 8.  Merely adding package prefixes to
`CMAKE_PREFIX_PATH` was not sufficient to control compiler header order.

The decisive workaround was:

```bash
-DCMAKE_CXX_FLAGS="-I$FMT_PREFIX/include"
```

This places the Spack fmt 8 include directory before Torch's bundled fmt 12
headers and prevents errors involving fmt internals such as `basic_runtime`.

## 3. Successful CMake configuration

Start with a clean out-of-source build directory when changing dependency
paths or branches:

```bash
rm -rf /opt/build
```

Then configure with explicit SPNG, Torch, spdlog, and fmt locations:

```bash
cmake -S /opt/wire-cell-toolkit -B /opt/build \
    -DWCT_WITH_SPNG=ON \
    -DWITH_LIBTORCH="$TORCH_SITE" \
    -DWITH_SPDLOG="$SPDLOG_PREFIX" \
    -Dfmt_DIR="$FMT_PREFIX/lib/cmake/fmt" \
    -Dspdlog_DIR="$SPDLOG_PREFIX/lib/cmake/spdlog" \
    -DCMAKE_CXX_FLAGS="-I$FMT_PREFIX/include" \
    -DCMAKE_PREFIX_PATH="$SPDLOG_PREFIX;$FMT_PREFIX;/opt/wirecell-view" \
    -DCMAKE_INSTALL_PREFIX=/opt/install \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
```

This configuration completed successfully and enabled these relevant
packages:

```text
pytorch;spng
```

It also found the CUDA-enabled LibTorch installation and generated the build
files in `/opt/build`.

## 4. Messages that were not fatal

### Kineto warning

Torch emitted this warning:

```text
library kineto not found
```

It did not prevent configuration and was not the cause of the fmt failure.

### `CUDA` listed as an absent optional WCT dependency

CMake reported `CUDA` among WCT's absent optional dependencies and disabled
the standalone WCT `cuda` package.  This is distinct from LibTorch CUDA
support.  In the same configure run, Torch successfully detected CUDA 12.4,
`nvcc`, and the CUDA toolkit.  Therefore, the optional WCT `cuda` message by
itself does not mean that the SPNG Torch/NVTX path is disabled.

### GPU architecture auto-detection

No GPU was exposed during configuration, so Torch selected a broad set of
common CUDA architectures.  This was not fatal, but it can make compilation
slower.  For a production image, explicitly limiting the architecture to the
target GPU (for example, compute capability 8.9 for an L40S/RTX 4090) may be
preferable after confirming the CMake variable honored by this source tree.

## 5. Build and install

We chose a serial, verbose build first so that any next error would be clear:

```bash
cmake --build /opt/build --verbose -j1 \
    2>&1 | tee /tmp/wct-cmake-build.log
```

After the build gets beyond `WireCellUtil` without the fmt
`basic_runtime` error, it can be resumed in parallel:

```bash
cmake --build /opt/build -j"$(nproc)" \
    2>&1 | tee -a /tmp/wct-cmake-build.log
```

Install after the build succeeds:

```bash
cmake --install /opt/build
```

The preserved session proves that the corrected **CMake configure step**
succeeded.  It does not, by itself, prove that the full compile and install
completed, so those results should be recorded separately when confirmed.

## 6. Verify the NVTX branch and implementation

Check both the source revision and the presence of the NVTX code:

```bash
git -C /opt/wire-cell-toolkit branch --show-current
git -C /opt/wire-cell-toolkit rev-parse HEAD

grep -RInE 'NVTX|nvtx|nvToolsExt' \
    /opt/wire-cell-toolkit/CMakeLists.txt \
    /opt/wire-cell-toolkit/cmake \
    /opt/wire-cell-toolkit/spng \
    /opt/wire-cell-toolkit/pgraph \
    | head -200
```

After compilation, also inspect the CMake cache, compile commands, and linked
libraries rather than assuming that checking out the branch enabled NVTX:

```bash
grep -iE 'nvtx|nvToolsExt' /opt/build/CMakeCache.txt || true
grep -iE 'nvtx|nvToolsExt' /opt/build/compile_commands.json | head -50 || true
find /opt/build -type f -perm /111 -exec sh -c '
    for file do
        ldd "$file" 2>/dev/null | grep -H -iE "nvtx|nvToolsExt" /dev/stdin && echo "$file"
    done
' sh {} +
```

The exact branch name, commit SHA, NVTX grep results, successful build, and
install/runtime checks are the remaining evidence needed for a complete
NVTX-enabled build record.
