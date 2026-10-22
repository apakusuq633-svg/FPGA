# RV32 memory audit — 2026-10-14

> 2026-10-15复核：下文是2026-10-14归档基线，不是当前工作区状态。
> 本次进入工程时core退休门控、fetch保持请求、FAST_SCAN和独立overlap模块已经存在。
> 当前微基准为2 cycles/access，CSR与单次退休一致；旧实现报告不能验证这些改动。
> 当前验收与边界见[三文档执行复核](pdm12_taskbook_execution_20261015.md)。

Task: [taskbook](PDM_RV32_mem_taskbook.md). Baseline HEAD `10f6c3a2ea686d82a2418cc175c757bd4df22076` plus the recorded working-tree firmware/tests. Functional `rtl/` diff is empty. Physical device discovered by XSCT: `xc7z020`; implemented part `xc7z020clg400-1`, Vivado 2020.2, FCLK 40 MHz. Full algorithm SoC TB has a 10 ns simulation clock; its cycles are converted at 40 MHz, not a 40 MHz waveform/timing test. The independent memory TB uses a 25 ns clock; board counters confirm its measurements.

## Phase 0 / Gate 0 — PASS

| Path | Actual source | Mechanism |
|---|---|---|
| LSU | `rtl/memory/rv32_lsu.v:29-52` | Combinational alignment, byte strobes, signed/unsigned extraction. No state/ready controller in LSU. The requested `rtl/core/rv32_lsu.v` does not exist. |
| MEM request/stall | `rtl/core/rv32_memory_stage.v:56-74` | Request follows valid memory op; write is gated by ready. Stall is valid aligned memory op AND NOT ready. |
| Address selection | `rtl/soc/rv32_soc.v:153-192` | MMIO pages, ordinary 16 KB DTCM; 64 KB scratch at `0x10000..0x1ffff` uses another instance of the same DTCM controller. |
| MMIO response | `rtl/soc/rv32_soc.v:207-228` | `mmio_ack_q <= dmem_mmio & ~mmio_ack_q`; read-data register captures peripheral mux. Ready pulse completes each request. |
| DTCM response | `rtl/soc/rv32_dtcm.v:55-108` | Synchronous RAM read, READ_FIRST. `ready_q <= req_i & ~ready_q`. CPU write is already response-gated upstream; physical RAM read runs every clock. |
| Pipeline hold | `rtl/core/rv32_pipeline_control.v:46-58`; `rtl/core/rv32_core.v:921,969` | Memory wait freezes IF, IF/ID, ID/EX, EX/MEM and MEM/WB. Retirement is masked during wait; held WB data stays available for forwarding. |
| Load-use | `rtl/execute/rv32_hazard_unit.v:17-19` | Immediate consumer interlock based on ID sources vs EX load destination. Hold and flush priority must remain consistent. |
| Forwarding | `rtl/execute/rv32_forward_unit.v:21-33` | EX/MEM takes priority over MEM/WB. Removing hold may invalidate the data used by a stalled EX consumer. |
| Trap / flush | `rtl/core/rv32_core.v:268-301,844-845` | EX valid suppressed by memory wait; trap committed on response, younger EX instruction killed. |
| IF restart | `rtl/core/rv32_fetch_stage.v:46-64`; `rtl/soc/rv32_itcm.v:73-80` | Memory stall drops instruction request; ITCM ready follows previous request. On release, IF must restart the synchronous request. This helps explain 3-cycle streams; it is not a second DTCM wait. |
| PS window | `rtl/soc/rv32_ps_memif.v:54-85`; `rtl/soc/rv32_dtcm.v:72-106` | Separate RAM port, one-cycle PS request pulses, synchronous read; writes allowed only under existing HALT/reset contract. Never rely on simultaneous same-address dual-port collisions. |

MMIO read pulses and write pulses differ. `rv32_soc.v:174-175` defines read from `~dmem_write`, where write is response-gated. Consequently a waiting store can also present a peripheral read pulse on its request edge. Capture `INDEX` has no read side effect, so the measured INDEX writes remain correct. This must be considered for any generic MMIO redesign; do not infer that read pulse count always equals retired loads. SRP/XSP/steering real read pulses are gated by `~mmio_ack_q` at lines 475/497/525; capture at line 425.

### Capture ownership and packing

`rtl/array/rv32_pdm_capture.v:43-66,95-117,144,158-189,222-223`: 12 channels mean six packed words/sample; even microphone is low halfword, odd microphone high halfword. Each 512-sample half is 3072 words. DATA does **not** increment INDEX. INDEX write is followed by synchronous RAM settling; firmware deliberately reads STATUS before DATA. That read is not yet proven redundant.

CTRL=7 takes two halves then freezes snapshot capture while the raw source/DAS continue. CTRL=3 is continuous existing capture: two occupied banks cause input drops, never silent overwrite; ACKSEQ/RELEASE must match the selected published sequence. A snapshot DROP=0 is not continuous raw-data coverage. Board FIRST intervals of about 4161 samples prove the present window schedule is not Hop=512.

Firmware working regions: FFT cache `0x10000..0x1602f`, frame `0x19000..0x197ff`, correlation `0x19800..0x19fff`, scores `0x1a000..0x1afff`, second microphone frame `0x1b000..0x1b7ff`, audit PHI `0x1d000..0x1d803`. Results `0x2800..0x2bff`; stage marker is `0x2bc0`. This marker is diagnostic only. Profile flags/build manifests distinguish it from production.

