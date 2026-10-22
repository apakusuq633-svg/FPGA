# ZYNQ 12 麦方案 A：严格实时 50% 重叠声源定位——Codex 工程实施任务书 V3

> **交付对象**：在当前真实仓库中工作的 Codex / Codex CLI。  
> **目标**：12 路 PCM、1024 点分析窗、512 点 Hop，每经过一个 Hop 可持续完成一个完整定位结果；不能靠长期跳过候选窗口“实现”方案 A。  
> **状态**：待审计、待实施。以下文件路径和硬件行为来自历史工程记录，不代表已在当前 HEAD 重新核对。  
> **修改原则**：先建立正确可复现的端到端性能与数据连续性证据，再按瓶颈优化；高风险 RTL/存储架构更改必须先提交方案等待用户批准。  
> **配套背景**：本文件是原《50% 重叠分帧 Codex 分阶段执行方案 V2》的**方案 A / 严格实时扩展版**。如与 V2 的“允许跳窗”策略冲突，以本文件的严格实时验收口径为准；可把跳窗作为调试/安全降级模式，但**不能当作方案 A 验收通过**。

---

## 0. 给 Codex 的最高优先级命令

请在当前实际工程中**动手实施**方案 A，不要只输出建议。先运行 Phase 0 的只读审计与基线测试，确认现有 12 麦路径。随后优先实现/验证 50% 重叠的正确数据流，接着打开可测量的完整 66 对 GCC-PHAT / IFFT + SRP 基准，建立真正的全链周期表，并从最大瓶颈开始逐项优化。每一项安全、可回退的固件或单元测试改动可以直接执行；凡需重构采集 Bank、总线、RAM 端口、新增 DMA/FFT 并行阵列、改变 RV32 指令编码或可能破坏时序的架构变更，必须先停下，报告几种选项与证据，等待确认再改。

**不允许**为了通过实时测试而降低定位工作量、偷偷减少 66 对、关闭 SRP、缩小 FFT 点数、静默丢帧、以模拟的采集时钟代替真实时钟，或者把 `geometry_enabled=0` 时没有执行的算法段当成已完成。任何功能未运行都必须明确标注 `NOT EXECUTED`。若严格实时尚不可达，应如实给出 `FAIL/BLOCKED` 及所需进一步优化，不得虚报 PASS。

---

## 1. 已知输入、边界与需要证实的事实

### 1.1 用户已确认的硬件/阵列信息

| 项目 | 当前已知 | 验证要求 |
|---|---|---|
| 系统 | ZYNQ-7000，目标器件 ZYNQ-7020 | 核对当前项目 Part 和真实 bitstream target；历史工程也曾使用 7010 |
| 固件执行位置 | **PL 内 RV32 RISC-V 软核**，非 PS Cortex-A9 | 检查 SoC 接线、ELF 链接地址、CPU 时钟与计数器 |
| PL/RV32 时钟 | 40 MHz | 从当前顶层、约束和 Vivado 报告核对 |
| PDM 时钟 | 2.5 MHz | 核对时钟分频参数，不作本轮频率优化 |
| CIC 抽取 | 64 | 核对实例化参数 |
| PCM 采样率 | 39,062.5 Hz / 通道 | 2.5 MHz ÷ 64 |
| 麦克风数量 | 12 路 | 核对软件通道映射及 RTL 采集通道数 |
| 空间结构 | **三个相邻、两两垂直的面，每面 4 麦** | 四麦排列、坐标、间距、通道物理映射**未知** |
| 处理 | 每路 1024 PCM 点；1024 点 FFT | 不改变长度 |
| 重叠目标 | Hop=512，50% overlap | 必须真实连续、逐点验证 |
| GCC 组合数 | 全部 12 选 2，共 66 对 | 验证生产代码的实际配对遍历，不得以理论数冒充已运行 |

### 1.2 算术预算（计算值，不是实测）

```
Fs = 2,500,000 / 64 = 39,062.5 samples/s
N = 1024 samples/channel
HOP = 512 samples/channel
Analysis_Window_Time = 1024 / 39062.5 = 26.2144 ms
Hop_Time = 512 / 39062.5 = 13.1072 ms
RV32_Cycle_Budget = 40,000,000 * 0.0131072 = 524,288 cycles/hop
Nominal_Result_Rate = 39062.5 / 512 = 76.2939453125 results/s
Per_Hop_New_PCM = 12 * 512 = 6144 16-bit samples (if format verified)
Window_PCM = 12 * 1024 = 12288 16-bit samples
Window_Raw_Storage = 24576 bytes at 16 bit (not counting buffering/workspaces)
```

**方案 A 的严格验收定义**（同时满足，不能仅满足平均处理率）：

