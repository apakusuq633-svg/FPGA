# ZYNQ 12 麦：RV32 访存与流水线性能诊断、优化实施任务书（供 Codex 执行）

**版本**：V1.0（2026-10-14）  
**执行对象**：连接当前真实 FPGA/固件仓库的 Codex  
**关联目标**：方案 A——12 路 PCM、1024 点窗口、512 点 Hop、50% 重叠，长期达到每 13.1072 ms 产生一帧完整定位结果  
**本文件定位**：现有《方案 A 严格实时 50% 重叠定位任务书 V3》的**性能诊断与 RV32 访存优化专项子任务**，不是推翻 V3，也不是保证优化 CPU 后就能实现全链严格实时。

> **最重要的规则**：先读取仓库源码、复现已有测试、**用波形和计数验证** MMIO/DTCM/LSU 的真实时序；再按实测瓶颈优化。绝对不要在没有证据时将 `ready` 强行改成常高、删掉 stall、修改 `mmio_ack_q` 或宣称所有访问都是严格 2 拍。

---

## 1. 目标、现状及硬边界

### 1.1 本任务要解决的问题

1. 查明 `MMIO` 读/写的请求—接受—响应周期，以及连续访问吞吐；区分**读数据响应**、**写入副作用脉冲**和**CPU 退休**。
2. 查明 `DTCM` `lw/sw/lb/lh/sb/sh` 等访问的响应延迟及稳态吞吐；判断所谓“隔拍应答”到底源于同步 RAM、DTCM 控制器、LSU、总线仲裁，还是 CPU stall。
3. 查明五级 RISC-V 流水线因数据访存而停顿的精确周期数，是否存在可去除的保守 stall；判断是否会与数据冒险、前递、load-use、分支冲刷耦合。
4. 查明 12 麦采集读取 + 统计、DC/增益/Hann、FFT PUSH/POP 及完整 GCC-PHAT/SRP 中，哪些耗时确实来源于上述访存等待，哪些是计算、指令、循环与共享资源争用。
5. **优先做不修改 CPU RTL 的可回退软件优化**；仅在测量证明 CPU 访存协议存在明显可改进之处时，提出局部 RTL 方案，经用户批准后实施。

### 1.2 已知条件（历史信息，必须在当前 HEAD 核对）

| 条目 | 暂定已知 | 核对说明 |
|---|---|---|
| FPGA/CPU | ZYNQ-7020 目标、PL 内 RV32、40 MHz | 历史项目也曾使用 7Z010；先核对当前 Vivado part/时钟 |
| 音频输入 | 12 路 PDM、2.5 MHz PDM 时钟、64 倍 CIC、39,062.5 Hz PCM | 不修改时钟/抽取 |
| 方案 A | 每路 1024 点，Hop=512；每 524,288 个 RV32 周期必须可持续完成一个定位窗口 | 是长期吞吐要求，此外逐窗延迟单独统计 |
| 历史旧测量 | capture+stats=533,804 cycles，prepare=599,613 cycles，FFT PUSH=43,128，RUN=11,040，POP=37,032，合计 1,224,617 | 旧 XSim 合成 PCM 的五段指标，不是完整 66 对定位 |
| 历史较新报告 | 成对读取后 capture+stats ~9.46ms，五段 ~26.69ms | 与旧 commit/构建不同，当前 HEAD 重新测 |
| 阵列几何 | 三个相邻、两两垂直的面，每面 4 麦 | 四麦实际布局/坐标/间距及物理通道映射未知，不能编造 |
| 定位计算 | 12 路正向 FFT、最多 66 对 GCC-PHAT/IFFT + SRP | **完整 66 对生产实测目前不能凭历史五段报告推定** |

算术预算：

```text
Fs                 = 2500000 / 64 = 39062.5 samples/s
Window             = 1024 samples/ch = 26.2144 ms
Hop                = 512 samples/ch = 13.1072 ms
Hop_budget         = 40000000 * 0.0131072 = 524288 cycles
New_data_per_hop   = 12 * 512 = 6144 samples (若当前格式为 16-bit)
```

