# 上板顶层 rv32_board_top 的引脚约束：正点原子领航者 ZYNQ7010（裸 PL，不依赖 PS）。
#
# 引脚值抄自正点原子官方的 NAVIGATOR_ZYNQ_IO.xdc（那份是 GBK 编码，不要直接拷进来跑，
# 见文件末尾说明）。顶层端口只有 5 个，全是本设计真正用到的：
#
#   clk_i   U18          系统时钟，50MHz。核的关键路径约 15.36ns（上限约 65MHz），
#                        50MHz 留约 4.6ns 余量，不需要分频。
#   rst_n_i N16          sys_rst_n，专用系统复位，低有效。直接接，不反相。
#   led_o   H15/L15/J16  PL_LED：底板 led[0]/led[1] + 核心板 led，全板就这 3 个，高电平点亮。
#
# ⚠ 别照抄 Zybo Z7 的 M14/M15/G14/P14/D18：在领航者上那四个脚分别是蜂鸣器、PL_UART 的 txd、
# ATK MODULE 的 gbc_key、以太网 eth_txd[0]，烧进去会去怼那些外设。

# Zynq 配置引脚，缺这两行 bitstream 生成会报 CFGBVS/CONFIG_VOLTAGE 未设置。
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# 板上 50MHz 晶振（官方 create_clock -period 20.000）。缺了它时序报告全是 unconstrained。
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports clk_i]
create_clock -name clk_i -period 20.000 -waveform {0 10} [get_ports clk_i]

# 复位来自按键，异步人手输入：不参与建立/保持分析，只约束引脚。
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports rst_n_i]
set_false_path -from [get_ports rst_n_i]

# 3 个 LED。方括号必须用花括号包住：写成 [get_ports led_o[0]] 会被 Tcl 当成命令替换。
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports {led_o[0]}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} [get_ports {led_o[1]}]
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS33} [get_ports {led_o[2]}]

# 这里不放 set_property SEVERITY {Warning} [get_drc_checks UCIO-1]：
# 5 个端口全部有脚，没有未约束的端口，降级反而会掩盖以后真出现的悬空。
#
# 官方 NAVIGATOR_ZYNQ_IO.xdc 放同目录当参考没问题 —— create_vivado_project.tcl 只加载
# constrs/<顶层名>.xdc，别的文件名是惰性的。但别把它加进构建：它给 LCD/HDMI/摄像头/
# 以太网等本设计没有的端口写 set_property，会刷一屏 "no objects matched" 的 critical warning。