1. 从第一个完整 1024 点窗口产生后，**每一个** 512 点 Hop 都生成一个合法的 1024 点分析窗口和一个完成的**完整定位计算结果**；稳定运行中不允许悄悄跳窗。
2. 完成结果的**长期吞吐**达到每 Hop 一结果，即相邻有效结果的最大间隔按当前设定不超过 524,288 个 40 MHz 周期（仿真计数需明确起始/结束边界）；如果必要的固定流水线启动延迟导致首帧较慢，需单独记录 warm-up。
3. 对每个窗口同时记录 `window_ready_cycle`、`result_valid_cycle`。**默认目标**是窗口完整可用后的端到端延迟 `<=524288 cycles`，如深流水能达到稳定吞吐但延迟更大，必须单独标注为“吞吐通过、逐窗延迟未通过”，**不可宣称完全满足严格目标**。
4. 全部用户要求的定位算法阶段必须真实执行：12 路必要的正向频谱、66 对互谱/PHAT/相关或与参考等效的算法、SRP 搜索和方向结果/有效性输出。算法等效替代必须有参考黄金结果与误差证明。
5. 真实采样块 `SEQ/FIRST` 连续、窗口不丢、不重、不乱；连续 DAS/FIR 音频 `drops=0`（在约定负载与测量边界内）；共享 SIMD/FFT/BRAM 仲裁安全。
6. RTL 仿真通过不是板级定位精度通过。当前没有实际麦克风坐标，不能宣称**真实空间方位角精度验收**。可使用标为 `TEST_GEOMETRY` 的**纯仿真**坐标做全链压力与正确性测试，正式运行仍按现有几何禁用安全规则执行。
7. 建议追求 **20% 预留量**，即实测关键路径/单窗资源使用理想目标 `<=419430 cycles`（约 10.486 ms）。这只是优化目标，不是可以脱离功能正确性的 PASS 依据；最终仍必须遵守 524288 硬上限与连续运行实测。

### 1.3 历史数据，不能误用

| 记录 | 段或结果 | 真实口径 |
|---|---|---|
| 较早 XSim 12 麦 | capture=533804、prepare=599613、PUSH=43128、RUN=11040、POP=37032，总计=1224617 cycles=30.615425ms | 计时 RV32 固件、合成 PCM；**未证明 66 对 IFFT/SRP 已运行** |
| 更新后截图报告 | 成对 MMIO 读取 12288→6144 字访问；capture 13.35→9.46ms；五段 30.62→26.69ms | 与旧版**不同代码/构建**；需在当前 HEAD 重跑核对 |
| 连续音频验证截图 | 两轮快照、4438 个连续音频样点，drops=0，退休异常=0 | 有限仿真长度的音频连续性，**不是**长时间完整定位 76Hz |
| 单台 VFFT 历史 | 一台变换约 7606 cycles；存在 66 台 IFFT 的估算风险 | **不能将 66×7606 认作实际全链测量**；32 点回读优化可能改变成本 |

**严禁**在几何关闭、未执行完整定位时，将五段 26.69 ms 作为完整 66 对系统的最终基线或当成实现 13.1072ms 的唯一差距。

---

## 2. 工程红线与停机条件

- 不改 PDM 时钟、CIC 抽取、PCM 采样率、FFT=1024 点，不做 STFT 逆重叠相加（本任务是**定位分析窗**而非重构声音）。
- 不允许靠修改生产的 `geometry_enabled`、伪造坐标或硬编码方向来“通过定位测试”。**测试几何须独立编译开关和明显标注**。
- 不擅自修改用户 Git 未提交修改，不执行 `git reset --hard`、`git clean -fdx`、强制推送或覆盖不相关代码。
- 不擅自改变 RV32 自定义指令编码、核心异常/流水线提交语义、PS 控制路径或 AXI 接口；如确需改变，先设计评审。
- 不改音频连续链 PDM→CIC→DAS→固定 FIR 的外部时序契约。定位算子不得不受控地占用共享 8-lane SIMD，导致 DAS/FIR 缺算或 `drops>0`。
- Bank/FIFO 增大只能解决**瞬时拥塞**，不能弥补平均计算吞吐不足；测量积压增长斜率并报告。
- 发现现有设备不具备可行的资源/时序余量时，必须交付可证伪的可行性报告并停在需要授权的架构门，不要无边界地堆硬件。
- `FW_CYCLE_PROFILE=1` 插桩版与正常版需分开记录，`rdcycle` 在核阻塞期间继续计数时属于**墙钟经过周期**，不是“CPU 有效执行指令周期”。

---

## Phase 0｜只读审计与可复现基线（必须首先执行）

### 0.1 确认代码与环境

在仓库根目录执行，保留输出及时间：