注意：`rdcycle` 统计两点间经过的核心时钟周期，其中包含等待、硬件忙和软件循环；**不等同于 LSU Stall 本身的耗时**。平均阶段加速也不等于完整流水化系统的稳定结果更新速率。

### 1.3 绝不能擅自更改

- PDM/CIC/Fs、12 路通道映射、1024 点 FFT、50% 重叠的定义。
- 连续音频 DAS/FIR 正常的时序、仲裁优先级和结果语义。
- RV32 ISA、CSR、异常与退休语义、自定义 SIMD/VFFT 指令编码。
- MMIO 寄存器地址及读后副作用（例如采集索引自动递增、状态清除、FIFO 弹出）、PS AXI-Lite/TCM 访问契约。
- 真实三维定位几何参数（未知）；完整定位可用明确隔离的 `TEST_GEOMETRY` 测试模式。
- 用户尚未提交的 Git 修改；不执行破坏性清理/重置/强制推送。
- **未获用户同意，不得直接修改核心握手、RAM 端口、SoC 地址译码或跨模块仲裁结构。**

---

## 2. Phase 0｜先审计：定位真实设计，不允许先写优化代码

从仓库根目录执行并保存输出：

```bash
git status --short
git rev-parse --show-toplevel
git rev-parse --short HEAD
rg --files | rg 'CLAUDE\.md|rv32_(dtcm|soc|lsu|memory_stage|core|itcm)\.v|rv32_pdm_capture\.v|fw_live(12|16)?\.c|fw_fft\.c|fw_gcc\.c|fw_mem\.h|tb_.*(soc|core|memory|capture)|check_cycle_profile\.py'
rg -n 'mmio_ack_q|mmio_.*ack|dtcm_.*ready|memory_stall|mem_stall|ready_o|req_i|load_use|flush|wb_.*valid' rtl sw tb
```

所有候选文件名来自既有工程记录，**如果当前路径不同，以 `rg` 找到的真实代码为准，不准虚构模块、行号或综合参数**。

重点审计：

1. `rtl/soc/rv32_soc.v`：MMIO/DTCM 地址选择、`mmio_ack_q`、`req/ready` 连接、外设读写脉冲、PS 访问路径。
2. `rtl/soc/rv32_dtcm.v`：RAM 推断方式、同步读/写、核端与 PS 端仲裁、`ready_o` 何时有效、是否允许背靠背请求、地址/读数据何时锁存。
3. `rtl/core/rv32_lsu.v`、`rv32_memory_stage.v`、`rv32_core.v`（如存在）：请求握手时序、MEM stage hold、stall/flush 优先级、WB 退休、重复提交保护、load-use 转发机制。
4. `rtl/array/rv32_pdm_capture.v` 及上层连线：`INDEX/DATA` 或 PACKED DATA 访问的副作用；`SEQ/FIRST/ACKSEQ/RELEASE`、Bank 保留/释放条件。
5. `sw/fw/fw_live16.c` 或当前 12 麦入口、`fw_mem.h`、FFT/GCC 代码：DTCM/scratch/BRAM 的确切数据位置，采集循环 MMIO 写索引/读数据次数，预处理加载/写回次数。
6. `CLAUDE.md`、现有测试平台、脚本、Vivado report：核对 40MHz、实际 part、资源占用和 WNS/WHS；不能用旧的 8 麦架构文档替代当前 RTL。

**交付 `audit.md`：** 给一张逐路径表：`CPU load/store -> LSU -> SoC 地址译码 -> DTCM 或 MMIO -> response -> WB`，每个阶段附`文件:行号`、组合/寄存关系、波形证据与测试名称。

特别说明：此前工程资料对 `mmio_ack_q` 与 MMIO 读写副作用有提示，但**不构成所有 MMIO 访问固定 2 拍、DTCM 固定隔拍吞吐的证明**。

**Gate 0**：能说清楚 DTCM 与 MMIO 访问的不同机制；把不确定的行为标为 `UNKNOWN`，而不是猜测。

---

## 3. Phase 1｜只加测试与计数：测出 DTCM、MMIO、CPU Stall 的独立成本

### 3.1 建立最小微基准（不改功能 RTL）

