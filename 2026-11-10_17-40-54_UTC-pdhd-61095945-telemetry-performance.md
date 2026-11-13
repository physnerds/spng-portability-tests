# PDHD one-node telemetry performance — job 61095945

Recorded 2026-11-10_17-40-54_UTC. Retrospective analysis of user-run evidence; no tests or workloads launched by the agent.

## Study, completion and hardware

All nine configurations completed **one warmup and two measured rounds each**: 27 validated rounds total, 18 measured rounds, four complete events per round with four APAs/event. There are 72 measured event executions, not 72 independent physics events. The manifest explicitly records repeated input copies. No failed.json or campaign lock remains in the evidence. All 42 measured process results have zero return codes and validated outputs; UUIDs and physical CPU cores are disjoint within each round.

| Property | Recorded value |
| --- | --- |
| Slurm job / node | 61095945 / nid008652 |
| GPU model | NVIDIA A100-SXM4-80GB |
| GPUs assigned to outer compute step | 4 |
| Outer compute-step CPU affinity | 32 logical CPUs representing 16 physical cores |
| Per-case active resources | P=1,2,4 GPUs; 4P physical cores; one process/GPU |
| TBB threads / process | 1,2,4; Torch=1, OMP/MKL/OpenBLAS=1 |
| Launcher / runtime | local controllers within Slurm compute step / podman-hpc |
| Image | `docker.io/abashyal/wirecell-spng:cuda80` |
| Wire-Cell / Torch / CUDA | spng-0.35.0-1147-ga8d61722 / 2.5.0a0+872d972e41.nv24.08 / 12.6 |
| Dataset | Four repeated complete events; IDs 1–4; four APAs/event |
| Warmups / measured repeats | 1 / 2 per case |
| Requested host sampling interval | 500 ms |
| Model SHA256 | `4809002775f7f8d64e4e9a512066d89c58b50c488ab7a357824e3eb3eb356c27` |
| Evidence root | `/pscratch/sd/a/abashyal/pdhd-telemetry-local-61095945-20261110T171738Z` |

Case resource counts describe active assigned resources, not measured occupancy. All cases retain the outer four-GPU/16-core compute-step reservation; smaller cases do not release unused allocated resources. With the local launcher there is no per-case Slurm CPU request; the workload uses one logical CPU per physical core within its process mask. Timing/throughput means exclude warmups.

## Throughput and scaling

Rates are complete events/minute. SD is sample SD across two measured rounds. Speedup and efficiency use the same-TBB one-process baseline.

| Case | Processes | GPUs | Cores/process | Total physical cores | TBB/process | Rate ± SD | E2E rate | Process speedup | Scaling efficiency | E2E speedup | CV |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| n1-p1-t1 | 1 | 1 | 4 | 4 | 1 | 10.679 ± 0.001 | 6.75 | 1.000× | 100.0% | 1.000× | 0.01% |
| n1-p1-t2 | 1 | 1 | 4 | 4 | 2 | 16.013 ± 0.114 | 8.52 | 1.000× | 100.0% | 1.000× | 0.71% |
| n1-p1-t4 | 1 | 1 | 4 | 4 | 4 | 19.035 ± 0.095 | 9.42 | 1.000× | 100.0% | 1.000× | 0.50% |
| n1-p2-t1 | 2 | 2 | 4 | 8 | 1 | 15.872 ± 0.077 | 8.78 | 1.486× | 74.3% | 1.301× | 0.48% |
| n1-p2-t2 | 2 | 2 | 4 | 8 | 2 | 21.326 ± 0.161 | 10.29 | 1.332× | 66.6% | 1.208× | 0.75% |
| n1-p2-t4 | 2 | 2 | 4 | 8 | 4 | 22.384 ± 0.117 | 10.61 | 1.176× | 58.8% | 1.126× | 0.52% |
| n1-p4-t1 | 4 | 4 | 4 | 16 | 1 | 20.319 ± 0.072 | 9.74 | 1.903× | 47.6% | 1.442× | 0.35% |
| n1-p4-t2 | 4 | 4 | 4 | 16 | 2 | 22.911 ± 0.031 | 10.20 | 1.431× | 35.8% | 1.197× | 0.13% |
| n1-p4-t4 | 4 | 4 | 4 | 16 | 4 | 24.448 ± 0.443 | 10.38 | 1.284× | 32.1% | 1.102× | 1.81% |