```bash
git status --short
git rev-parse --show-toplevel
git rev-parse --short HEAD
rg --files | rg 'CLAUDE\.md|fw_live(12|16)?\.c|fw_fft\.c|fw_gcc\.c|rv32_pdm_capture\.v|rv32_soc\.v|rv32_core\.v|tb_live12_soc\.v|tb_pdm_capture\.v|check_cycle_profile\.py'
```

阅读 `CLAUDE.md`、历史 issues、最新测量台账，不得用旧文档替代源代码。记录 Vivado、iverilog、Verilator、RISC-V GCC/objdump、WSL 版本；历史日志中的 `verilator --binary` 可能与 4.x 不兼容，不能照搬陈旧构建命令。

### 0.2 确认真实的 12 麦/66 对入口

重点检查（如路径不符按符号检索）：

- `sw/fw/fw_live16.c` 或当前的 12 麦固件入口，`fw_location_quality.h`、`fw_fft.c`、`fw_gcc.c`；
- `rtl/array/rv32_pdm_capture.v`、`rtl/array/rv32_pdm_array_rx.v`、`rtl/soc/rv32_soc.v`、`rtl/core/rv32_core.v`、`rtl/vec/rv32_vec_unit.v`、`rtl/acoustic/rv32_fft_bfly.v`；
- `tb/tb_pdm_capture.v`、`tb/tb_live12_soc.v`、`scripts/check_cycle_profile.py`、测试黄金参考；
- 当前 ELF、MAP、`.su`、反汇编和 `build/.../summary.json`，若产物不存在需按现有脚本生成。

必须回答并附 **文件:行号 + 可复现证据**：

1. 12 麦实际被编译启用的宏和运行路径是什么？完整 66 对 FFT/IFFT/PHAT/SRP 分别从哪里调用、有哪些几何门控、哪些缓存跳过？
2. 采集为每 Bank 512 样点吗？是单次快照还是连续滚动？READY/SEQ/FIRST/ACKSEQ/RELEASE 的握手与 DATA 自动增址是什么？
3. CPU 处于 VFFT RUN、PHAT/SRP、其他访存阻塞时，采集侧新数据在哪里暂存，是否覆盖或丢弃？连续 DAS/FIR 是否照常处理？
4. 12 路数据格式：16-bit/24-bit？每 32-bit 打包几个样点？新 512 点真正需要多少 `INDEX/DATA` MMIO 访问？
5. 现有工作区：原始 PCM、未加窗/已加窗、FFT 频谱、66 对互谱、IFFT、32 点相关环、SRP、栈、bss 分别位于 DTCM/scratch/BRAM 的什么地址范围？峰值并存容量是多少？
6. RAM 的读写端口、CPU 访存、FFT PUSH/POP、DAS/FIR 共享 SIMD、PS HALT 控制等是否可能冲突？
7. 当前 Vivado Part、LUT/FF/BRAM/DSP 利用率、WNS/WHS、最慢路径是什么？（之前曾出现 WNS 仅 +0.060ns/WHS +0.034ns 的**历史**记录，不能当现值。）

### 0.3 复现基线

按仓库真实脚本重新运行既有 `tb_pdm_capture`、`tb_live12_soc` 和 `check_cycle_profile.py`；示例：

```bash
wsl python3 scripts/check_cycle_profile.py
```

如果命令与当前环境不符，请写出实际采用的命令。将 `commit/toolchain/build flags/profile mode/test vector` 与 `summary.json`、日志、PASS/FAIL 放入 `build/overlapA_0_baseline/` 或仓库规定目录。**本阶段不修改设计。**

**Gate 0 输出**：当前代码能否产生连续半块、能否安全存储重叠窗口、完整算法是否真实启用、可行性最大障碍、最小安全修改面。完成后继续安全步骤，架构问题需保留为风险。

---

## Phase 1｜实现 50% 分帧黄金参考与不可变数据生命周期

### 1.1 独立参考生成器（不碰 RTL）

使用原始 PCM 的 `ch ∈ [0,11]`、全局样点 `n` 构造窗口：

```
B0: [0..511]        # 预热
B1: [512..1023]     -> W0: [0..1023]
B2: [1024..1535]    -> W1: [512..1535]
B3: [1536..2047]    -> W2: [1024..2047]
B4: [2048..2559]    -> W3: [1536..2559]
```

每个窗口都是 **12×1024**，并对所有通道逐点验证。建议独立输入数据：

```
pcm[ch][n] = (int16_t)(((ch*311 + n*7) % 60000) - 30000)
```

还要单独覆盖 `-32768/-1/0/1/32767`、符号扩展、交织打包顺序、SEQ/FIRST 跳号、环绕、复位、慢消费与错序。

### 1.2 数据所有权强约束

