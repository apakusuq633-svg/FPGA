# 16 麦第一阶段：采集与固定 DAS

用户已确认：两麦共线，8 根 DIN；阵列尚未到位，先完成仿真与位流，保留四麦实板程序。

后续 [16麦定位配置](live16_localization.md) 已完成120对、32×32定位、自动转向、PS/GUI及独立位流；本页保留固定方向配置的历史验收。

2026-10-13防漂移任务中，固定版固件也补齐了采集INDEX读等待，前端/捕获/DAS/1200样点SoC再次通过，PS显式`-FixedDas16`重建通过；固定版位流未重建。旧配套清单已保留为`build/das16/live16_fixed_manifest_pre_quality_20261013_110650.json`，不作为本次新固件的发布清单；当前生产发布使用`build/das16_loc`版本。

本阶段路径为 16 路 PDM → 通道对齐/去直流 → 固定正前方 DAS → SIMD 32 抽头 FIR → PS 40000 点音频段 → 诊断与网页。DAS 的 16 路延迟均为 0，等权求和除以 16；圆阵声孔共面、指向正前方时使用等延迟。定位、自动转向和音频/定位同步不在本阶段启用。

## 接线与配置

配置入口为 `configs/live16_fixed.json`。通道 2k 与 2k+1 共用 DINk，分别为 L/R=GND、VDD。采用标准八路 J3 数据引脚 Y16/Y17/T15/T14/W16/T17/V18/V17，CLK=V16，和四麦调试板的删减接线不同。最终物理槽位与 DIN/LR 对应仍需阵列板确认。

`rv32_soc` / `rv32_ps_top` 的配置为 DAS_ACTIVE_CHANNELS=16、PDM_CHANNELS=16、PDM_MICS_PER_LINE=2。默认八麦及四麦调试仍可构建，16 麦工程输出独立放在 `build/das16_zynq` 与 `build/das16`。

## 实现与接口

- DAS 的 PCM、延迟、缓存和计数器按通道容量扩展；16 路累加留足位宽，延迟插值保留 1/16 样点分辨率。每通道历史为 64 点。
- 连续音频 FIFO ABI 保持不变：0x380 窗口，DATA 低 16 位 DAS、高 16 位 FIR，256 点。0x3c0 返回有效通道数 16，PS 启动时拒绝不匹配位流。
- 手动延迟 CH0～7 仍为 0x3a0～0x3bc，CH8～15 增补在 0x3e0～0x3fc，避免覆盖 0x3c0 的通道数寄存器。单通道延迟格式与既有 ABI 相同。
- 原始快照每样点 8 个 32 位字，双 bank 各 512 点；frozen 使用独立 0x330 的完整 16 位标志。
- 独立固件 `fw_live16_fixed.c` 只统计快照，不执行 GCC/SRP。DTCM RESULT 基址 0x2800，RESULT(0)=0xDA516001，RESULT(8～87) 为每路 sum、平方和低/高、peak、clipped；RESULT(88) 奇偶发布序号，RESULT(89)=0x4d493136。这个布局仅供第一阶段固件，后续定位固件必须重新规划工作区，不能与旧 `FW_OUT_BASE=0x2880` 混用。
- PS 不加载旧转向 LUT，以手动模式启动 DAS。页面显示 16 路电平和固定方向模式，不显示旧四麦定位点。单声道音频采样率仍为 39062.5 Hz，PS 音频吞吐不会因麦数变为 16 倍。

## 构建与复现

```powershell
python scripts/build_live16_fixed.py
powershell -ExecutionPolicy Bypass -File scripts/build_ui_pipeline.ps1 -ActiveChannels 16 -Live -MatchingPlWindow -FixedDas16
python scripts/check_live16_stage1.py
$env:DAS_ACTIVE_CHANNELS='16'
$env:LIVE16_LOCALIZATION='0' # 固定方向历史配置；生产16麦默认开启1024格定位
$env:ZYNQ_PROJ_DIR="$PWD/build/das16_zynq"
$env:ZYNQ_OUTPUT_DIR="$PWD/build/das16"
# 用本机 Vivado 执行 scripts/run_zynq_flow.tcl
python scripts/package_live16_fixed.py
```

前端共线仿真 34 项通过；DAS 4/8/16 路分别执行 1200 个样点，最长周期 76/76/132，逐位结果和 FIFO 溢出检查通过。PS 本机测试及四麦/16 麦 ARM 链接通过，GUI 16 行电平和固定模式测试通过。

SoC 集成仿真已通过：真实 RV32 固件完成 16 路快照统计，1200 个连续 DAS/FIR 样点逐位一致，FIFO 无丢样。验证用已知 PCM 在通道对齐输出注入，PDM 共线相位另由前端 TB 验证；没有把数字仿真当作真实阵列声学验收。

Vivado 完整实现、位流/XSA 和配套清单检查均通过：40 MHz 下 WNS=+0.044 ns、WHS=+0.021 ns，setup/hold/pulse-width 失效端点均为 0；LUT=33003/53200、DSP=191/220、BRAM=36.5/140。时序余量小，下一阶段改动必须重新实现验证。相对于四麦基线，LUT 27750→33003、DSP 175→191、BRAM 31.5→36.5。

可用产物：`build/das16_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit`、`build/das16/das_fir.xsa`、`build/ui_pipeline_live16/ui.elf`、`build/das16/live16_fixed_manifest.json`。`package_live16_fixed.py` 检查参数绑定、引脚、时序、位流/XSA 一致性、映像哈希和源文件新旧关系。阵列尚未接入，清单 `board_tested=false`，当前四麦板运行程序未被替换。

第二阶段再扩展 120 对 SRP、短相关序列、FFT 复用、32×32 网格和 16 路自动转向；现有 SRP/转向实例保留但不执行，不代表第二阶段已完成。
