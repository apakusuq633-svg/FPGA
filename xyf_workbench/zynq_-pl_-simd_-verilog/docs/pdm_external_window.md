# PDM外部窗口的条件Setup/Hold分析

下一阶段自动化入口已加入：`scripts/accept_pdm_project.ps1`（统一验收）及 `scripts/accept_pdm_external.ps1`（独立窗口门控），配置为 `configs/pdm_external_assumptions.json`。逐端点检查失败返回非零，不把资格时钟加入生产约束。详见[自动化与RAM实验报告](PDM验收自动化与RAM实验报告_2026-10-16.md)。

2026-10-16。本轮生产RTL不变，HOLD_TICK=4、CONSUME_TICK=12，对应驱动后125ns采样。源码XDC的5ns输入、10ns输出max datapath约束保留为实现护栏；它们不构成完整外部接口时序验收。新的可复现分析入口是 `scripts/check_pdm_external_sta.tcl`，公共过程是 `scripts/pdm_external_window.tcl`。

## 为什么max datapath不够

`set_max_delay -datapath_only`排除了完整时钟关系，并抑制相关Hold检查，不能从内部WNS或输入min路径报告推导出外部Hold通过。分开的输入5ns、输出10ns预算也没有自动组合麦克风延迟、PCB往返传播、驱动/释放边沿、实际时钟插入、CPR和器件建立保持弧。简单删除此约束会让40MHz每25ns的无效采样参与检查，同样不能表达实际使能语义。

[AMD UG903说明](https://docs.amd.com/r/2023.1-English/ug903-vivado-using-constraints/Consequences-of-Setting-Maximum-Delay-or-Minimum-Delay-Constraints-on-a-Path)明确指出datapath_only会忽略Hold。本轮用Vivado2020.2实际路径与负例检查对应行为。

## 边沿、端点及假设

依据[IM73D122V01数据手册v1.00第8–10页](https://www.infineon.com/dgdl/Infineon-IM73D122-DataSheet-v01_00-EN.pdf?fileId=8ac78c8c83cd3081018409cafdfb46db)：tDD为40..80ns，tDV最大100ns，tHZ为5..30ns。tDD表示开始驱动，不等于已经达到有效逻辑电平；Setup采用tDV。Hold以最早进入高阻为保证终点，不借助线容延长有效时间。上述数值的测试负载、供电、阈值及温度条件必须与实物核对。

PCB CLK与DATA各采用0..3ns假设；不是实测，也不包含电平转换器。相对不确定性额外留2ns。FPGA C→Q、输出OBUF、输入IBUF、布线、采样时钟树、器件Setup/Hold使用实际routed器件弧，不再重复扣除解析模型中的2ns FF占位。报告总不确定性约2.035ns。

| 相位 | Setup数据来源 | 有效采样 | Hold失效来源 |
|---|---|---|---|
| A，L/R=GND | 下降沿0ns + tDV + PCB往返 | 125ns，phase_a_q[0..5] | 随后上升沿200ns + tHZ最小 + PCB往返 |
| B，L/R=VDD | 上升沿200ns + tDV + PCB往返 | 325ns，g_phase_b.u_cic_b/bit_q[0..5] | 随后下降沿400ns + tHZ最小 + PCB往返 |

基本窗口关系：Setup要求 `capture−launch−PCBmax−tDV−input_max−setup−uncertainty >=0`；Hold要求 `opposite_edge+PCBmin+tHZmin+input_min−capture−hold−uncertainty >=0`。实际STA还包含传播时钟及CPR，直接采用完整报告计算。

## 分析脚本如何工作

1. 打开完整SoC原有routed.dcp，确认六个A和六个B端点。保存真实40MHz时钟源后，在内存中reset_timing，移除旧max datapath及其隐式Hold例外。
2. 在真实PDM输出pad建立400ns生成时钟，传播实际系统时钟、clkgen C→Q和输出路径。
3. 在十二个采样C端点建立400ns资格时钟，边沿表达被使能的125/325ns采样。它们是用于接口证明的时序抽象，并非新增物理时钟。B的bit_q每25ns更新，但只有CONSUME对应值进入CIC；A锁存后内部传递仍由原40MHz设计约束检查。
4. 对真实输出时钟上升、下降沿均建立 `input_delay -max 106`、`-min 5`；106=tDV100+CLK PCB3+DATA PCB3，5=tHZ最小5+PCB最小0。
5. 仅对不属于该相位的边沿分别排除setup或hold：A保留下降沿setup、上升沿hold，B相反。不是整条输入false_path；保留的24条路径必须全部存在。
6. 导出full_clock_expanded Setup/Hold报告、每端点paths.csv、summary.txt。验证器确认24条路径无datapath_only例外、源/捕获时钟传播均存在，并核验故意失败的两个边界负例。

**隔离要求：**分析会重置约束并替换采样时钟，仅用于外部12条输入路径。不能使用此状态下的全局WNS验收内部逻辑；`ANALYSIS_ONLY_NOT_FOR_BUILD.xdc`不得加入生产工程，不保存覆盖原DCP。独立实验在分析前另存真实约束下routed.dcp及internal_timing.rpt。

## 实际结果及边界

完整SoC、125ns，`build/pdm_convergence/external_final`：

| 条件 | A Setup/Hold ns | B Setup/Hold ns | 判据 |
|---|---:|---:|---|
| max106/min5 | +5.314 / +80.999 | +5.503 / +80.972 | 假设下全部24路径通过 |
| max206/min5 | −94.686 / +80.999 | −94.497 / +80.972 | 故意延迟100ns，Setup必须失败 |
| max106/min−195 | +5.314 / −119.001 | +5.503 / −119.028 | 故意提前失效200ns，Hold必须失败 |

负例是验证模型检查能力，不是正常麦克风参数。实例Setup路径包含源时钟10.422ns、捕获时钟约2.862ns、CPR0.115ns、输入106ns及输入路径4.147ns；这是实际报告来源，不能拿旧解析0ns预算冒充同一口径。

完整SoC报告位置：`external_final/nominal125/setup.rpt`、`hold.rpt`、`paths.csv`。所有报告均在build/pdm_convergence下，部分.rpt被Git忽略但实际存在。独立125/150/175结果见[本轮报告](PDM收敛性整改报告_2026-10-16.md)。最差Setup仅约5.3ns，对超出假设的传播、负载及阈值很敏感；新增未计入延迟按一阶关系等量消耗Setup裕量。

状态：**PASS（条件STA及检查器自检）**；**UNVERIFIED_HARDWARE（实际接口）**。仍需真实载板确认L/R、VDD/VCCO、VIH/VIL、电平兼容、12麦CLK扇出、DATA电容、走线/排线往返延迟、占空比及温度/电压边界。没有这些证据不能冻结硬件时序模型或升级为板级PASS。