**绝不可**把会被下一次到达覆盖的 1024 点环形缓冲裸指针交给耗时 13ms 以上的 FFT 消费者。根据真实内存余量选择：

- 不可变窗口复制到工作区；或者
- N-bank/多槽引用计数固定，使用完成确认后才能回收；或者
- 可证明不会被覆盖的双阶段 RAM 与深度足够的队列。

必须给出每种工作区 `bytes`、生命周期、最大并存份数、读写仲裁、失败时如何报告**方案 A 失败**。在性能诊断阶段可以有“丢旧保新”的安全回退，但严格模式下 `window_skip_count > 0` 直接 FAIL。

### 1.3 独立软件接口（名称可替换）

```c
// 仅示意，不要求照搬：
overlap_init();
overlap_ingest_halfblock(const int16_t *block, uint32_t seq, uint32_t first);
bool overlap_acquire_window(/* immutable view or copy, window_id, first_sample */);
void overlap_release_window(/* window_id */);
overlap_get_telemetry();
```

把 MMIO Bank 事务与纯拼窗算法分开，防止测试只验证“调用成功”而不验证数据正确。

**Gate 1**：至少 4 个半块→3 个窗口，12 路全部点逐项相等；测试异常输入；此阶段禁止修改采集硬件。

---

## Phase 2｜接入真实连续半块：Bank 协议与无损读取

1. 在现有快照协议下画实际周期时序图：PDM/PCM 采样、512 点 Bank 发布、READY/SEQ/FIRST、CPU SELECT/INDEX/DATA、ACKSEQ/RELEASE、另一个 Bank 采集及 CPU 计算。
2. 必须检验在 CPU 忙超过一个 Hop 的情况下，旧数据是否被保留或覆盖；对所有权进行波形级断言。旧 Bank 只有在完整复制且版本确认后才能释放。
3. 每个新 512 点半块只从 MMIO 读取一次；上一半块从**CPU 已拥有且不被修改**的存储复用。若一个字装两路样点，理论每 Hop 新读 3072 个字，**最终以 RTL 证据为准**。
4. 验证相邻合法半块 `FIRST_next = FIRST_prev + 512`、`SEQ_next = SEQ_prev + 1`（按实际位宽/回绕）；断裂即 invalid + resync，不得拼成“看似连续”窗口。
5. 延迟 ACK、慢 CPU、Bank 竞争、半块写入未完成、复位后第一个块、SEQ 回绕分别测试。状态上至少区分 `raw_block_lost`、`candidate_window_dropped`、`audio_output_dropped`。
6. 如果现有双 Bank **不能**在每 13.1072ms 无损交付 512 点块，请先给出三个选择的可行性比较：固件更早取块+双缓冲、增加 Bank/块 FIFO、硬件自主将采集块复制到 scratch/DTCM（含仲裁）；必须附地址、安全性、资源、时序和预计吞吐，不可直接选最复杂的方案开工。
7. 禁止改变当前已验证的 PDM/CIC/DAS/FIR 数据节拍，避免为了定位刷新率干扰连续音频。

**Gate 2**：真实连续 4+ 半块对应连续 3+ 正确窗口；CPU 计算时仍能安全接收新块。无法实现时标记 `L2 BLOCKED`，提交可执行 RTL 变更方案并等批准。

---

## Phase 3｜完整 12 麦、66 对算法“性能基准模式”

> 本阶段关键：消除“几何关闭→算法被跳过→测出来很快”的误判。

### 3.1 两套模式严格隔离

- `PRODUCTION_GEOMETRY`: 真实坐标未知时继续保持当前安全禁用门控，**不得输出假方位角**。
- `TEST_GEOMETRY_ONLY`: 仅在测试宏/仿真中使用明确标注的**合成三面正交几何**和合成声源；用它运行**完整 12×FFT + 66×GCC-PHAT/IFFT + SRP**，测试参考模型和性能；不得把测试坐标写进生产固件或当实板真值。

在 `TEST_GEOMETRY_ONLY` 下，确保 66 对**实际全部计算**，不是 66 次空循环，也不是注入预先算好的最后定位结果。每对输出必要的 `pair_id/result_valid`，仅在 profile 外按合适开销记录审计信息。若当前算法并非“每对各运行 1024 点 IFFT”，按**真实实现**审计，以最终数学等价/参考模型对照为准，不强行制造多余工作。

### 3.2 参考数值正确性