## GPU telemetry and CPU utilization

| Case | GPUs | Assigned cores | GPU mean busy % | GPU peak busy % | GPU peak MiB/device | Mean W/active GPU | Peak W/device | CPU capacity % | Busy-core equivalents | CPU seconds/round | Peak RSS/process GiB | Measured samples |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| n1-p1-t1 | 1 | 4 | 15.9 | 90.0 | 6719.0 | 129.9 | 346.6 | 24.5 | 0.98 | 21.97 | 1.84 | 90 |
| n1-p1-t2 | 1 | 4 | 25.0 | 92.0 | 7049.0 | 152.3 | 348.6 | 37.2 | 1.48 | 22.18 | 2.18 | 60 |
| n1-p1-t4 | 1 | 4 | 27.0 | 99.0 | 7671.0 | 169.3 | 358.4 | 45.9 | 1.82 | 22.99 | 2.75 | 51 |
| n1-p2-t1 | 2 | 8 | 13.3 | 97.0 | 6719.0 | 116.1 | 353.2 | 23.7 | 1.88 | 28.45 | 1.86 | 120 |
| n1-p2-t2 | 2 | 8 | 14.7 | 97.0 | 7075.0 | 132.1 | 339.8 | 32.7 | 2.57 | 28.92 | 2.13 | 90 |
| n1-p2-t4 | 2 | 8 | 17.9 | 99.0 | 7669.0 | 133.4 | 346.5 | 37.0 | 2.88 | 30.91 | 2.58 | 84 |
| n1-p4-t1 | 4 | 16 | 8.1 | 97.0 | 6719.0 | 122.0 | 360.9 | 22.6 | 3.55 | 41.99 | 1.85 | 185 |
| n1-p4-t2 | 4 | 16 | 9.2 | 99.0 | 7143.0 | 114.1 | 340.2 | 27.2 | 4.23 | 44.32 | 2.14 | 162 |
| n1-p4-t4 | 4 | 16 | 8.9 | 96.0 | 7821.0 | 117.8 | 352.8 | 31.0 | 4.84 | 47.51 | 2.51 | 154 |

GPU readings are device-wide, matched by UUID to each process execution window. Mean busy and mean power first average samples within a process/round, then equally average over measured processes/rounds. Peaks are maxima over all selected samples on any active GPU, not sums across devices. Device memory includes framework allocations/cache and is not model-only memory. nvidia-smi busy percent measures GPU activity, not achieved FLOPS, kernel occupancy, useful-work efficiency or scaling efficiency. Power includes device idle/static consumption; no job energy or energy-efficiency claim is made.

CPU capacity percent is the equal average of each process's `100 × CPU_seconds / (4 × process_elapsed_seconds)`; CPU seconds are wait4 user+system time. Busy-core equivalents use total process CPU seconds divided by the common coordinator processing window, averaged across rounds. These two denominators differ. Coordinator, container supervisor, separate validation, final assembly, and host sampler CPU costs are excluded from these process CPU metrics. Peak RSS is the largest process high-water mark across the measured rounds, not total node memory.

### Field guide

All values in this table exclude warmups. A process window is the recorded interval from a Wire-Cell process starting until its completion is observed. GPU readings are selected by device UUID and sample timestamp within that interval.

