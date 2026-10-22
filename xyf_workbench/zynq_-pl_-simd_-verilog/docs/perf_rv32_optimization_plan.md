# Phase 4 RTL design review — awaiting user approval

> 2026-10-15状态更新：以下为原设计评审。当前进入工程时已存在C0/A实现、FAST_SCAN
> 和独立重叠定位模块；本轮未替用户回退或继续改写这些RTL。
> 当前CSR/访存仿真通过，SoC集成、当前构建40MHz实现及256-Hop整机验收仍未完成。
> 具体集成选项及所需批准见[当前报告](pdm12_taskbook_execution_20261015.md)。

No functional patch to `rtl/` has been applied. The explicit stop rule is [taskbook Phase 4](PDM_RV32_mem_taskbook.md): changes to actual memory handshake, Bank/RAM arbitration, address mapping or peripheral side effects require approval first. Evidence and baseline are in [audit](perf_rv32_mem_audit.md) and [bottlenecks](perf_rv32_bottlenecks.md).

## Recommendation

Prioritize a small **IF restart** experiment, while preserving the current data-memory response and one-shot MMIO effects. Do not start by deleting MEM Stall or making ready always high. It can improve CPU efficiency but cannot by itself satisfy the 524288-cycle target. Larger data movement and preprocessing/correlation acceleration remain necessary candidates.

## C0 — CSR retirement counter correction

Measured new defect: CSR minstret126784 vs exported one-shot retirement100846; extra25938 equals held-WB wait cycles. Proposed single connection change at `rv32_core.v:324`: `.retire_i(memwb_valid & ~memory_stall & ~halt_i)`, matching the existing exported retirement pulse. Keep all other CSR writes, counter splitting and existing fault-event policy unchanged in this scoped patch; separately review architectural fault-count policy. Add direct CSR/exported-count agreement tests under wait/HALT, byte loads, trap/flush and multicycle instructions. Expected performance gain=0 cycles; this corrects measurement/CSR behavior. Estimate 0 FF/BRAM/DSP and <=2 LUT; not synthesized. No data-memory/peripheral side effects or PS address changes. This is a functional core/retirement change and **must wait for approval**, even though the patch is small.

## A — preserve a parked instruction across data wait

Measured back-to-back DTCM load/store streams take about 3 cycles/access despite one response wait. `rv32_fetch_stage.v:46` drops imem_req on memory wait; ITCM ready drops the next clock. Proposed files: `rv32_fetch_stage.v`, possibly `rv32_pipeline_control.v`/IF-ID control if an explicit parked-valid state is required; TB only first. Separate instruction-memory request/retention from permission to advance PC or consume an instruction. Hold PC and pipeline registers throughout MEM wait; retain synchronous ITCM readiness for the parked instruction. Redirect/exception invalidates the parked entry before it can execute.

Expected benefit: up to one restart bubble per eligible transaction; unrolled stream analytical ideal ~3→2 cycles/access. Application upper bound <=250439 useful-stage memory waits in the -Os diagnostic, with actual eligibility **UNKNOWN** until a counter/waveform prototype. Guaranteed gain=0 before testing. This does not shorten the required BRAM read or SRP scan. Estimated incremental storage 0–64 FF, roughly 10–80 LUT, 0 BRAM/DSP; these are design estimates, not synthesis results. Risks: PC/rdata alignment during branch/trap redirect, stale parked instruction after HALT/soft reset, incorrect flush-vs-hold priority. Keep EX/MEM and MEM/WB wait/forwarding behavior unchanged; byte masks and peripheral transaction sequence unchanged. Existing VFFT/SIMD/divider multi-cycle stalls need separate eligibility; they must not advance or duplicate the parked instruction. PS TCM writes remain HALT-protected; resuming after writes must invalidate any parked instruction.

## B — tagged/pipelined DTCM request-response

Files: `rv32_dtcm.v:89-108`, `rv32_memory_stage.v:56-74`, `rv32_core.v:834-969`, potentially SoC/scratch instances. Keep synchronous BRAM one-edge read latency. Add explicit outstanding request identity/latched address, response validity and safe forwarding; permit a new independent request when the old response is consumed. Stores retain one physical pulse per retired store. Simultaneous read-after-write must have defined READ_FIRST/bypass ordering. Do not treat current req level as multiple requests.

Upper bound: only measured ordinary DTCM/scratch waits, excluding MMIO and sampling/validation work. It is below the 250439 all-wait bound and cannot close the >1.39 million-cycle candidate deficit. Single-issue MEM/WB and IF restart may prevent the advertised RAM throughput reaching CPU. Estimated ~100–300 FF / 100–500 LUT, no mandatory BRAM/DSP increase, contingent on the chosen outstanding depth. No achieved WNS is claimed. Ready→forward→EX path can become longer; re-run 40 MHz implementation and reject if WNS/WHS<0. This is a larger-risk change than A, so do not implement it first without evidence from A.

## C — MMIO request/effect/response separation