- 12 路正向 FFT 与 Python/C 标量黄金模型对比，明确 Q 格式、舍入、饱和和 bin 约定。
- 66 对互谱 `X_i·conj(X_j)`，PHAT 弱谱点/零除处理按真实固件约定；确保 SIMD 与标量参考可比。
- 逆 FFT 或等效相关算法：相关峰、符号、循环移位约定正确。
- 32 点相关环优化必须证明能覆盖测试几何 SRP 查询的全部合法时延；**不能**推断真实未知物理几何也一定足够。
- SRP 的每一个输出包含 `window_id、first_sample、geometry_mode、result_valid`；禁止静默用旧结果假装新窗口完成。
- 严格核对真实 `pairs_executed==66`、`fft_forward_executed`、`ifft_executed/等价计算次数`、`srp_grid_evaluations`，汇报与代码入口一致的期望值。

**Gate 3**：完整链数值测试 PASS；“全链真实执行计数”可证；真实坐标缺失仍明确标记 `方向精度未验收`。

---

## Phase 4｜建立方案 A 的逐窗真实周期基线（区分延迟、吞吐、等待）

### 4.1 性能事件必须覆盖整个链条

建议扩展现有 `rdcycle`/结果 MMIO（名字由仓库决定）记录每个窗口：

- `halfblock_ready / halfblock_copy_begin / halfblock_copy_end`；
- `ready_poll_wait`、`mmio_read`、`unpack_stats`、`raw_buffer_copy`；
- `window_publish / window_acquire / window_staging_copy`；
- `DC_mean`、`DC_remove/scale`、`Hann`；
- `FFT_PUSH / FFT_RUN / FFT_POP`（全部正向 FFT）；
- `cross_spectrum / PHAT / all_pair_IFFT / 32point_extract`；
- `SRP_scan / result_commit`；
- `window_ready_cycle / result_valid_cycle`；
- CPU 实际指令执行、VFFT stall、MMIO wait、共享 SIMD 等待、BRAM 忙；
- `expected_windows / processed_windows / skipped_windows / raw_block_loss / audio_drops / max_backlog`。

避免在每个采样点打印影响时序。计数器 32 位回绕按照无符号差值处理并说明单窗口时间；绝对 timestamp 需 64 位/扩展计数或有正确回绕处理。`rdcycle` 计到 FFT 阻塞等待，不等于 FFT 的运算电路本身消耗同样多的 CPU 指令。

### 4.2 必须给 4 种可比较基线

| 测试模式 | 重叠 | 几何/算法 | 作用 |
|---|---|---|---|
| M0 | OFF | 当前生产几何状态 | 回归原功能 |
| M1 | ON | 只验证真实窗口与原有已启用阶段 | 单独测分帧/缓冲开销 |
| M2 | ON | TEST_GEOMETRY_ONLY + **完整 66 对及 SRP** | 方案 A 性能与数值核心依据 |
| M3 | ON | 原 66 对参考算法或标量参考 | 判断硬件优化是否改变结果 |

所有性能对比必须注明同一 `HEAD + test vector + toolchain + build flags + measurement mode`；跨 commit 时写清差异。M2 无法执行时**不能**从 M1 推测方案 A 可行。

### 4.3 端到端时间线与预算

严格模式每个 Hop 的 `window_ready` 理论间隔 524288 cycles。窗口处理可以流水化/重叠，但必须给出：

1. **平均每 Hop 资源消耗与稳态吞吐**：多窗口连续结果间隔的最大值、均值、P99；
2. **逐窗端到端延迟**：每窗 `result_valid_cycle - window_ready_cycle` 最大值；
3. **并发关键路径**：CPU、FFT、SIMD、采集 RAM 和 SRP 谁在何时并行，哪些阶段仍串行；
4. **队列行为**：每 Hop backlog 的变化，不能 10 帧缓存够用就宣称长期实时；
5. **生产功能覆盖**：66 对全部执行且 result 对应**同一个 window_id**。

**Gate 4**：生成每个模块真实耗时、每窗总耗时及连续吞吐证据。若 M2 超过 524288 cycles，进入 Phase 5 数据驱动优化，不得宣称已实现方案 A。

---

## Phase 5｜先做可回退的低风险软件/数据复用优化

依照 Phase 4 排序，而不是固定猜瓶颈。一般优先序可从下列候选挑选：

