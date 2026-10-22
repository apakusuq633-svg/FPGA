# 声源定位/DAS集成验证复现

源码根为 `D:/Users/xyfhhh/Desktop/PDM/zynq_-pl_-simd_-verilog`。以下Python命令在WSL源码根执行，Vivado/XSim命令在Windows PowerShell执行。不连接开发板、不执行Git提交或复位、不覆盖原release。

## 模型与模块

```sh
python3 scripts/integrated_acoustics.py --output build/zynq12_integrated_plan/m1_release
python3 scripts/evaluate_das_quality.py --output build/zynq12_integrated_plan/m2_quality
python3 scripts/check_das_precision.py --output build/zynq12_integrated_plan/m2_precision_release
python3 scripts/check_integrated_interfaces.py --output build/zynq12_integrated_plan/m3_smooth_ab
python3 scripts/analyze_direction_ab.py
python3 scripts/evaluate_switch_candidates.py --output build/zynq12_integrated_plan/m3_candidates
python3 scripts/analyze_grid_coverage.py
python3 scripts/analyze_integrated_figures.py --output build/zynq12_integrated_plan/reports/figures
```

已有输出目录必须保留，复现应改用新名字，并相应调整引用几何向量的参数/路径。参考场景seed20261015，12路、Fs39062.5Hz、c343m/s、FFT1024、Hop512、66对、SRP1024槽。`integrated_acoustics.py`在产生样点前写出acceptance.json，固定阈值、测试几何及模型假设；绝不写production_array.json。

`--generate-coeff`只用于重新生成设计系数头文件，不属于日常复现必需步骤。现有头文件与独立有理数定点参考逐样点比较；复现不得为了制造PASS而调整系数或验收阈值。

## 完整SoC与压力

```sh
python3 scripts/run_integrated_validation.py --tag m5_validation_release
python3 scripts/check_integrated_auxiliary.py --output build/zynq12_integrated_plan/m5_auxiliary_signed_release
```

实际正式目录见最终报告和manifest。总驱动先执行短场景、显式/自动恢复、GSC反压、物理声场及联动，再运行256/1024窗、183压力、4096窗、回卷、不同seed、CPU/访存回归。4096窗在单独子进程重放已构建并固定哈希的相同Verilator模型，与1024窗等独立场景并行，不减少仿真周期。

定位黄金参考为独立host C定点模型；物理声场浮点参考独立于该有限字长算法。检查三遍RAW标签、FFT/PHAT/相关环/全部SRP分数、实际发布峰值、真实指令退休次数及音频。链接模式按独立几何期望表、输入PCM、1/16样点渐变和有理数插值系数计算完整逐样点golden，禁止从DUT音频反推期望值。

`--output`现在同时隔离固件与仿真wrapper，新增报告名归档防止同一个场景参数的后续重放覆盖旧日志。单场景JSON、CSV、manifest及完整log均保留；若RTL改变，`--reuse-model`拒绝旧模型。短测试用的算子桩不替代SoC算术回归。

压力结果分为PASS（按截止正确）、CORRECT_LATE、EXPLICIT_LOSS、ERROR；总检查器成功只表示所测场景符合相应分类，绝不把EXPLICIT_LOSS计入实时成功。4096窗的实际输入覆盖时长由produced/Fs计算，不宣称一小时板测。

本次真实DTCM覆盖检查曾拒绝“只有MMIO阻塞”的旧注入点。修正后的正式补测与独立长跑命令如下，原失败记录及中断的长跑日志均保留：

```sh
python3 scripts/check_localizer12_safety.py --dtcm-probe --kind mem --phase raw --duration 50000 --windows 4 --output build/zynq12_integrated_plan/m5_validation_release/dtcm_real --report-name dtcm50000
python3 scripts/build_fast_simulator.py --model build/zynq12_integrated_plan/m5_validation_release/safety --output build/zynq12_integrated_plan/m5_validation_release/fast_simulator
python3 scripts/run_localizer_long.py --model build/zynq12_integrated_plan/m5_validation_release/safety --binary build/zynq12_integrated_plan/m5_validation_release/fast_simulator/model/Vtb_localizer12_safety --output build/zynq12_integrated_plan/m5_validation_release/extended4096_verified --windows 4096
```

O3只用于主机仿真器，16窗对照确认数值和架构周期摘要完全相同；FPGA性能比较始终使用RTL周期。所有测试及当前源码匹配后，运行`python3 scripts/finalize_integrated_release.py`生成只认完整实际证据的正式报告与新artifact目录。

## XSim与Vivado

```powershell
wsl python3 scripts/build_live12.py --transfer --windows 4 --hot-o2 --output build/zynq12_integrated_plan/m5_xsim_fw
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Transfer -SnapshotFrames 4 -RunTag integrated_m5_xsim_signed4 -TransferBuild build\zynq12_integrated_plan\m5_xsim_fw
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/run_integrated_impl.ps1 -Tag m5_impl_release
```

实现驱动拒绝已有目录，使用独立工程/输出路径和当前源文件manifest，明确xc7z020clg400-1、40MHz和12路参数。以FLOW_PASS及routed setup/hold报告为准，不仅看进程退出0。新增插值头文件必须进入Vivado fileset，已在建工程脚本补齐。

未来GSC tap的资源/时序可在完整实现结束后用 `scripts/measure_gsc_tap.tcl` 单独OOC测量。此测量不等于已实例化PS DMA；现有PS顶层未连接该内部流，工具可裁掉未使用的tap逻辑。

本轮没有真实麦克风XYZ、空间通道映射、板级采样或实际声场验收。生产几何和自动转向默认关闭；自动恢复需显式AUT1启用并受三次尝试上限约束。接口布局、时间轴和恢复语义见 `PS_GSC接口契约_2026-10-15.md`。
