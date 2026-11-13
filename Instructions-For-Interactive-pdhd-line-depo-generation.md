# Interactively generate PDHD line deposits in Apptainer

This procedure enters the SPNG Apptainer image, installs the Python tools in
an ephemeral virtual environment, and generates PDHD line-deposit NPZ files.
It is an interactive preparation/debugging workflow, not an HTCondor submit
procedure.

## 1. Prepare persistent host paths

Run these commands from the `spng-portability-tests` checkout on the `sgpu`
host:

```bash
export PROJECT_DIR="$PWD"
export IMAGE=/home/dune/users/abashyal/image-location/wirecell-spng-cuda89.sif
export LINE_DEPO_OUTPUT="$PROJECT_DIR/pdhd-line-depos-interactive"

test -r "$IMAGE"
test -d "$PROJECT_DIR/wire-cell-data"
test -r "$PROJECT_DIR/scaling/pdhd/generate_line_depos.py"
test -r "$PROJECT_DIR/scaling/pdhd/line-depo-template.sh.in"
mkdir -p "$LINE_DEPO_OUTPUT"
```

The output directory is explicitly bound to `/work` so generated files remain
available after leaving the container.

## 2. Enter Apptainer

The basic site command is:

```bash
apptainer exec \
  --bind wire-cell-data:/opt/wire-cell-data/ \
  --nv \
  --pwd /work \
  /home/dune/users/abashyal/image-location/wirecell-spng-cuda89.sif \
  /usr/local/bin/wirecell-entrypoint bash -i
```

For persistent output and access to the helper script, use this expanded
version from the project checkout:

```bash
apptainer exec \
  --bind "$PROJECT_DIR/wire-cell-data:/opt/wire-cell-data:ro" \
  --bind "$PROJECT_DIR:$PROJECT_DIR:ro" \
  --bind "$LINE_DEPO_OUTPUT:/work" \
  --nv \
  --pwd /work \
  "$IMAGE" \
  /usr/local/bin/wirecell-entrypoint bash -i
```

The `line_depo` generator itself is CPU-only. The `--nv` option is retained to
match the standard SPNG container entry command; it does not imply that deposit
generation consumes a GPU.

## 3. Create the temporary Python environment

Inside Apptainer:

```bash
/opt/wirecell-view/bin/python -m venv /tmp/my-venv
source /tmp/my-venv/bin/activate
pip install uv
ls -lht

uv tool install git+https://github.com/wirecell/wire-cell-python
export PATH="$(uv tool dir --bin):$PATH"
hash -r
```

`uv tool install` uses an isolated environment. If it attempts to compile
`gojsonnet` and fails because the container has no Go compiler, install
WireCell Python into the active virtual environment instead:

```bash
uv pip install --only-binary=gojsonnet \
  'git+https://github.com/WireCell/wire-cell-python.git'
hash -r
```

Do not install a Go compiler merely to work around this error when a compatible
`gojsonnet` wheel is available.

Verify the environment before generating anything:

```bash
command -v python
command -v wcpy

wcpy --help >/dev/null
```

## 4. Configure WireCell data lookup

Inside Apptainer:

```bash
export WIRECELL_PATH=/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg:/opt/wire-cell-data
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1

```

## 5. Generate one line deposit directly with `wcpy`

This uses the PDHD defaults adopted by the repository generator for plane 0
and a 0-degree XZ angle:

```bash
mkdir -p /work/pdhd-line-p0-txz0-ty90

wcpy gen detlinegen \
  --offset '+1*m,0*m,0*m' \
  --detector=pdhd \
  --plane=0 \
  --angle-coords=wire-plane \
  --theta_xz='0*deg' \
  --theta_y='90*deg' \
  --output_depos /work/pdhd-line-p0-txz0-ty90/data.npz \
  --output_meta /work/pdhd-line-p0-txz0-ty90/meta.json
```

Check the result:

```bash
ls -lh /work/pdhd-line-p0-txz0-ty90/data.npz \
       /work/pdhd-line-p0-txz0-ty90/meta.json

python - <<'PY'
import zipfile

with zipfile.ZipFile('/work/pdhd-line-p0-txz0-ty90/data.npz') as archive:
    print('\n'.join(archive.namelist()))
PY
```

The archive must contain a matched `depo_data_0.npy` and `depo_info_0.npy`
pair.

## 6. Generate and merge multiple line deposits

The repository helper renders
`scaling/pdhd/line-depo-template.sh.in` once per configuration, runs each
rendered Bash script, validates its one-event archive, and merges the results.
It does not use Snakemake or `spng/test/spng-ssss` at runtime. The default grid
contains 42 configurations. To produce the first 32:

```bash
test ! -e /work/generated-depos.npz
test ! -e /work/depo-generation.json
test ! -e /work/line-depos

python "$PROJECT_DIR/scaling/pdhd/generate_line_depos.py" \
  --events 32 \
  --output /work/generated-depos.npz \
  --metadata /work/depo-generation.json \
  --workdir /work/line-depos \
  --template "$PROJECT_DIR/scaling/pdhd/line-depo-template.sh.in"
```

The three output paths must be fresh. The helper deliberately refuses to
overwrite an existing archive, metadata file, or work directory.

Inspect the result:

```bash
ls -lh /work/generated-depos.npz /work/depo-generation.json
cat /work/depo-generation.json
find /work/line-depos -name wcpy.log -print
find /work/line-depos/pdhd/line/depo -name data.npz | wc -l
```