1. **采集**：只读本 Hop 新 512 点；证实每 32-bit 字是否承载 2 路；分析 MMIO 2 拍应答之外的 CPU 指令和索引开销；减少多余 INDEX 写与重复拆包。使用 `objdump -d` 结合计时证明收益。
2. **滑窗统计**：如果 DC 均值来自窗口求和，验证 `sum_new = sum_old - sum_departed + sum_arrived` 的滑动递推在定点量化、溢出、舍入下是否与全量算法一致。最大值、峰值、能量和异常检测的等价递推需另外证明，不能随意复用。
3. **预处理**：将 DC 去除、增益定标、Hann 加窗的重复读取/写回减少到 1～2 遍，按当前数据类型和实际存储布局优化；原始环形样点不可被就地改写。注意同一原始样点在不同窗口的 Hann 位置不同，**不能照搬上一窗已加窗结果**。
4. **FFT 输入/输出**：减少非必要的临时转存、可验证的地址计算和频谱重复取回；旧指令编码与黄金测试不变。
5. **66 对相关**：证明 SRP 真正用到哪些 lag、是否可使用合法的频域/时域等效算法降低 66 次串行 IFFT；必须附数学正确性、测试几何结果和周期对照，不允许仅“只回读 32 点”就省略必要计算。
6. **SIMD 使用**：评估现有 8 lane 向量单元是否可加速 DC/PHAT，检查音频优先仲裁。由于 SIMD 与连续 FIR 共享，必须同时测 `audio_drops` 和最坏等待。
7. **缓存与调度**：允许正向 FFT、互谱、逆 FFT、SRP 通过多级流水线和双缓冲**并行处理不同窗口**，但严格区分不同 `window_id`，避免跨帧数据串扰；实现上不强迫所有阶段单线程串行。

每项优化必须单独提交 A/B 数据：`cycles_before/after`、数学误差、`raw_block_loss`、`window_skip`、`audio_drops`、当前最大 backlog；未达收益或破坏功能需回退该项。

**Gate 5**：低风险优化后的 M2 正确性与周期对照。若仍不达标，进入 Phase 6 架构评审；不要继续只加大 buffer。

---

## Phase 6｜高风险 RTL/存储/计算并行架构方案：先设计、获批再实施

如仍超过预算，给出不少于 3 个具有资源/时序/带宽分析的技术选项。示例（**候选，不是默认必须实施**）：

### 6.1 采集端自主块复制（优先评估数据通路）

- 采集侧直接将发布后的新 512 点半块复制到具备明确所有权的 scratch/BRAM/FIFO，而不让 RV32 反复按字 MMIO 读取；
- 分析硬件实际每周期可写字数、Bank 存储端口、CPU/DAS 冲突、跨时钟/使能时序、总线仲裁、地址范围保护；
- 对比现有 MMIO 约 9.46ms（历史旧模式）与新 Hop 半块读取的**实测**，不能把 9.46ms 整段全算成可省；
- 不允许在未获用户同意时直接增加新 DMA 总线或改变 PS 访问寄存器语义。

### 6.2 预处理硬件化或专用 SIMD

- 评估流式 PCM 基础统计、定标与窗乘，区分窗口级 DC 均值依赖（不能在全帧采满之前盲目完成全局均值去除）和可跨窗口共享的固定比例操作；
- 核对 DSP48、BRAM、LUT/FF 和 40 MHz WNS/WHS，确定加速价值、冲突点与延迟。

### 6.3 66 对 GCC-PHAT / IFFT / SRP 专用并行

- 评估频谱矩阵缓存、并行互谱 PHAT 引擎、相关所需 lag 的计算简化、分组 IFFT 以及 SRP 硬件扫描；
- 必须给出每对处理字数、并行度、BRAM 读端口数和仿真/综合成本；
- 必须证明数学等价并保持输入窗一致；不要无条件实例化 66 个 FFT 核。

### 6.4 VFFT 块搬运仅在最新口径表明值得时启用

- 复用之前已经讨论过的 scratch RAM B 口与自定义指令建议前，重新核对当前 RTL/宏与地址映射；
- 旧 `push+pop` 在几何关闭五段里仅占 6.5%，但完整 66 对后占比可能改变——**重新测量**，不使用旧 1.07× 封顶推导全部未来场景；
- 自定义编码不得与原 PUSH/POP/RUN 冲突；相关 RTL 改动需独立 golden 回归；
- 需特别处理逆 FFT 的输入缓冲未必位于 scratch 的问题，以及 memory stall 排空/读写时序。

### 6.5 架构评审交付模板

```
Proposal ID: A-RTL-xxx
根因及证据（逐窗耗时、资源等待、文件:行号）:
方案 1/2/3 对比:
  - 数据路径与模块图
  - 每 Hop 最坏读/写带宽和峰值 BRAM 容量
  - 预期节省周期（计算假设）与最差情况
  - 需要改动的 RTL/固件/测试文件
  - 对连续 DAS/FIR 和 HALT/AXI 的影响
  - 资源增量估算 LUT/FF/BRAM/DSP
  - WNS/WHS 风险和回退方式
推荐一项及原因:
用户需要批准的具体内容:
```

**Gate 6**：向用户提交方案并**停止**在需要授权的重大 RTL 边界。批准后再进入 Phase 7 实施。不能因用户提出“最终做 A”就视为授权任何大规模硬件架构改写。

---

## Phase 7｜获批后的 RTL/固件迭代与实际约束验证

每一批仅改变一项瓶颈，包含：