新增可单独运行的微基准程序与 testbench，名称按仓库规范确定，例如：

- `sw/bench/bench_mem_access.c`（或测试固件等价路径）
- `tb/tb_rv32_mem_perf.v`（或扩展现有 RV32 SoC TB）
- `scripts/report_rv32_mem_perf.py`（按需）

必须将以下测试作为**独立场景**运行，而不是混在同一个循环中的结果：

| 场景 | 访问内容 | 测量目标 |
|---|---|---|
| D1 | 连续顺序 `lw` 至有效 DTCM 地址 | 首笔 latency、稳态 cycles/access、load-use 开销 |
| D2 | 连续顺序 `sw` | `ready` 吞吐、每次写入恰好一次 |
| D3 | 混合 `lw/sw`、原地读改写 | 读写切换、依赖与 LSU stall |
| D4 | `lb/lbu/lh/lhu/sb/sh`、byte enable | 数据扩展和 `wstrb`，绝不因优化破坏 |
| D5 | 独立寄存器交织的 load 与立即使用 load 结果 | 将原始访存等待与 load-use 冒险分开 |
| M1 | 无副作用普通 MMIO 只读寄存器 | MMIO 纯读吞吐/延迟 |
| M2 | 无副作用普通 MMIO 可写寄存器 | 每次写恰好一次，读回一致 |
| M3 | 采集 `INDEX/DATA`、PACKED DATA、FIFO/状态侧效应（按真实存在测试） | 两拍门控有无重复/跳样/乱序 |
| A1 | 连续 DAS/FIR 运行同时执行上述访问 | 资源仲裁、最大 stall、`audio_drops` |

测试数组必须在当前链接脚本确认的有效存储区域内。核对编译器生成的反汇编，使用 `volatile` 或汇编约束与 checksum 防止访问被优化掉；保证循环控制开销有单独空循环/基线版本，**报告原始 elapsed 与扣除基线后的结果**，二者均保留。

每种访问至少跑长度 1、16、256、1024 个操作；除平均值，还要记录总读/写请求次数、实际接受次数、完成次数及意外重复次数。输入、链接地址和生成 ELF/MAP/反汇编要一并存档。

### 3.2 必须从 RTL 检测的周期事件

可以在仿真 TB 添加轻量探针，或添加 `ifdef PERF_TRACE` 下的只读计数器（仅在确实需要时），**不得改变关键时序**：

- `dtcm_req_cycles`、`dtcm_accept_count`、`dtcm_wait_cycles`、`dtcm_complete_count`。
- `mmio_req_cycles`、`mmio_accept_count`、`mmio_wait_cycles`、`mmio_complete_count`。
- `mmio_read_side_effect_count`、`mmio_write_side_effect_count`（能够识别的副作用控制脉冲）。
- `lsu_stall_cycles`，并尽量区分 `dtcm/mmio/load_use/multicycle/vector/arbiter`（以现有机制实际支持的分类为准，避免重复归因）。
- `retired_load_count`、`retired_store_count`、`total_retired_inst`、`total_cycles`（能测就测）；同时记录异常和 trap。

请求如果保持多个周期，**不能按高电平持续时长当成多笔事务**；务必定义接受/完成条件，从 RTL 明确一次事务的身份。不允许把 `wait_cycles` 与 CPU `rdcycle` 的阶段总耗时重复相加。

### 3.3 关键仿真断言

- 每条已提交 store 只写一次；MMIO side effect 按事务仅触发一次。
- 访存等候期间请求所需字段稳定（地址、写数据、字节选通、写/读方向）。
- load 的 WB 数据对应本次正确地址及字节/半字的符号扩展。
- flush/exception 后被取消的访存不得写出外设副作用；如果已有已提交或不可取消语义，以实际设计定义和架构约束为准。
- 请求握手永不丢失、响应永不误认上一笔；背靠背交替读写正常。
- PS 与 CPU 同地址访问禁止依赖未定义双端口 RAM 冲突；遵循现有 HALT/权限流程。

以波形报告 `request cycle / accept cycle / response cycle / retire cycle` 的四个事件，至少展示：DTCM lw、sw，MMIO read、write 四张简短时序表或对应 VCD 信号。

