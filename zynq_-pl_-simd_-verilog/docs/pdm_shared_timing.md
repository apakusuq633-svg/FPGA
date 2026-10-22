# 12路双麦共线时序模型

2026-10-16收敛复核：下文分段预算继续作为生产实现护栏；新增[传播时钟、双相位Setup/Hold条件分析](pdm_external_window.md)及[本轮报告](PDM收敛性整改报告_2026-10-16.md)。完整SoC在假设PCB往返范围内得到Setup最差+5.314ns、Hold最差+80.972ns，两个故意超界负例被检出；这不是载板时序验收。

本模型使用显式分段数据路径预算，不把被时钟使能丢弃的40MHz采样当成有效PDM采样，也不虚构异步同步器或多周期例外。默认HOLD=4、CONSUME=12；对应驱动沿后125ns采样，两相位相差200ns。修改采点、系统频率、驱动半周期时必须重新计算并重新生成约束。

## 条件及来源

[Infineon IM73D122V01 datasheet v1.00](https://www.infineon.com/dgdl/Infineon-IM73D122-DataSheet-v01_00-EN.pdf?fileId=8ac78c8c83cd3081018409cafdfb46db)第8–10页：tDD=40..80ns，tDV<=100ns，tHZ=5..30ns。数据有效条件为100pF/100kΩ；实际负载、边沿与供电需另验。

`configs/pdm_interface_timing.json` 的所有PCB和FPGA预算是设计假设，不是实测：CLOCK寄存器到pad最大10ns，CLK走线0..3ns，DATA走线0..3ns，DATA pad到采样D最大5ns；FF setup/hold各预留2ns，时钟相对偏斜/抖动预留2ns。CLOCK路径预算必须包含clk-to-Q；Vivado具体路径报告需检查该项，若报告不含它则应从10ns预算扣除实际clk-to-Q后再验收。2ns的时钟偏斜假设也必须用实际时钟路径验证。

最坏setup：125−10−3−100−3−5−2−2=0ns。

保守hold：200+0+5+0−125−2−2=76ns。高阻开始即不再计入数据保证；不靠线容维持旧电平取得余量。A/B使用相同公式。0ns剩余余量仅表示预算边界，不能解读为有裕量的硬件PASS。增加1ns未预算延迟即失败。

源码XDC用 `set_max_delay -datapath_only` 显式限制输入pad至所有可达寄存器及输出CLOCK路径。输入包括A的phase_a_q与B的CIC bit_q；A保持至CIC的内部路径仍按40MHz正常检查。移除了原来的整条PDM false_path，也未设置multicycle。注意AMD UG903明确规定datapath_only会关闭STA hold检查；这里的hold是外部窗口解析证明，min报告仅作诊断，不能当作hold STA通过。此方法不依赖 `set_input_delay` 的全周期源边沿假设，避免把半周期高阻窗口错误建模为整周期保持。

## 生成与验收

`scripts/apply_pdm_constraints.tcl`仍是生成入口，12通道产生六线XDC；不得只改build目录。`python3 scripts/analyze_pdm_interface.py`生成双相位解析预算。布局布线后运行 `source scripts/report_pdm_interface.tcl; report_pdm_interface <out_dir>`，检查12个输入采样端点、max/min路径、CLOCK和例外覆盖。没有实际routed报告时，状态为UNVERIFIED_STA。只有完整报告满足分段预算、FF setup/hold与实际相对时钟偏斜预算后，才能声明条件STA通过；它仍不构成实际载板验收。

## 启动策略

生产默认等待2,000,000个40MHz周期（50ms，±0.2dB策略），随后排除四个CIC输出帧。第一对PDM位不进入积分器；最初不完整抽取组与麦启动过渡均在门控期间清除。首个raw valid高期间frame_cnt为0；下一拍计数递增且align valid有效，下游看到首组ID为1，保持原计数接口语义。后续1024拍一帧。每次复位/停用重新执行相同策略。前提是麦克风VDD在使能前已有效；PL没有电源监测输入，软件必须保证供电前提。此策略不宣称下游DC高通或整个声学系统已达到稳态。

PS诊断若在使能后的短窗口量FRAME_CNT，窗口可能仍在50ms门控内，此时读到0是预期。当前ps_pdm.c已增加有界首帧等待，再开始计数窗口；实际C程序通过host MMIO顺序测试。其NOP窗口仍非校准时间基准，不能据此精确测量采样率；真实PS耗时及等待预算还需实机确认。银行READY等待应覆盖启动及512帧填充时间。

仅独立诊断测试可显式将MIC_STARTUP_CYCLES和CIC_SETTLE_FRAMES都置0，以保留旧的原始数字输出语义。此模式不用于声学采集或硬件验收。

## 相位与算法

200ns是FPGA两次采样的数字时间差，不直接等于实际声学通道延迟。正常PCM帧同拍，66对索引不变；生产坐标和channel_to_mic保护门保持。只能用TEST_ONLY实验研究偏差，未经实测不得写死补偿。缺麦的tri0仿真不代表真实线容会在200ns内放电，frozen不是电气冲突/断线的可靠检测器。

参考：[AMD UG903：datapath_only及hold行为](https://docs.amd.com/r/2023.1-English/ug903-vivado-using-constraints/Consequences-of-Setting-Maximum-Delay-or-Minimum-Delay-Constraints-on-a-Path)。
