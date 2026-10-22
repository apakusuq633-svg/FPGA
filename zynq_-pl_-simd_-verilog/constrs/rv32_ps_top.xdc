# rv32_ps_top 的约束：没有引脚，只约束时钟和异步输入。
#
# 这个文件给"单独综合 rv32_ps_top 做时序评估"用，和 rv32_synth_top.xdc 同一用途。
# 走 block design 时不用它：那时工程的顶层是 BD 的 wrapper，clk_i 由 PS7 的
# FCLK_CLK0 驱动，时钟由 BD 自己的约束描述，这里再来一条 create_clock 会重复。

# 与 create_zynq_project.tcl 里 FCLK_CLK0 的配置保持一致（40MHz）。
# 改频率时两处一起改：这里留 100MHz 会让单独综合的结果和实际工程对不上。
create_clock -name clk_i -period 25.000 -waveform {0 12.5} [get_ports clk_i]

# 外部复位是异步的，不参与建立/保持分析。
set_false_path -from [get_ports rst_n_i]

# 调试输出（retire_*）与中断输出在单独综合时不分配引脚。
# 降级 UCIO-1 让 implementation 能跑完出时序数字。
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