| Field | Meaning and calculation | How to interpret it |
| --- | --- | --- |
| **Case** | Configuration name: `n1-p4-t2` means one node, four processes, and a TBB limit of two threads per process. | This case uses one GPU and four assigned physical CPU cores per process. TBB thread limit and assigned core count are separate settings. |
| **GPUs** | Number of active GPUs assigned to the case: 1, 2, or 4. Each process has its own GPU UUID. | The outer allocation retains four GPUs throughout; this column counts GPUs assigned to workload processes, not GPU busy time or resources released back to Slurm. |
| **Assigned cores** | Total physical CPU cores assigned to Wire-Cell processes: `4 × process count`. | These are physical cores, not SMT logical CPUs or measured busy cores. For example, P=4 reserves 16 cores even when TBB=1/process. |
| **GPU mean busy %** | From `nvidia-smi utilization.gpu`: arithmetic mean of selected samples for each process/round, then an equal mean across all measured process/round windows. | Shows average reported GPU activity during execution. For P=4,T=4, 8.9% is the average per active GPU, not a sum across four GPUs. It does not measure achieved FLOPS or kernel occupancy; brief bursts can coexist with a low mean. |
| **GPU peak busy %** | Largest selected `utilization.gpu` reading on any active GPU across both measured rounds. | A value of 99% means at least one sampled device activity window was nearly fully busy. It does not mean all GPUs were simultaneously 99% busy or that the run sustained that level. |
| **GPU peak MiB/device** | Largest selected `nvidia-smi memory.used` reading on any active GPU. One MiB is 1,048,576 bytes. | Device memory usage includes framework allocations and caching. It is not GPU memory capacity, model size alone, memory-bandwidth utilization, or the sum across GPUs. The largest value here, 7,821 MiB, is about 7.64 GiB on one device. |
| **Mean W/active GPU** | Arithmetic mean of selected `nvidia-smi power.draw` samples per process/round, followed by an equal mean across measured windows. Unit: watts per active GPU. | Includes device static/idle power as well as workload power. For P=4,T=4, 117.8 W is a per-device average; it is not total node power or an energy measurement. |
| **Peak W/device** | Largest selected power reading on any active GPU across both measured rounds. | A sampled per-device peak, not a simultaneous sum of device peaks or a guaranteed maximum between samples. It excludes CPU, host memory, storage and other node power. |
| **CPU capacity %** | For each process, `100 × (user CPU seconds + system CPU seconds) / (4 assigned cores × process elapsed seconds)`, then equal mean across measured processes/rounds. | Fraction of assigned process CPU capacity occupied. Roughly, 25% corresponds to one busy-core equivalent per four-core process; 100% would correspond to four. It does not establish useful-work efficiency, whole-node CPU utilization, or scaling efficiency. |
| **Busy-core equivalents** | For each round, sum CPU seconds across its Wire-Cell processes and divide by the common processing-window seconds; then average the two round values. | Aggregate CPU activity expressed as equivalent continuously busy cores. P=4,T=4 reports 4.84 busy-core equivalents across 16 assigned cores. This is not an observed thread count or a claim that exactly 4.84 cores were simultaneously active. |
| **CPU seconds/round** | Sum user+system CPU time from `wait4` over all Wire-Cell processes in a round, then average over the two measured rounds. | CPU time accumulates across concurrently executing threads and processes, so it can exceed wall time. For P=4,T=4, 47.51 CPU seconds accumulate during a mean processing window of about 9.82 wall seconds. Separate coordinator, validation and assembly CPU time is excluded. |
| **Peak RSS/process GiB** | Maximum recorded process resident-set-size high-water mark across measured processes and rounds. Recorded KiB is divided by 1,048,576 to obtain GiB; one GiB is 1,073,741,824 bytes. | Peak host RAM resident for one process, as reported by OS accounting. It is not GPU memory, virtual address space, total memory across processes, or total node memory. For P=4,T=4, 2.51 GiB is the largest individual process peak. |
| **Measured samples** | Total number of GPU readings selected into all measured process windows for this case. Warmup, idle-device and out-of-window readings are excluded. | P=4,T=4 has 154 readings across eight process windows: four processes × two rounds. Multiple GPU readings can share a query timestamp, so this is not 154 distinct sampling times. More readings improve coverage but do not constitute independent benchmark repeats. |

**Why the two CPU utilization columns do not match exactly:** `CPU capacity %` uses each process's own elapsed time and averages per-process percentages. `Busy-core equivalents` uses the longer common coordinator processing window and sums CPU time across processes. Therefore dividing busy-core equivalents by assigned cores gives a related estimate, but need not reproduce the CPU capacity percentage. Both describe recorded CPU activity; neither establishes that all recorded activity was useful computation.

## Timing, memory and resource productivity

Times are mean seconds per round. Productivity units are events/minute per assigned GPU or core.

