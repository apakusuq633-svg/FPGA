# Application bottlenecks — Phase 2 and Phase 3

> 下列性能表保留2026-10-14构建口径。2026-10-15当前工作区已有CPU/SRP实验修改，
> 不能把这些表中的数值或实板结论套到新RTL。当前运行见
> [三文档执行复核](pdm12_taskbook_execution_20261015.md)。

See [audit](perf_rv32_mem_audit.md), [approval proposal](perf_rv32_optimization_plan.md). Scope is 12 channels, 1024-point FFT, all 66 GCC/IFFT pairs, 32 signed correlation lags and 1024 SRP directions. Real microphone coordinates remain unknown. `FW_TEST_SRP=1` loads a separate synthetic three-plane fixture; production `geometry_enabled=0` remains unchanged. No real-array accuracy or strict overlapping throughput is claimed.

## Phase 2 / Gate 2 — measured; overlap integration INCOMPLETE

`build/pdm12_runs/mem_full_chain/` contains a four-frame real RV32/SoC run. Commands:

```powershell
wsl python3 scripts/gen_pdm12_numeric.py
wsl python3 scripts/gen_pdm12_test_srp.py
wsl python3 scripts/build_live12.py --profile --numeric66 --fused --test-srp --mem-profile
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Twelve -CycleProfile -Numeric66 -TestSrp -SnapshotFrames 4 -RunTag mem_full_chain
wsl python3 scripts/report_rv32_mem_perf.py
```

PASS: four frames, 264 GCC pairs; every FFT spectrum, PHAT spectrum, full IFFT and 32-lag ring matches independent fixed-point references; all 4096 SRP scores match reference; 16647 continuous audio samples, drops=0, max=101. A deliberate PHAT reference-bit corruption in `build/pdm12_runs/numeric_negative/negative_ref.log` rejects frame 0/pair 0/bin 6. No measurement is inferred from a disabled GCC/SRP branch.

Stage marker probes count **actual LSU wait**, not elapsed-time subtraction. All waits partition exactly into MMIO/DTCM/scratch; simultaneous load-use remains a separate overlap signal, not added twice. Marker boundary/bookkeeping cycles are included in residency but not claimed as pure arithmetic. Diagnostic full-IFFT/copy work is reported separately.

| Measured stage residency, mean cycles | Total | MMIO wait | DTCM wait | Scratch wait | LSU total |
|---|---:|---:|---:|---:|---:|
| Capture/unpack/raw statistics | 376159 | 18444 | 6378 | 12288 | 37110 |
| Fused preparation | 486660.25 | 0 | 24624 | 36864 | 61488 |
| Forward FFT PUSH | 43154.5 | 0 | 0 | 6144 | 6144 |
| Forward FFT RUN | 11064 | 0 | 0 | 0 | 0 |
| FFT POP and publication vicinity | 38719.5 | 0 | 331 | 6156 | 6487 |
| GCC input/cross/PHAT/pop-padding | 464852.5 | 0 | 35244 | 27456 | 62700 |
| 66 inverse PUSH/RUN/ring POP | 302549.5 | 0 | 34056 | 1056 | 35112 |
| SRP ring load/poll/readback | 311865.75 | 37000 | 1262 | 3136 | 41398 |
| Extra numerical audit | 1178161.5 | 0 | 68214 | 135366 | 203580 |
| Snapshot sampling wait/poll | 1048267.25 | 131031.5 | 5.75 | 0 | 131037.25 |

Useful-stage wait total=250439 cycles (~6.261 ms). This is a **generous upper bound**, not a promised saving. In particular SRP busy-poll MMIO waits overlap a 270338-cycle hardware scan: deleting those waits does not make the scan finish sooner. Capture waits are about 9.9% of capture residency; counting the whole 9.4 ms as data-bus waiting is incorrect. Statistical instructions/64-bit accumulators and preparation passes dominate the remaining cost.

### Board complete-chain measurement

The standalone A9 test loader programs/read-verifies current firmware, installs TEST-only SRP LUT, and actively consumes the audio FIFO. Actual PDM input is captured on the board; microphone wiring/quality/geometry validity is not established. A9 observed all 66 pair publications in every frame without gaps and accumulated each pair's real cycle values.