**Gate 1：** 产出 `mem_access_baseline.csv`、`stall_breakdown.csv` 与可重复运行脚本；如无法可靠分类某项 stall，应明确 `UNATTRIBUTED`，禁止推断。

---

## 4. Phase 2｜在真实 12 麦程序中分解耗时，验证是否值得改 CPU

不要只看单条 lw 的微基准。使用当前实际 12 麦固件/仿真，建立相同构建下的应用级测量：

| 计时段 | 必须拆分的部分 | 重点 |
|---|---|---|
| CAPTURE | 等待新半块、写 MMIO INDEX、读 MMIO DATA、拆包、原始统计、存入工作区 | MMIO vs DTCM vs 指令成本 |
| OVERLAP | 新 512 点 ingest、旧 512 点复用、不可变窗口发布/复制 | 不可重复读旧 512 点；避免覆盖 |
| PREPARE | DC 平均值、去 DC、定标、Hann、每通道数据排布 | DTCM load/store、乘法和重复遍历 |
| FFT | PUSH、RUN、POP 分开计 | CPU 数据搬运与硬件 FFT 运行不得混算 |
| GCC | cross spectrum、PHAT、66 对 IFFT、32 点相关提取 | 确保 66 对真实运行 |
| SRP | 点集遍历、打分、结果提交 | 未确定真几何时限 `TEST_GEOMETRY` |

记录：commit、编译宏、优化等级、profile 开关、仿真时钟、测试数据、窗 ID、启动/完成时间戳、每窗 cycles、平均/P99/最大值、`raw_drop/window_skip/audio_drop`、VFFT/共享 SIMD 占用，以及可归因的各类 stall。

**定量筛选规则**：只有在 `MMIO_wait` 或 `DTCM_wait/LSU_stall` 对整个可执行目标具有可观可复现占比，且存在不破坏协议的减周期办法时，才把 CPU/SoC RTL 优化排进实施计划。对于某个“期望省下多少周期”的结论，给出 `可省 stall × 可削减比例` 的上界，避免单靠直觉说“会快一倍”。

**Gate 2**：按照可证据化的“机会周期数”列出优化排序，标明低风险软件、局部 RTL、高风险体系结构三类。

---

## 5. Phase 3｜优先执行低风险软件优化（可以直接做，但逐项验证）

1. **采集读取**：核实已实现的 32-bit packed 采集格式，每 Hop 只读新增 12×512 PCM；消除不必要的 MMIO INDEX 复位/重复读取；保留采集控制协议。**新半块若为 16-bit PCM，每 Hop 共有 6144 样点、理论 3072 个 packed 32-bit 数据字；最终以真实硬件打包方式为准。**
2. **读取与统计融合**：在必须读取新增样点时完成解包、有效性检查与可复用统计，减少 DTCM 再读一遍；确保数值溢出与符号扩展与原版一致。
3. **滑窗 DC 均值**：允许研究“上一帧和减去离开的 512 点再加新增 512 点”的增量更新，但必须证明定点精度与边界等价；旧数据应是未加工的原始 PCM，不能复用上一窗口已经施加 Hann 系数的结果。
4. **预处理**：合并 DC、定标、Hann 中重复的全窗访问；比较 AoS/SoA 排列、临时拷贝与数组跨度，确认不会增加额外 DTCM 冲突。用反汇编分析编译器生成的 load/store，评估指针步长、循环展开、寄存器复用。
5. **FFT PUSH/POP**：只在实际证明大量时间浪费在数据搬运时优化输入输出；不要修改 VFFT 算法/指令语义；完整 66 对算法执行以后要重排优化优先级。
6. **固件中的忙等**：辨别采样等待与可避免的主动轮询；减少不必要的 MMIO 查询，但不得破坏 READY/SEQ/RELEASE 及时性及输入数据完整性。
7. **共享 SIMD**：任何用于预处理的 SIMD 优化必须同时验证连续 DAS/FIR 的优先级、无新增音频丢样，必要时保持软件路径。

