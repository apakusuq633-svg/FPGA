# RV32访存专项 Phase 0～6 执行报告

> 2026-10-15勘误：本报告记录的是此前构建。当前工作区已含C0/A和独立硬件定位模块；
> “功能RTL未修改/CSR尚未修复”仅适用于下文归档基线。新复核与严格验收状态见
> [当前报告](pdm12_taskbook_execution_20261015.md)，旧时序/实板结果不能代替当前实现验收。

任务书已完整阅读并原样保存为`PDM_RV32_mem_taskbook.md`；最终方案A不变。
本轮源码基线HEAD `10f6c3a`，固件/测试修改在工作区，未推送。
实际板卡JTAG识别`xc7z020`；本轮当前RTL重新完成ZYNQ-7020/40MHz综合、实现、位流和XSA，
再执行实板测试。坐标和物理通道排列仍未知，生产配置所有几何字段保持null。

## 阶段验收

| 阶段 | 修改、测量和文件 | 命令/日志 | 周期收益及判据 | 状态/剩余项/批准 |
|---|---|---|---|---|
| Phase 0 | 审计SoC/DTCM/LSU/MEM/流水线/采集，`perf_rv32_mem_audit.md` | `rg`及源码位置已列在审计表；新实现`implementation.log`、timing/util报告 | 无功能修改；确认1个边沿应答延迟、约3拍连续吞吐，不能混用 | 审计PASS；发现CSR minstret重复计数，尚未修复 |
| Phase 1 | `check_rv32_mem_perf.py`、`tb_rv32_mem_perf.v`、`check_rv32_mem_board.tcl`、`report_rv32_mem_perf.py` | `wsl python3 scripts/check_rv32_mem_perf.py`；另加`--mmio-unrolled`；日志`build/rv32_mem_perf/` | 76+8场景PASS；主测试28534事务、156音频点；76项实板rdcycle完全等于仿真。单次写/负载数据/字节选通/退休顺序一致 | Gate 1 PASS；新CSR探针准确检出25938次held-WB重复计数，不作为ISA全通过 |
| Phase 2 | 应用MEM_STAGE归因；`gen_pdm12_test_srp.py`、`fw_live16.c`、`fw_fft.c`、XSim入口和TB；独立A9加载/音频消费/记录工具 | `mem_full_chain`四帧；`build_rv32_board_profile.py`和`check_rv32_profile_board.tcl`实板四帧 | 全12 FFT/264对GCC及4096 SRP分数逐位PASS；有效算法阶段LSU等待250439拍，capture仅37110等待拍 | 完整算法快照归因PASS；OVERLAP尚未接入连续Bank，不能称完整重叠性能 |
| Phase 3 | 保留packed读取；`fw_prepare_fused.h`；`--hot-o2`；`fw_overlap12.h`和宿主测试 | `numeric_baseline`→`numeric_fused`；`mem_full_chain`→`mem_full_chain_o2`；实板`board_profile_os`→`board_profile` | Fused prepare 597689.5→486914.25拍；O2实板算法阶段2027748.5→1917205.5拍，省110543拍/5.4515%；固定输入四帧数值PASS | 安全优化PASS，显式宏可回退；INDEX候选无收益未推广。半块复用仅HOST PASS273窗口，实际Hop收益NOT MEASURED |
| Phase 4 | `perf_rv32_optimization_plan.md`：C0 CSR计数、A取指恢复、B DTCM协议、C MMIO、D架构候选 | 仅方案，无功能RTL diff | C0省0拍，仅修计数；A上界≤符合条件的等待事务数；不能保证实时 | **等待批准**；不删除Stall，不强拉ready，不改Bank/端口/ISA编码 |
| Phase 5 | `check_rv32_mem_regression.py`；修复FFT旧TB未接`io_seek_i`；PS TB按原Verilog模式编译 | 7项既有回归PASS；两份全链SoC分别4帧/264对/4096分数；两份实板4帧drop0/trap0 | O2 SoC音频15947点、0drop、最长101拍；实板同样0drop | 既有回归PASS；新CSR缺陷未修。获批RTL后回归/256-Hop压力验收**NOT EXECUTED**；严格方案A FAIL |
| Phase 6 | 本报告、三份详细文档、measurements台账、issues115/116、CSV/ELF/MAP/反汇编/构建清单 | `report_rv32_mem_perf.py`及`report_rv32_board_profile.py` | 所有测量保留输入、范围、hash、日志；历史scope标签更正说明而非篡改日志 | 文档交付PASS，后续功能RTL等待批准 |

## 当前方案A的量化判断

实板优化后算法阶段均值1917205.5拍=47.9301375ms，最大1917636拍=47.9409ms。
较524288预算多1392917.5拍（均值），最大多1393348拍。
这是当前**完整1024点快照算法阶段之和**，不含验证用完整IFFT/PHI复制，
也不是已实现的512帧移Hop端到端时延；其快照每次仍搬两半原始数据。
实际计算墙钟（含额外数值核对）和采样等待另保留在CSV，未用阶段相加冒充持续输出。

即使重叠只搬新半块，66对GCC本身仍需699766拍，比Hop预算多175478拍；
减掉GCC所有实测LSU等待97746拍，也还约602014拍，尚未计12路FFT、准备和SRP。
SRP硬件扫描另需270338拍。只修访存ready不能保证方案A。
FIRST间隔约3986～3987（O2）或4161～4162（Os），目标512，故严格实时明确FAIL。
snapshot raw DROP=0不等于持续原始覆盖；本轮没有跳窗调度作为性能优化，
没有减少FFT点数、麦克风数或GCC对数来通过验收。

真正50%重叠的持续Bank服务、原始数据全覆盖、完整算法长时间无丢窗、256+Hop和
真实几何定位准确性仍未完成。半块宿主视图原型会明确拒绝慢消费者，不会伪造成功。

## 可重复执行的核心命令

```powershell
wsl python3 scripts/check_rv32_mem_perf.py
wsl python3 scripts/check_rv32_mem_perf.py --mmio-unrolled
wsl python3 scripts/check_rv32_mem_regression.py
wsl python3 scripts/gen_pdm12_test_srp.py
wsl python3 scripts/build_live12.py --profile --numeric66 --fused --test-srp --mem-profile --hot-o2
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Twelve -CycleProfile -Numeric66 -TestSrp -SnapshotFrames 4 -RunTag mem_full_chain_o2
wsl python3 scripts/summarize_pdm12_run.py build/pdm12_runs/mem_full_chain_o2 --numeric
wsl python3 scripts/report_rv32_mem_perf.py
```

实板ARM加载器编译/下载命令归档在`build/rv32_mem_perf/board_profile*/`，源码生成器和
XSCT脚本保留在`scripts/`。下载要先执行`check_jtag_owner.ps1`。
实板当前保留本轮测试位流，测试结束后RV32与A9停止，DAS停止继续入队；未写启动Flash。
这不是已经部署的持续定位程序。

当前实现资源：28383 LUT/15684 FF/84.5 BRAM/131 DSP，40MHz WNS+0.615ns、WHS+0.029ns。
这些是未修改软核功能协议的当前实现，不是待批准方案的综合结果。
下一步建议审阅并批准C0/A的小范围RTL实验，再依据实测收益决定更高层并行加速；
批准依据是任务书Phase 4“功能性RTL改动先展示具体方案，等待批准”的明确停止点。