1. 模块 testbench 数学 golden 和所有权/握手断言；
2. `tb_pdm_capture`、`tb_live12_soc`、完整 66 对 M2 回归；
3. 检查旧指令、5 级流水线停顿/冲刷、共享 SIMD 优先级、PS HALT 时控制、BRAM 读写冲突；
4. 在用户既有流程使用 `scripts/run_zynq_flow.ps1`（或当前真实脚本）重新综合和实现；运行前按仓库流程处理 Vivado 进程独占，保存 `WNS/WHS/利用率/路径`；
5. 若 WNS<0、WHS<0、功能回归失败、音频 drops>0 或快照所有权断言失败：**不能发布可用版本**；先报告并修复。

不要因为 RTL 仿真 PASS 就忽略实现时序。ZYNQ-7010/7020 资源不同，不能把 7020 的实现资源假定在 7010 也有。

---

## Phase 8｜严格实时压力验证（可核验的 PASS/FAIL 门槛）

### 8.1 必须的测试用例

| ID | 场景 | 核心判据 |
|---|---|---|
| T01 | 4 个连续半块、3 个 overlap 窗 | 12×1024 逐点与 golden 相等；first=0,512,1024 |
| T02 | 16 个半块、连续窗口 | 后一窗口前半段等于前一窗口后半段；全部窗口 ID/first 连续 |
| T03 | PDM/PCM 合成数据边界/正负数 | 打包/符号扩展、窗口存储正确 |
| T04 | SEQ/FIRST 跳号、重复、回绕、复位 | 明确检测异常，不生成假连续窗口；在 STRICT 模式测试标 FAIL |
| T05 | Bank 延迟读取/ACK/RELEASE | 所有权完整、无未授权覆盖、错误可观测 |
| T06 | VFFT 阻塞与新半块同时到达 | 不破坏连续采集，不拿错窗口 |
| T07 | 完整 12 路 FFT、66 对 PHAT/IFFT、SRP | 数值误差达标，执行次数可证，不跳过计算段 |
| T08 | 多窗依次执行并追踪 window_id | 输出与正确窗口绑定，不拿旧定位当新输出 |
| T09 | 原非重叠模式回归 | 原功能/旧 golden 不退化 |
| T10 | 共享 SIMD 强负载+DAS/FIR | 音频连续、无资源饥饿和新丢样 |
| T11 | 至少 256 Hop 的严格实时 SoC 压力测试 | 逐 Hop 结果、吞吐和延迟均满足；无窗口跳过/原始丢块/音频掉样；若仿真耗时过大需报告实际覆盖数量 |
| T12 | 针对改动 RTL 的 Vivado 实现 | 40 MHz WNS≥0、WHS≥0，资源/关键路径记录齐全 |

### 8.2 统计脚本必须能自动判定

建议可复用脚本 `scripts/check_overlap50_strict.py`（如当前已有同功能脚本，扩展之；不创建重复脚本），读取结构化事件日志，自动计算：

```text
expected_windows: 由连续 sample range 自动推导
processed_windows: 实际完成有效全链定位结果数
missing_windows: expected - processed（排除明确规定的初次 1024 点预热）
max_result_gap_cycles: 相邻结果完成周期的最大间隔
max_window_latency_cycles: 每窗就绪至完成周期的最大值
max_backlog: 队列峰值及稳态增长情况
raw_block_loss, window_skip, audio_drops
fft_fwd_count, gcc_pair_count, ifft_or_equiv_count, srp_exec_count
geometry_mode: TEST_GEOMETRY_ONLY 或真实已确认模式
```

PASS 条件全部成立：

```
window_length == 1024
hop == 512
all_expected_windows_processed == true
missing_windows == 0
raw_block_loss == 0
window_skip == 0
audio_drops == 0
all_12_channels_window_golden_match == true
all_algorithm_stages_executed == true
all_pair_computation_verified == true
max_result_gap_cycles <= 524288
max_window_latency_cycles <= 524288
40MHz_timing_met == true   // 仅对已实际运行 Vivado 的构建成立
```

若测试在 `geometry_enabled=0` 下跳过算法，自动标记 `FULL_CHAIN_NOT_EXECUTED` 且**绝不能 PASS**。如果仅有逐窗吞吐而某窗延迟>524288，则输出 `THROUGHPUT_PASS_LATENCY_FAIL`。如果当前硬件设计无法实现，请输出 `BLOCKED` 并提供定量证据。

### 8.3 重要的测量口径