每项独立提交/记账：`before cycles -> after cycles`、差值和百分比、代码 diff、逐点数值对比、64 位/溢出验证、`drops` 和回归测试。性能优化若不稳定或改变结果，应撤回该项。

**Gate 3**：清楚展示在**不动 RV32 RTL**时可以省多少；再判断是不是还需要动 CPU。

---

## 6. Phase 4｜仅在数据支持时评审/修改 RISC-V 与 SoC RTL（必须先获用户批准）

### 6.1 可评审的候选方案（不要默认全部执行）

**A. DTCM 请求与响应改良**：若证实核端控制器强制每隔一拍接受下一事务，评估在保持同步 BRAM 一拍读延迟时，是否可背靠背接受新的**互不依赖**访存；同时必须考虑单发射、原有 MEM/WB 结构及 load-use stall。只提高 RAM 端吞吐而 CPU 发不出新请求可能没有收益。

**B. LSU stall 精确化**：审计是否因为 ready/valid 逻辑和流水线保持过度保守，使 IF/ID/EX/MEM 多冻结一拍；修改需证明负载数据到 WB 与后续依赖消费时序正确，分支 flush 与异常的优先级正确。

**C. MMIO 两拍门控精简**：若 `mmio_ack_q` 造成多余空拍，评估将读请求/外设副作用脉冲/读数据响应分离，**每笔对有副作用的外设只能执行一次**。严禁“`mmio_ack_q` 删除 + `ready=1`”式粗改。若外设无法在一拍提供可靠读数据，不得为了速度违背时序。

**D. 局部块搬运/独立工作区**：如果瓶颈是 MMIO 单词交互，而非 LSU，优先比较采集硬件直接向安全 scratch RAM/FIFO 搬运新增半块、CPU 内读取 packed block、增加受控预取等方案；若需新 DMA、端口或资源互联，属于架构设计门，不在本任务自动实施。

### 6.2 每个 RTL 提案必须量化

对每个候选给：

- 当前波形/计数显示的根因，以及预期能去除的等待周期上界。
- 需要变更的信号/状态图/模块文件与行号、互联端口、时序图。
- 连续 request、load-use、store、byte-lane、load signedness、branch flush、异常、MMIO 副作用、PS 控制路径回归清单。
- 综合后 LUT/FF/BRAM/DSP 增量和 40 MHz WNS/WHS，当前器件 part 与 Vivado 版本。
- 对 12 麦 M0/M1/M2（原模式、重叠模式、66 对完整算法模式）预期影响、潜在数据污染及回滚手段。
- 若收益很低，明确建议**不改**，并说明下一项真正的瓶颈。

**强制停止点**：凡涉及 `rv32_dtcm.v`、`rv32_lsu.v`、`rv32_memory_stage.v`、`rv32_soc.v` 实际握手语义、Bank/RAM 仲裁、地址映射和外设寄存器副作用的**功能性 RTL 改动**，先向用户展示具体补丁设计和预计收益，等待批准。无需批准的活动仅限审计、测试/只读计数和安全可回退的固件优化。

**Gate 4**：用户批准后才进入 RTL 实装；未批准则提交设计评审文件，不得假装已完成。

---

## 7. Phase 5｜获批后的正确性与时序回归

### 7.1 必须通过的 CPU/LSU 回归

- 所有基础 RV32 load/store、byte/halfword signed/unsigned、写掩码、读写混合、边界地址、错位访问（按当前实现规定 trap/行为）。
- load-use、前递、WAW/RAW 相关性、branch/jump flush、MEM wait 中 branch、同步 RAM 读后被覆盖的竞争。
- 各 MMIO 外设读/写副作用恰好一次；采集 INDEX/DATA 数据序列与所有 MMIO 控制寄存器语义保持不变。
- 程序退休次数/次序与 golden 对齐；`trap_count` 无新增；PS HALT 与 PS TCM 读写窗口回归。
- FFT/SIMD/PHAT 功能对照参考结果，不得发生因为 stall 逻辑引发的多拍指令重复或丢提交。
- 连续 DAS/FIR 的样点与输出 FIFO 计数、`drops=0`；并验证 12 麦窗口 `SEQ/FIRST` 连续无遗漏。