Files: `rv32_soc.v:174-228,425,475,497,525`, MEM stage request direction output/control if needed. Carry original read/write intent independent of ready-gated write pulse. Latch transaction address and read payload; issue peripheral read effect exactly once, and store effect exactly once on defined acceptance. Preserve one-edge registered response unless each addressed peripheral's data latency is separately proven. Capture INDEX/DATA synchronous settling cannot simply lose its dummy read. No register addresses or custom instruction encodings change.

Capture MMIO waits=18444 per 1024-point/12-channel snapshot (6144 packed words × INDEX/STATUS/DATA); a new half accounts for 3072 words. Even deleting all capture MMIO wait saves <=18444 snapshot cycles / 0.4611 ms, not the entire 9.4 ms capture. SRP poll wait largely overlaps fixed hardware latency. Estimated 32–128 FF / 50–200 LUT, 0 BRAM/DSP for one outstanding transaction; combinational ready must not recreate the old critical external mux loop. Risks: repeated FIFO pop, premature/duplicate SRP index increment, phantom read pulse on waiting stores, request direction mix-up, loss of latched read payload. Every peripheral needs an exact-effect test. Low potential gain suggests keeping current registered response unless correctness cleanup and a measurable gain justify the change.

## D — architectural paths for scheme A (separate approval)

| Candidate | Analytical cycle opportunity | Resource estimate / timing risk |
|---|---|---|
| Continuous capture Bank/ring + controlled raw-half copier | Removes CPU INDEX/STATUS/DATA loops and repeated raw-half ingest. Buffer depth alone cannot fix mean compute throughput. | Additional retained raw half=12 KB (~3 RAMB36 ideal); DMA/copy port needs ownership metadata and arbitration. Rough 200–1000 LUT/100–500 FF; estimates only. New port collision/drop and CDC/PS ownership risks. |
| Fixed-point DC/peak/scale/Hann engine feeding existing VFFT | Candidate CPU prepare currently ~455k cycles; a two-pass one-sample/clock datapath would need ~24576 clocks + setup (~0.6144 ms) for 12×1024. Gain upper estimate ~430k if all dependencies/resources fit. | Mean/peak dependency requires complete immutable raw window; raw storage/ports and exact int16/rounding semantics. Rough 2–8 DSP, 1–4 BRAM beyond raw storage, 1000–4000 LUT; synthesis required. Shared FIR priority retained. |
| VFFT/GCC block transfer with zero-padding handled inside controlled transfer engine | O2 forward PUSH+POP=80212.5 cycles; 66 inverse PUSH~237602/ring POP~7330, total~325144.5. Payload=12×(512+513)+66×(513+16)=47214 words. A hypothetical one-word/clock engine needs >=47214 clocks, saving <=277930.5 (~6.9483ms) before setup/arbitration. Existing FFT points/pairs remain unchanged. | Add block descriptor, guarded BRAM port/transfer arbitration; rough 1–4 BRAM, 500–2500 LUT, 200–1000 FF, 0–4 DSP; no measured implementation. Exact 513-bin masks, 66 rings and IFFT command order matter. |
| Pipeline the existing SRP scan, keeping all66×1024 work | Current scan270338 clocks. Hypothetical one completed pair/grid contribution per clock needs >=67584+pipeline-drain clocks; opportunity about202750 clocks (~5.069ms). This is a design target, not an achieved throughput. | LUT/R/P memory ports and pair-boundary accumulation must support the pipeline. Estimate extra1–4 BRAM/2–8 DSP/1000–3000 LUT/200–800 FF depending on banking; registered stages reduce arithmetic path depth but increase routing/hold risks. No implementation before separate approval. |

Current free device capacity is 24817 LUT, 90716 FF, 55.5 BRAM tiles, 89 DSP. This is arithmetic from the actual current implementation, **not** placement feasibility. Current margins WNS +0.615 ns / WHS +0.029 ns are small, so combined additional hardware must be routed and measured. No candidate is approved or implemented, and no proposed throughput is a PASS result.

## Required regression / rollback

One isolated branch/commit per approved option; retain current bit/XSA/ELF and CSV baselines. Test all signed/unsigned byte/half/word accesses and alignment traps, dependency forwarding, branch/jump/trap flush coincident with memory wait, WAW/RAW, request field stability, exactly-once stores and MMIO effects, PS HALT/window protections and soft reset, SIMD/PHAT/VFFT multi-cycle instruction single commit. Run 12-channel audio with max<1024 and drops=0; all 66 pairs/1024 SRP scores and complete 512-Hop windows must match references. Preserve eight-lane FIR; four-lane complex acoustic configuration remains baseline. Then full 40 MHz implementation, current part/tool versions, WNS/WHS>=0. Strict acceptance still requires 256+ consecutive complete overlapping results, no raw/window/audio drop.

Phase 5 baseline regression is PASS; **approved RTL regression is NOT EXECUTED**, because no functional RTL approval/patch exists. Phase 6 delivers the audit, CSVs, numerical/performance evidence and this concrete proposal; scheme A remains FAIL/INCOMPLETE. User approval is needed only for implementing a selected functional RTL option.