| Case | Processing s | Step through validation s | Assembly s | Finalized E2E s | Other step s | Processing share | Rate/GPU | Rate/assigned core | Mean sum process peak RSS GiB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| n1-p1-t1 | 22.47 | 31.98 | 3.57 | 35.55 | 9.51 | 63.2% | 10.68 | 2.67 | 1.84 |
| n1-p1-t2 | 14.99 | 24.59 | 3.57 | 28.17 | 9.60 | 53.2% | 16.01 | 4.00 | 2.15 |
| n1-p1-t4 | 12.61 | 21.93 | 3.55 | 25.49 | 9.33 | 49.5% | 19.03 | 4.76 | 2.73 |
| n1-p2-t1 | 15.12 | 23.78 | 3.55 | 27.33 | 8.66 | 55.3% | 7.94 | 1.98 | 3.69 |
| n1-p2-t2 | 11.25 | 19.78 | 3.54 | 23.32 | 8.53 | 48.3% | 10.66 | 2.67 | 4.25 |
| n1-p2-t4 | 10.72 | 19.05 | 3.57 | 22.63 | 8.33 | 47.4% | 11.19 | 2.80 | 5.10 |
| n1-p4-t1 | 11.81 | 21.10 | 3.55 | 24.66 | 9.29 | 47.9% | 5.08 | 1.27 | 7.28 |
| n1-p4-t2 | 10.48 | 20.00 | 3.55 | 23.55 | 9.52 | 44.5% | 5.73 | 1.43 | 8.28 |
| n1-p4-t4 | 9.82 | 19.56 | 3.58 | 23.14 | 9.74 | 42.5% | 6.11 | 1.53 | 9.58 |

Processing window runs from coordinator barrier release to the last wc-finished marker; it includes process startup, execution, output writing inside the process and polling. Step time also includes launcher/container readiness and separate output validation through controller exit. Finalized E2E adds final event assembly. Other step time = step − processing, combining pre-barrier and post-processing costs that these summary fields do not separate. E2E excludes queue wait, initial campaign planning and warmups. Sum of process RSS peaks can overstate simultaneous process memory because high-water marks need not coincide; it also excludes other node processes.

## Telemetry coverage and variability

Raw host CSV contains **5,640 readings from four GPUs at 1,410 query timestamps** over 707.65 seconds. It includes warmups, idle GPUs, validation, and gaps between cases. Only **996 readings in 42 measured process windows** contribute to the tables. Mean query duration is 0.100 s; timestamps use query midpoints and have uncertainty of approximately half each query duration. The maximum recorded window/boundary sample gap is 0.693 s. The raw CSV reproduces the per-window sample counts and mean utilization/power to numerical precision.

| Case | Round-mean GPU busy range % | Largest window sample gap s | Measured samples |
| --- | --- | --- | --- |
| n1-p1-t1 | 4.8–26.9 | 0.582 | 90 |
| n1-p1-t2 | 21.8–28.2 | 0.559 | 60 |
| n1-p1-t4 | 21.8–32.3 | 0.550 | 51 |
| n1-p2-t1 | 9.2–17.5 | 0.626 | 120 |
| n1-p2-t2 | 13.3–16.2 | 0.572 | 90 |
| n1-p2-t4 | 17.7–18.2 | 0.569 | 84 |
| n1-p4-t1 | 8.0–8.1 | 0.693 | 185 |
| n1-p4-t2 | 8.5–9.9 | 0.645 | 162 |
| n1-p4-t4 | 7.4–10.5 | 0.662 | 154 |

The short process windows yield few GPU samples, and activity is bursty: utilization can peak near 100% while the execution-window mean stays low. The round-mean range shows substantial utilization variation for some cases even when throughput is stable. Sampling phase and nvidia-smi's internal activity window can affect short-run averages. These results do not establish a sustained GPU-saturation limit or identify a single CPU/I/O/GPU bottleneck. Device samples near process boundaries can partly represent activity outside the selected window.

## Formulas and worked example

Let N=4 events, P=process count=active GPU count, T=TBB limit/process, W_r=processing seconds and F_r=finalized seconds.