### 7.2 重叠及 66 对测试

- 使用 2048 个以上连续样点，验证每通道 `W0=[0..1023]`、`W1=[512..1535]`、`W2=[1024..2047]`。再运行至少可覆盖多轮 Bank 环绕的持续负载。
- 仅在独立 `TEST_GEOMETRY` 模式下跑完整 66 对 GCC-PHAT/IFFT/SRP 的正确性与性能，不得用 `geometry_enabled=0` 的五段计时冒充全部算法。
- 稳态目标每 524,288 拍一个完成结果；同时报告每窗最大端到端延迟，不能只报告平均值；满负载下窗口跳过>0 或音频丢样>0 则方案 A FAIL。
- 若硬件实现未达严格实时，报告具体瓶颈与已节省周期，状态标 `INCOMPLETE` 或 `FAIL`，不要降低计算量伪造 PASS。

### 7.3 约束与结果

使用仓库现有工具链跑仿真 + 综合实现，附 `timing summary`、WNS/WHS、LUT/FF/BRAM/DSP；不要只以语法编译/RTL仿真通过替代时序验收。更换 Vivado 版本或芯片 part 时要注明，不允许拿不同条件的资源和速度直接比较。

---

## 8. Phase 6｜汇报格式、优先级和交付

请按如下文件组织输出（适应仓库已有 docs 和 build 习惯）：

```text
docs/perf_rv32_mem_audit.md          # 真实握手/模块文件:行号/波形结论
docs/perf_rv32_bottlenecks.md       # 应用阶段各类 stall、目标周期、优化优先级
docs/perf_rv32_optimization_plan.md # RTL 候选收益/风险及等待批准的方案
build/rv32_mem_perf/               # csv、trace、ELF/MAP、反汇编、仿真日志
...
```

如果仓库 `CLAUDE.md` 要求其他测量台账位置（例如 `docs/measurements.md`），以它为准并同步记录。不要将大规模波形和生成物无意提交到 Git。

### 推荐实施优先序

1. **P0：** Phase 0—2 审计/微基准/归因，先准确找瓶颈。
2. **P1：** Phase 3 固件读取、拼窗复用、预处理，优先安全可回退的性能提升。
3. **P2（条件触发）：** Phase 4 评审 LSU/DTCM/MMIO 局部 RTL；获得批准后实施。
4. **P3：** 如 CPU 通路已优化仍达不到 524,288 cycles/hop，按 V3 进入更高层的数据搬运、并行加速和资源评审。

### 每阶段汇报模板

```text
阶段：
当前 Git HEAD / 测试环境：
已检查的文件及行号：
确认的时序事实：
UNKNOWN / 待澄清：
实际改动文件与 diff 摘要：
测试命令、PASS/FAIL 与日志路径：
MMIO/DTCM 吞吐与 stall 变化：
12 麦 capture/prep/FFT/GCC/SRP 周期变化：
完整定位所需 cycles/hop（有测量才填）：
window_skip/raw_drop/audio_drop：
FPGA 资源、WNS/WHS（若涉及 RTL）：
下一步及是否需要用户批准：
```

### 验收门槛

- **L0（必须）**：报告每条路径的真实握手，分清 MMIO、DTCM、LSU stall；有微基准和波形，数值能复现。
- **L1（优先）**：完成可回退的固件优化、既有模式回归，列出真实节省的周期。
- **L2（条件）**：获批后优化 RTL，保持所有流水线、MMIO 副作用、PS 端和音频回归正确，资源/时序合规。
- **L3（方案 A 最终目标）**：在已真实执行的完整 12 麦 + 66 对 + SRP 模式下，50% 重叠长期每 524,288 个 40MHz 时钟完成一个新定位结果，窗口跳过和音频丢样均为 0。没有真实麦克风坐标时，只能宣称**合成测试几何下的功能/吞吐达标**，不能宣称实物 3D 定位精度达标。

**最后强调**：这次专项目的是判断“RISC-V 内存路径是否值得改”和在证据支持时安全提升性能，**不是让 Codex 先大改五级流水线，也不是让它跳过完整 66 对计算就宣称达到方案 A**。