- 合成 PCM 的 XSim 结果是 RTL 逻辑级验证，不等于真实麦克风实板延迟。
- 计时版固件可能改变 GCC 的寄存器分配；标明 profile ON/OFF。
- 真实几何未知：只可声明“在合成几何/合成声源下的完整算法正确性与吞吐”，不可声明真实三维定位误差达标。
- 采集源、处理器与输出计数可能跨不同节拍，要标明事件所在时钟域并做可靠的跨时钟同步；不要拿不等价的计数器硬相减。
- 稳态处理吞吐不等于“首帧 13 ms 出结果”；首次 1024 点物理采集至少需 26.2144 ms，再谈处理延迟。

---

## Phase 9｜台账、工程交付和 Codex 汇报模板

### 9.1 台账

按 `CLAUDE.md` 当前规范，更新 `docs/measurements.md`，完整记录：

- 当前 commit、时间、设备/工具版本、仿真还是板级、时钟频率、是否插桩、输入数据来源；
- M0/M1/M2/M3 各自真实运行的算法模块；
- 优化前/后所有阶段的**周期**、吞吐、逐窗延迟和最大 backlog；
- 功能数值误差、窗口连续性、音频 drops、SEQ/FIRST 行为；
- Vivado 利用率、WNS/WHS 和关键路径；
- 对每项 FAIL/复现和修复在 `docs/issues/` 新增档案，并更新索引。

### 9.2 每次回复必须包含

```text
[STATUS] Phase X / PASS | FAIL | BLOCKED | NOT RUN
[COMMIT] 当前 HEAD，git status
[FACTS] 真实源码证据（文件:行号）
[CHANGES] 修改文件和核心行为；是否仍可一键回退
[TEST] 完整命令、退出码、日志路径、关键断言
[NUMERIC] 12 麦逐点 / FFT / GCC / SRP 黄金误差
[PERFORMANCE] 每窗各段周期、端到端延迟、稳态结果间隔、窗口数、丢块/跳窗/音频掉样
[IMPLEMENTATION] Vivado part、LUT/FF/BRAM/DSP、WNS/WHS 或 NOT RUN
[DECISION] 本阶段是否达到 Gate；下个安全动作；是否必须征求用户批准
```

### 9.3 阶段性里程碑，不允许越级宣称

- **A-L1**：独立算法 50% 重叠窗正确（数学/软件）。
- **A-L2**：当前采集 RTL 真正连续发布新 512 点，无被覆写，12 路窗口完整正确，原音频不断流。
- **A-L3**：在测试几何下真实执行完整 12 麦/66 对 GCC-PHAT/IFFT/SRP，算法黄金结果正确，按窗输出可追踪。
- **A-L4**：长时间**无窗口跳过**，稳定每 524288 拍一结果且逐窗完成延迟也 ≤524288 拍；40 MHz 时序收敛，音频无掉样。这才是方案 A 的**RTL 仿真级严格实时 PASS**。
- **A-L5**：拿到真实物理阵列坐标后，实板验证真实方向角、定位误差、音频连续性、功耗/温度/运行稳定性；A-L4 不能冒充 A-L5。

---

## 10. Codex 启动指令（复制下面这一段即可）

> 请阅读仓库中的 `ZYNQ_12麦_方案A_严格实时50%重叠定位_Codex实施任务书_V3.md` 并执行方案 A。先按 Phase 0 审计真实代码、校准历史周期口径；对可回退的固件与单元测试修改可直接实施。Phase 1～5 依次完成 12 麦 1024 点窗口/Hop 512 正确拼窗、Bank 所有权连续性、66 对完整算法的 TEST_GEOMETRY_ONLY 真执行验证、逐窗 `rdcycle` 与基于瓶颈的优化。不得把几何关闭而跳过计算的模式当作完整链，也不得以静默跳窗达成吞吐。对于增加/重构 Bank、DMA、共享 RAM、CPU 指令或硬件并行单元等重大 RTL 改动，必须先给资源、带宽、时序、风险、替代方案与定量预期并等我批准；一旦获批再完成 RTL/固件、Vivado 时序与持续压力验证。最终按 A-L1 到 A-L5 分级交付：目标 A-L4 需长期每 524288 拍产生一个真实完整定位结果，同时每窗延迟≤524288、原始块无丢失、窗口无跳过、连续音频 drops=0，并提供测试命令与日志。真实阵列坐标未知，生产几何维持安全门控，不能假装实板三维精度已经验证。

---

## 11. 提醒：本任务书不会替代真实工程源代码

用户尚未向本会话提供当前仓库的 `fw_live16.c`、RTL 和完整 XSim 汇总文件，故本任务书中的路径、周期、宏及行为**都是需要 Codex 在工作目录重新核实的线索**。如果当前仓库根本不具备足够的存储端口、DSP 或 40 MHz 时序余量，Codex 的正确行为是量化报告不能达到硬指标的环节，再提出可审批的硬件架构变更，而不是保证“只改固件肯定实时”。