## Phase 1 / Gate 1 — PASS

Commands, from the project directory:

```powershell
wsl python3 scripts/check_rv32_mem_perf.py
wsl python3 scripts/check_rv32_mem_perf.py --mmio-unrolled
& 'D:\Vivado\Vitis\2020.2\bin\xsct.bat' scripts/check_rv32_mem_board.tcl
wsl python3 scripts/report_rv32_mem_perf.py
```

Artifacts: `build/rv32_mem_perf/{manifest.json,bench_mem_access.S,bench_mem_access.elf,bench_mem_access.map,disassembly.txt,mem_access_baseline.csv,stall_breakdown.csv,transactions.csv,latency.csv,simulation.log,board.log,board_raw_cycles.csv}`. Unrolled MMIO has its own `mmio_unrolled/` directory. 76 main cases plus eight MMIO stream cases; lengths 1/16/256/1024. 28,534 main transactions, data checked independently at retirement; every store exactly one physical write pulse; no faults, no unstable waiting request, no reorder. Main audio: 156 inputs/outputs, drops=0, max processing=101 cycles. Ordinary MMIO test register is GPIO/LED; capture DATA is a prepared read-only bank fixture, and INDEX/DATA tests check the actual module data path. This fixture is not a continuous capture acceptance test.

All 76 board `rdcycle` values equal simulation exactly. Board microbench initializes/read-verifies all ITCM words and runs actual packed capture registers. The microbench stops PDM **after** measuring, before slow JTAG result retrieval can fill the output FIFO; this is an endpoint of a bounded test, not a production optimization or long-run audio test. The first exploratory board test overflowed the undrained FIFO and is retained as `board_fifo_overflow_exploratory.log`; its old PASS marker was incomplete. Current runner fails if audio DROP is nonzero.

| 1024 operations | Measured loop elapsed | LSU wait | Load-use overlap | Steady meaning |
|---|---:|---:|---:|---|
| DTCM `lw` loop | 6154 | 1024 | 0 | Includes pointer/branch loop overhead |
| DTCM load + dependent add | 8194 | 1024 | 1022 | Dependency adds about one cycle/iteration |
| DTCM load + independent add | 7170 | 1024 | 0 | Same number of instructions as dependent case |
| MMIO read loop | 6146 | 1024 | 0 | One wait per transaction |
| MMIO write loop | 6146 | 1024 | 0 | Exactly 1024 physical write pulses |
| Capture DATA loop | 6146 | 1024 | 0 | No auto increment |
| DTCM unrolled `lw/sw` | 3072 | 1024 | 0 | About 3 cycles/access; two pointer-adjust instructions at midpoint |
| MMIO unrolled read/write | 3070 | 1024 | 0 | Same ~3-cycle steady stream; no pointer adjustment |

Empty-loop elapsed=4110; raw `rdcycle` adds the measured timestamp boundary (e.g. 6157 vs 6154). Both elapsed and empty-loop subtraction are retained. Subtraction is not a proof of a 2-cycle steady CPU stream. Unrolled tests explicitly have no corresponding empty-loop subtraction.

### Four transaction events

Each row is a real example in `transactions.csv`; acceptance of a read means the first synchronous sampling edge, while acceptance of a store is its actual write pulse. The bus has no separate accept wire.

| Kind | Request | Accept | Response | Retire |
|---|---:|---:|---:|---:|
| DTCM `lw` | 5304 | 5304 | 5305 | 5306 |
| DTCM `sw` | 13176 | 13177 | 13177 | 13178 |
| MMIO read | 102067 | 102067 | 102068 | 102069 |
| MMIO write | 109916 | 109917 | 109917 | 109918 |

Response latency is **one edge interval**, or **two occupied MEM cycles** including request and response. These definitions are kept separate from continuous instruction throughput. Unattributed opportunities: exact application-wide IF restart bubbles not yet isolated from simultaneous vector/divider/branch stalls; no claimed guaranteed CPU savings from those overlaps.

### Additional defect: CSR instruction-retirement count

`rv32_core.v:324` feeds CSR with `memwb_valid`, while exported retirement at line 969 also masks memory wait/HALT. `rv32_csr.v:58-61` increments minstret on every such input. New test-only monitor measures minstret=126784, exported retire=100846, held-WB events=25938; the entire difference equals held WB during memory waits. No duplicate architectural store/load was observed; it is the **CSR counter** that overcounts. `rdcycle` uses mcycle and is unaffected. All performance retirement figures use exported one-shot retirement, not minstret. Functional fix requires approval; see proposal C0. Existing seven regressions passing does not clear this newly detected defect.

## Implementation and board provenance

Current unmodified RTL rebuilt using `scripts/run_zynq_flow.tcl` with `ZYNQ_PROJ_DIR=build/rv32_mem_perf/zynq`, `ZYNQ_OUTPUT_DIR=build/rv32_mem_perf/implementation`, `DAS_ACTIVE_CHANNELS=12`.
FLOW_PASS; 40 MHz WNS=+0.615 ns, WHS=+0.029 ns, TNS/THS=0. LUT=28383, FF=15684, BRAM=84.5/140, DSP=131/220. XSA includes matching bitstream and `ps7_init.tcl`, extracted under `build/rv32_mem_perf/hw/`. No functional RTL patch was applied. These figures replace neither old build-specific reports nor measurements for an unimplemented proposed RTL optimization.
