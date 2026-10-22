# rv32_synth_top（综合/时序评估用顶层）的约束：没有引脚，只约束时钟和异步输入。
# 缺了 create_clock，时序报告里所有路径都是 unconstrained，等于没做时序分析。

create_clock -name clk_i -period 8.000 -waveform {0 4} [get_ports clk_i]

# 异步复位和 DFT 旁路都不参与建立/保持分析。
set_false_path -from [get_ports rst_n_i]
set_false_path -from [get_ports test_en_i]

# retire_* 是调试输出，本顶层不分配引脚。降级 UCIO-1 让 implementation 能跑完出时序数字。
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
