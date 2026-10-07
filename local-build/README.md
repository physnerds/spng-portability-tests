# Wire-Cell Toolkit: native Perlmutter build

## Perlmutter machine specs and software versions

GPU nodes have one 64-core AMD EPYC 7763 CPU, 256 GB RAM, and four NVIDIA
A100 GPUs (40 or 80 GB each). CPU nodes have two 64-core EPYC 7763 CPUs and
512 GB RAM. See [NERSC machine specifications](https://docs.nersc.gov/systems/perlmutter/architecture/).
This build targets A100 (`sm_80`).

| Software | Version used |
| --- | --- |
| Wire-Cell Toolkit | `spng`, revision `a8d61722` |
| GCC | 13.2.1 (`gcc-native/13.2`) |
| LLVM | 20.1.3 available; this build uses GCC |
| PyTorch | 2.8.0+cu129, C++11 ABI enabled |
| CUDA toolkit / NVCC | 12.9 / 12.9.41 |
| Python | 3.12.11 |
| CMake | 3.30.2 |
| Spack | 1.0.4 |
| NVTX | CUDA-provided, header-only NVTX3 |

## Installation

Follow [Installation.md](Installation.md) for prerequisites, modules,
dependencies, and CMake build instructions. The completed installation is
in `local-build/install`, with SPNG and NVTX enabled.

## Running Wire-cell-toolkit [spng branch] locally in Perlmutter

1. Request a GPU allocation from a login shell. Replace `YOUR_PROJECT_g`
   with your NERSC GPU account. Skip this step if already allocated:

   ```bash
   salloc --account=YOUR_PROJECT_g --constraint=gpu --qos=interactive \
       --nodes=1 --gpus=4 --time=00:30:00
   ```

   GPU resources must also be requested by `srun`, as described in
   [NERSC interactive-job instructions](https://docs.nersc.gov/jobs/interactive/).

2. Activate the native installation:

   ```bash
   cd /global/homes/a/abashyal/spng-portability-tests
   source local-build/activate.sh
   ```

   `activate.sh` loads the modules and sets executable, library, and configuration
   paths. `WIRECELL_PATH` includes `wire-cell-data`, Toolkit `cfg`, and `spng/cfg`.
   If your workspace lacks `wire-cell-data`, it uses
   `/global/homes/a/abashyal/spng-portability-tests/wire-cell-data`.
   To select another existing data checkout, set `WCT_DATA_DIR` before sourcing.

3. Select the existing ADC input and TorchScript model, and create an output directory:

   ```bash
   WCT_INPUT=/global/homes/a/abashyal/spng-portability-tests/infiles/drifted-cosmics_10-frame.npz
   WCT_MODEL=/global/homes/a/abashyal/spng-portability-tests/infiles/legacy_roiuniter_090326.ts
   test -r "$WCT_INPUT" && test -r "$WCT_MODEL" && test -d "$WCT_DATA_DIR"
   mkdir -p "$SCRATCH/wirecell-spng"
   cd "$SCRATCH/wirecell-spng"
   ```

4. Run `adc-to-spng.jsonnet` on one GPU:
### Without srun
```bash
wire-cell -l stdout -A "input=$WCT_INPUT" -A "output=$PWD/spng.npz" \
 -A "model_file=$WCT_MODEL" -A device=gpu \
spng/adc-to-spng.jsonnet
```
   ```bash
srun --ntasks=1 --cpus-per-task=8 --gpus-per-task=1 \ 
--cpu-bind=cores wire-cell -l \ 
stdout -A "input=$WCT_INPUT" -A "output=$PWD/spng.npz" \ 
-A "model_file=$WCT_MODEL" -A device=gpu spng/adc-to-spng.jsonnet

   ```

   Both `input` and `model_file` are required. Use ADC frames and a model
   compatible with the selected detector and TPC.

5. Inspect the results:

   ```bash
   tail -n 30 adc-to-spng.log
   ls -lh spng.npz
   ```

The build and shared-library checks passed. This workflow and GPU inference
have not yet been executed here; the commands above are for user verification.