For `--events 32`, the final command should report `32`. The merged archive is
`/work/generated-depos.npz`, which maps to
`$LINE_DEPO_OUTPUT/generated-depos.npz` on the host.

The default parameter grid is equivalent to:

```bash
--detector pdhd \
--offset '+1*m,0*m,0*m' \
--angle-coords wire-plane \
--planes 0,1,2 \
--theta-xz-deg 0,1,3,5,10,20,30,45,60,75,80,82,84,89 \
--theta-y-deg 90
```

All values may be overridden. For example, this creates six configurations
from two planes and three paired angles:

```bash
python "$PROJECT_DIR/scaling/pdhd/generate_line_depos.py" \
  --planes 0,2 \
  --theta-xz-deg 0,15,30 \
  --theta-y-deg 90 \
  --output /work/custom-depos.npz \
  --metadata /work/custom-depos.json \
  --workdir /work/custom-line-depos \
  --template "$PROJECT_DIR/scaling/pdhd/line-depo-template.sh.in"
```

One `--theta-y-deg` value is broadcast across all XZ angles. Alternatively,
provide the same number of Y and XZ values to pair them positionally.

Use `python .../generate_line_depos.py --help` for the full CLI. A custom file
passed with `--template` may use these shell-quoted placeholders:

```text
{wcpy} {offset} {detector} {plane} {angle_coords}
{theta_xz} {theta_y} {output_depos} {output_meta}
```

The default template is
`scaling/pdhd/line-depo-template.sh.in`. Every rendered `generate.sh` is
retained beside its `wcpy.log`, `data.npz`, and `meta.json` for provenance.
In a custom template, write literal braces as `{{` and `}}` because Python
formatting reserves single braces for placeholders.

## 7. Run the complete workflow with one Apptainer command

Instead of entering an interactive shell and running sections 3–6 manually,
the following single `apptainer exec` invocation creates the temporary venv,
installs WireCell Python, generates 32 distinct line deposits, merges them,
and verifies the number of direct `wcpy` outputs.

Run it on the host after completing section 1. The bound output directory must
be empty of outputs from a previous attempt.

```bash
apptainer exec \
  --bind "$PROJECT_DIR/wire-cell-data:/opt/wire-cell-data:ro" \
  --bind "$PROJECT_DIR:/project:ro" \
  --bind "$LINE_DEPO_OUTPUT:/work" \
  --nv \
  --pwd /work \
  "$IMAGE" \
  /usr/local/bin/wirecell-entrypoint bash -lc '
    set -euo pipefail

    for path in \
      /work/generated-depos.npz \
      /work/depo-generation.json \
      /work/line-depos
    do
      if [[ -e "$path" ]]; then
        echo "Refusing existing output: $path" >&2
        exit 2
      fi
    done

    /opt/wirecell-view/bin/python -m venv /tmp/my-venv
    source /tmp/my-venv/bin/activate
    pip install uv
    ls -lht
    export UV_CACHE_DIR=/tmp/uv-cache

    uv pip install --only-binary=gojsonnet \
      "git+https://github.com/WireCell/wire-cell-python.git"

    export WIRECELL_PATH=/opt/wirecell-view/share/wirecell:/opt/wire-cell-toolkit/cfg:/opt/wire-cell-toolkit/spng/cfg:/opt/wire-cell-data
    export OMP_NUM_THREADS=1
    export MKL_NUM_THREADS=1
    export OPENBLAS_NUM_THREADS=1

    command -v wcpy
    wcpy --help >/dev/null

    python /project/scaling/pdhd/generate_line_depos.py \
      --events 32 \
      --output /work/generated-depos.npz \
      --metadata /work/depo-generation.json \
      --workdir /work/line-depos \
      --template /project/scaling/pdhd/line-depo-template.sh.in

    test -s /work/generated-depos.npz
    test -s /work/depo-generation.json
    count=$(find /work/line-depos/pdhd/line/depo -name data.npz | wc -l)
    [[ "$count" -eq 32 ]] || {
      echo "Expected 32 line-deposit archives, found $count" >&2
      exit 2
    }
    echo "PASS: generated and merged $count distinct PDHD line deposits"
  ' > >(tee "$LINE_DEPO_OUTPUT/interactive-generation.log") 2>&1
```

Success ends with:

```text
PASS: generated and merged 32 distinct PDHD line deposits
```

The host output directory will contain:

```text
generated-depos.npz
depo-generation.json
interactive-generation.log
line-depos/pdhd/line/depo/.../generate.sh
line-depos/pdhd/line/depo/.../wcpy.log
line-depos/pdhd/line/depo/.../data.npz
line-depos/pdhd/line/depo/.../meta.json
```

The command installs WireCell Python into the temporary venv. This avoids
`uv tool` isolation and prevents `gojsonnet` from being built from source. The
temporary environment is not part of the retained test artifacts; only
`/work` outputs are required after the command exits.

## 8. Leave the interactive container

```bash
deactivate
exit
```

On the host, retain at least:

```text
pdhd-line-depos-interactive/generated-depos.npz
pdhd-line-depos-interactive/depo-generation.json
pdhd-line-depos-interactive/line-depos/pdhd/line/depo/.../generate.sh
pdhd-line-depos-interactive/line-depos/pdhd/line/depo/.../wcpy.log
pdhd-line-depos-interactive/line-depos/pdhd/line/depo/.../data.npz
pdhd-line-depos-interactive/line-depos/pdhd/line/depo/.../meta.json
```

The deposits are deterministic line configurations for controlled testing.
Distinct event IDs do not imply independent simulated physics events.
