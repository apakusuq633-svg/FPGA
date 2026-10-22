# 当前生产配置：12 麦

> **2026-10-21 production update:** use the [confirmed planar8 board configuration](planar8_configuration.md). Four shared DINs: T14/Y17/T15/W16; CLK V16; active-low reset N16. The 12-mic three-face board is retired. Circular-array and 12/16-channel specifications below are historical and do not override `configs/production_array.json`.


**2026-10-14更新**：当前固件无几何时只读取/统计12路，不写无用途FRAME、不缓存FFT；已完成本轮完整GUI ARM链接及40MHz实现。新产物为 `build/system_optimization_release12`，启动方式见其中README，源码已同步回此工程。三维定位仍需真实XYZ与CH/DIN/LR映射，不能只打开旧宏就代替角度算法适配。本文后面的旧目录/2272字节/4412点记录是2026-10-13历史证据，当前964字节/3257点及完整资源/时序以[系统报告](system_optimization_20261014.md)为准。

2026-10-13。用户要求把生产默认统一为12麦；阵列是相邻三个相互垂直的面，每面4麦，实际尺寸与坐标等待图纸。

## 已切换的配置

| 项目 | 当前值 |
|---|---|
| 活跃麦克风 / PCM 通道 | 12 |
| PDM DATA | 6 根，每线2麦 |
| 通道映射 | CH2k=DINk相位A，CH2k+1=DINk相位B；空间麦位尚未绑定 |
| PL 时钟 / PCM 采样率 | 40MHz / 39.0625kHz |
| 采集格式 | 每时刻6个32位字，低16位偶通道、高16位奇通道 |
| 每 bank | 512时刻，3072字，12288字节；双 bank 共24576字节 |
| DAS | 12路独立历史、分数延时、等权平均；除以12，输出一路16位PCM |
| SIMD | 8 lane；用于32抽头FIR，lane与麦数无关 |
| SRP | 66对、1024个评分位置；相关环暂定32点 |
| Steering | 12路补偿、12288项表容量 |
| 三维几何与角度网格 | 未启用，等待真实坐标；1024是容量，不是已验证的角度分辨率 |

权威入口为 `configs/production_array.json`。SoC、PS顶层和Vivado BD默认均为12麦；旧4/8/16麦只保留显式选择的兼容性/历史测试入口，不参与生产默认选择。`LIVE16_LOCALIZATION`这个旧参数名暂保留ABI兼容，在12麦时也表示大阵列缓存和SRP窗口启用，实际麦对数量由通道数计算，不再写死120。

采集地址已由位拼接改为连续乘加地址，因为6不是2的幂；INDEX步长确实为6，而不是存储空洞的8。DAS使用 `floor((sum+6)/12)`，负数也按同一舍入规则，不能用右移替代。

## 几何未确定时的行为

生产固件读取12路快照、统计电平并持续输出零补偿等权DAS/FIR；几何未启用时不写FRAME、不执行预处理或FFT，频谱运算仅在几何启用分支进行。SRP/Steering的表容量和寄存器已配置，但生成表为零占位，固件不扫描/发布定位、不提交自动转向。PS页面显示“12麦几何待图纸，三维定位未启用”，不会把旧圆阵或固定Z平面的结果当作该三面阵列的定位。

生产配置没有填入虚构的麦坐标。图纸到位后须重算每麦/麦对延时、确认32点相关环是否覆盖阵列最大时差，再确定水平角/俯仰角网格、边界与周期距离策略。

## 当前验证与产物

- 12麦前端34项通过，包括六根共线DATA的逐相位参考和缺麦/换相反证。
- 12通道采集39项通过，包括6字连续地址、两个bank、序号、增益与丢弃。
- 12路DAS/FIR连续1200点逐位通过；最大104拍，预算1024拍；FIFO过载被计数。
- PS宿主编译/协议/界面测试通过；12路电平、66对标注和几何待定显示通过。
- RV32固件编译链接通过：text=2272字节，data=0，bss=760字节。
- Cortex-A9独立采音程序编译链接通过：`build/acoustic_arm/live_das12.elf`。完整GUI的ARM链接未执行，当前环境缺少UI工程及lwIP BSP。
- Vivado `rv32_ps_top` 默认12麦综合通过：LUT31556、FF15295、BRAM tile84.5、DSP183，目标xc7z020clg400-1。这是综合结果，不是完整布局布线时序结论。
- BD创建/校验通过：绑定12通道、每线2麦，生成的wrapper输入为 `pdm_din_i[5:0]`。
- 实际RV32固件的完整SoC测试已通过：Icarus和Vivado XSim均完成2轮快照，4412个连续DAS/FIR样点逐位一致、丢样0，12路统计与6字采集地址一致，未发布假几何。指纹为`LIVE12_SOC_PASS channels=12 lines=6 pairs=66 snapshots=2 audio_samples=4412 drops=0 geometry_enabled=0`及`LIVE12_XSIM_PASS`。
- `scripts/package_live12.py`配置证据归档通过，清单为`build/das12/configuration_manifest.json`，包含源文件/ELF/DCP/BD/wrapper和日志哈希。

默认生产工程位置：`build/das12_zynq/rv32_zynq.xpr`。用户后续在GUI完成了12麦位流，该轮报告WNS +0.709ns、WHS +0.048ns，但有XDC控制流与失效tacho约束警告；源文件已修，见[110](issues/110-pdm-xdc-control-flow.md)。修正后的约束尚须在已打开工程中应用并重跑实现。尚未在本会话下载或验证实板；原8/16麦位流不能作为该12麦配置证据。

已打开GUI工程可在Tcl Console执行以下命令，应用纯6线约束，无需重新创建工程：

```tcl
source {D:/Users/xyfhhh/Desktop/PDM/zynq_-pl_-simd_-verilog/scripts/apply_pdm_constraints.tcl}
apply_pdm_constraints 12
```

随后重跑综合、实现和位流。普通Tcl负责条件选择；工程实际加载的是`generated_constraints/ps_pl_wrapper.xdc`，没有if/foreach等XDC不支持的命令。`constrs/ps_pl_wrapper.xdc`是完整8线兼容模板，不能直接作为12麦工程约束加载。

## 复现

WSL中运行：

```sh
python3 scripts/build_live12.py
python3 scripts/golden/fw_fir_model.py
python3 scripts/check_live12.py
python3 scripts/check_ps_apps.py
python3 scripts/package_live12.py
```

Windows PowerShell中运行：

```powershell
node scripts/check_ui_page.js
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check_live16_xsim.ps1 -Twelve
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_acoustic_ps.ps1 -Live
& 'D:/Vivado/Vivado/2020.2/bin/vivado.bat' -mode batch -source scripts/check_live12_synth.tcl
& 'D:/Vivado/Vivado/2020.2/bin/vivado.bat' -mode batch -source scripts/create_zynq_project.tcl
```

`build_live_acoustic.sh`、`build_ui_pipeline.ps1 -Live -MatchingPlWindow`、`run_zynq_flow`和`package_ui_live.py`默认均选12麦。`package_live12.py`输出的是配置证据清单，不将其标成已实现/已上板发布。