| Metric | Calculation |
| --- | --- |
| Round processing throughput | `q_r = 60 × 4 / W_r` |
| Reported mean processing rate | `R(P,T) = mean(q_r)` over two measured rounds |
| Sample SD | `sqrt(sum((q_r − R)^2)/(2−1))` |
| Coefficient of variation | `100 × SD/R` |
| E2E rate | `mean(60 × 4/F_r)` |
| Process speedup | `S(P,T) = R(P,T)/R(1,T)` |
| Scaling efficiency % | `100 × S(P,T)/P` |
| E2E speedup | `E2E(P,T)/E2E(1,T)` |
| Throughput/GPU; throughput/core | `R/P`; `R/(4P)` |
| CPU capacity % | `mean(100 × CPU_seconds_i/(4 × elapsed_i))` over measured processes |
| Busy-core equivalents | `mean(sum(CPU_seconds_i)/W_r)` over measured rounds |
| Processing share % | `mean(100 × W_r/F_r)` |
| GPU mean busy/power | Mean samples per process window, then equal mean over measured windows |
| Peak GPU utilization/memory/power | Maximum selected reading on any active GPU |

For P=4,T=1, speedup is about `20.32/10.68 = 1.903×` and efficiency `1.903/4 × 100 = 47.6%`. For P=4,T=4, `24.45/19.03 = 1.284×`, giving `32.1%`. Calculations use unrounded values; printed examples are approximate. One-process scaling efficiency is 100% by definition and does not imply saturated hardware. Total assigned CPU cores also grow with P, so this is scaling of combined CPU/GPU resources, not isolated GPU acceleration.

## Interpretation

- Highest processing throughput: P=4,T=4, **24.45 events/min**, using four active GPUs and 16 assigned physical cores. Mean GPU busy is **8.9% per active GPU**, and CPU capacity utilization is **31.0%**.
- Highest observed E2E throughput: P=2,T=4, **10.61 events/min**, compared with 10.38 for P=4,T=4. The small difference across only two rounds is not a statistically established winner.
- Largest process speedup: P=4,T=1, **1.903× / 47.6% efficiency**. Scaling weakens as T increases; P=4,T=4 gives **1.284× / 32.1%**.
- GPU mean busy ranges from **8.1% to 27.0%**, despite peaks of 90–99%. Peak sampled device memory is **7,821 MiB** (about 7.64 GiB). Peak sampled power reaches about **361 W/device**.
- Four-event runs give P=4 only one complete event per process. Startup, output work and short sampling windows therefore carry substantial weight. Low average GPU busy suggests idle/wait intervals in these windows, but does not identify their cause.
- Throughput per active GPU favors P=1,T=4 (19.03 events/min/GPU) over P=4,T=4 (6.11). This describes active-resource productivity; the enclosing allocation still reserves all four GPUs in every case, so it is not billed-cost efficiency.
- Two repeats provide little statistical coverage; SD is descriptive, not a confidence interval. No physics-equivalence, multi-node scaling, cancellation, SIGKILL recovery, energy efficiency or thread-affinity-over-time claim follows from this run.

## Comparison boundaries with job 61054772

| Property | Earlier job 61054772 | Telemetry job 61095945 |
| --- | --- | --- |
| Events/round | 32; repeated_copies=false | 4; repeated_copies=true |
| Warmups / measured repeats | 1 / 5 | 1 / 2 |
| Launcher | Slurm controller steps | Local controllers in Slurm compute step |
| Hardware | A100-SXM4-80GB, nid008656 | A100-SXM4-80GB, nid008652 |
| CPU cores/process | 4 | 4 |
| Peak processing rate | 84.45 events/min | 24.45 events/min |
| GPU telemetry | Missing | Valid host samples |

The different event count, repetition, launch mode and node prevent attributing the throughput difference to a regression or to telemetry overhead. The completed telemetry pilot verifies collection and short-workload behavior; it does not replace the 32-event performance study.

## Evidence and retained artifacts

The raw telemetry and compact campaign evidence are copied into [2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets) so this analysis does not depend solely on scratch retention:

- [host-gpu.csv](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/host-gpu.csv), [gpu-process-windows.csv](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/gpu-process-windows.csv), and [case-metrics.csv](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/case-metrics.csv).
- [Original generated telemetry table](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/telemetry-summary.md), [rounds.json](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/rounds.json), [scaling-summary.json](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/scaling-summary.json), [campaign.json](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/campaign.json), and [preflight.json](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/preflight.json).
- [Measured process results](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/measured-process-results.json), [dataset.json](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/dataset.json), frozen runner files in `suite/`, and [analysis script](2026-11-10_17-40-54_UTC-pdhd-61095945-telemetry-assets/analyze.py).
- [Failure and solution history](2026-11-10_17-40-54_UTC-pdhd-interactive-failures-and-fixes.md).