`build/rv32_mem_perf/board_profile_os/` archives the -Os baseline; `board_profile/` holds the -O2 candidate. Both are snapshots, **not overlapping windows**. Mean -Os algorithm stage sum=2027748.5 cycles / 50.6937125 ms; max=2028258. It excludes verification-only full IFFT and PHI-copy, and includes real SRP ring loading, scan wait and score readback. Complete `compute` including verification averages about 3.213 million cycles and is retained separately. Every frame has 12 FFTs, 66 GCC pairs, one SRP scan, no audio drops/traps. FIRST=[1,4162,8324,12485], which explicitly fails Hop=512 despite snapshot DROP=0.

Budget=524288 cycles. Baseline stage sum exceeds it by 1503460.5 mean cycles. Removing **all** measured useful-stage LSU waits still leaves roughly 1.777 million cycles before control overhead. Even the generous hypothetical removal of a further one IF restart cycle for every wait cannot close the deficit. Busy polling reduction is useful for CPU occupancy or servicing capture, not a substitute for algorithm throughput.

## Phase 3 / Gate 3 — safe changes and validation

1. Packed capture retained. INDEX strength-reduction candidate (`--capture-increment`) did not reduce cost: capture about 378328/378550 vs corresponding ~378k baseline; not promoted. INDEX→STATUS→DATA settling sequence remains intact.
2. `fw_prepare_fused.h`: reuse raw sum already calculated during required packed capture; retain exact mean/truncation/scaling/int16 boundary; combine scaling and Hann in one pass after peak is known. Host 260 scenes, sanitizer checks, signed extrema, DC, weak signal and silence all bit-exact. Four-frame 264-pair full FFT/GCC numerical test: prepare 597689.5→486914.25 cycles, gain 110775.25 / 18.534%; no audio drops. Opt-in `--fused`, rollback by omitting the flag. No production geometry change.
3. `fw_overlap12.h`: retain two raw 512-point halves, expose immutable const views, sum raw halves in int64; reject busy ingest and gaps before overwriting. Host 4/16/256-half streams produce 273 exact windows. Seq/FIRST unsigned wrap, signed extrema, wrong release, reset, stalled consumer pass. Working state 24792 bytes; each hop copies only the new 6144 samples. **HOST PROTOTYPE ONLY**: not integrated into continuous hardware Bank service; no measured SoC overlap cycle benefit claimed. A slow consumer explicitly fails, it does not silently skip windows. Scratch coexistence with cached spectra and processing buffers still needs a complete allocation.
4. `--hot-o2`: reversible validated candidate, four-frame board baseline vs candidate uses the same -fused/-numeric66/-test-srp/-mem-profile flags. ITCM text 4572→4720 bytes, no RAM/ISA/RTL change. Current board means: capture 375817.5→363676.5; prepare 486816.5→455543.5; GCC66 766614→699766; full algorithm stage sum 2027748.5→1917205.5, reduction 110543 / 5.4515%. Fixed-vector SoC run `mem_full_chain_o2` PASS: four frames/264 pairs/4096 SRP scores, audio15947/drop0. Each result matches the same golden reference as -Os. Default production build still uses -Os; opt-in flags make rollback explicit.

The board optimization A/B input is not replayed identical PCM; it supports cycle measurements and validates protocol completion, not bitwise numerical equivalence. Fixed four-scene SoC vectors provide the numerical A/B evidence. Report P99 as nearest-rank maximum for four frames; four frames are not statistically sufficient for a long-run tail claim.

Current strict-real-time result: **FAIL / INCOMPLETE**. Complete algorithm computation and baseline regression are measured; continuous raw windows, 256-Hop pressure test and lossless full-chain overlap remain unvalidated. No skipped windows, smaller FFT or reduced pair list are used to pass a budget gate.

The current snapshot reads both 512-point halves; a real Hop should read only the new half. Thus 1917205.5 is a measured **snapshot algorithm stage sum**, not a measured implemented overlap-Hop latency. The impossibility evidence does not depend on that extra capture work: optimized **66 GCC alone =699766 cycles**, exceeding budget by 175478. Even removing its measured 97746 LSU waits leaves ~602014 cycles before FFT/preparation/SRP. Additional hardware/parallel execution must be quantitatively evaluated.

SoC summaries for test-SRP mode include marker-stage bookkeeping in SRP residency (O2 total mean1922374); board's summed ring-load/scan/readback timers give the narrower mean1917205.5. Do not mix these scopes. Historical generic `CYCLE_SCOPE srp=0` labels in the two raw test-SRP logs are stale: explicit TEST_SRP_FRAME/PASS and 4096 score comparisons prove SRP executed. The summarizer corrects its scope and the TB label is fixed for future runs; raw logs were not edited.
