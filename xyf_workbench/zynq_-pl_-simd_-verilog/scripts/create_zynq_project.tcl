# 一键建立 Zynq-7010 的 PS-PL 工程：PS7 + AXI Interconnect + rv32_ps_top（模块引用）。
#
# 用法（二选一）：
#   * Vivado 菜单 Tools -> Run Tcl Script...，选本文件；
#   * 或命令行：vivado -mode batch -source scripts/create_zynq_project.tcl
#
# 与 create_vivado_project.tcl 的分工：那个建的是"裸 PL"工程（顶层 rv32_synth_top /
# rv32_board_top，没有 PS），本脚本建的是带 PS7 的异构工程。两者都读同一份
# scripts/filelist.f，工程目录不同（vivado_zynq / vivado），可以并存。
#
# 注意：会在 <工程根>/vivado_zynq 下重建工程，该目录已存在时会被覆盖。
#
# 约定：**要打印出来的字符串一律写 ASCII**。Tcl 在这台机器上按 cp936 读源码，
# 字符串里的中文会被解成乱码（本文件自己踩过：报错信息打出来是 "PS7 娌℃湁 ..."，
# 完全没法读）。注释用中文没问题 —— 注释不输出，编辑器按 UTF-8 显示是正常的。

set root [file normalize [file join [file dirname [info script]] ..]]

set part       "xc7z020clg400-1"
set proj_dir   [file join $root build das8_zynq]
if {[info exists ::env(ZYNQ_PROJ_DIR)]} {
    set proj_dir [file normalize $::env(ZYNQ_PROJ_DIR)]
}
set proj_name  rv32_zynq
set bd_name    ps_pl

# 板卡文件探测。**在领航者上这里一定会落到 part 模式**：探测的是 Digilent 的 Zybo，
# 而板子是正点原子的，Digilent 不会有它的板卡文件。
# 落 part 模式本身不影响 PS7 —— DDR/MIO 那些不是"引脚约束"，而是 PS7 的配置，
# 现在由 scripts/ps7_config.tcl 从厂商例程导进来（见下面 apply_ps7_config）。
# 这段探测保留着，是为了万一以后换了 Digilent 的板子还能自动吃到 preset。
set board_part ""
foreach candidate {"digilentinc.com:zybo-z7-10:part0:1.1" "digilentinc.com:zybo-z7-10:part0:1.0"} {
    if {$board_part eq "" && [lsearch -exact [get_board_parts] $candidate] >= 0} {
        set board_part $candidate
    }
}

# ---- 从 scripts/filelist.f 读清单，保持单一来源 ----
set rtl_files {}
set fp [open [file join $root scripts filelist.f] r]
foreach line [split [read $fp] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    if {[string match "tb/*" $line]} { continue }
    lappend rtl_files [file join $root $line]
}
close $fp

# Opt-in isolated RAM experiment; the default production file list is unchanged.
if {[info exists ::env(PDM_RAM_EXPERIMENT_OVERLAY)]} {
    set overlay [file normalize $::env(PDM_RAM_EXPERIMENT_OVERLAY)]
    if {![file isdirectory $overlay]} {error "Missing experiment overlay"}
    set replacements {}
    foreach path $rtl_files {
        set tail [file tail $path]
        if {$tail in {rv32_srp_scan.v rv32_overlap_localizer.v}} {
            set path [file join $overlay $tail]
            if {![file exists $path]} {error "Missing RAM experiment source $tail"}
            lappend replacements $tail
        }
        lappend experiment_files $path
    }
    if {[llength $replacements]!=2} {error "Incomplete RAM experiment substitution"}
    set rtl_files $experiment_files
    puts "PDM_RAM_EXPERIMENT_OVERLAY $overlay production_sources_unchanged=1"
}

# ---- 建工程 ----
if {$board_part ne ""} {
    puts "==> Using board preset: $board_part"
    create_project $proj_name $proj_dir -part $part -force
    set_property board_part $board_part [current_project]
} else {
    puts "==> No Digilent Zybo board file; using plain part mode (expected on Navigator)."
    puts "==>     PS7 DDR/MIO config comes from scripts/ps7_config.tcl; no board file needed."
    create_project $proj_name $proj_dir -part $part -force
}

# RTL 进综合集。没有 PS 的两个顶层（rv32_synth_top / rv32_board_top）都由脚本生成、
# 不在 filelist.f 里，所以这里不会混进用不上的模块。
add_files -norecurse $rtl_files
set lagrange_header [file join $root rtl beamformer das_lagrange_coeff.vh]
add_files -norecurse $lagrange_header
set_property file_type {Verilog Header} [get_files $lagrange_header]
set_property include_dirs [list [file join $root rtl]] [current_fileset]

# ROM 预装的绝对路径（相对路径在 run 目录下找不到，见 rom_preload.tcl 头部）
source [file join $root scripts rom_preload.tcl]

# rv32_defines.vh 必须显式进 fileset 并标成 Verilog Header。裸 PL 工程里只用
# include_dirs 就够了（create_vivado_project.tcl 就没加它），但 create_bd_cell
# -type module 解析 `include 时会检查头文件有没有归属的 fileset，不加会报
# HDDASrcFileProxy。
set vh_file [file join $root rtl rv32_defines.vh]
add_files -norecurse -fileset sources_1 $vh_file
set_property file_type "Verilog Header" [get_files $vh_file]

update_compile_order -fileset sources_1

# ---- block design ----
create_bd_design $bd_name

# PS7：开 M_AXI_GP0 给控制面，开 FABRIC_INTERRUPT 收 PL 的中断。
#
# FCLK_CLK0 配 40MHz，不是 50MHz —— 核自己的关键路径就要 19.6 ns，50MHz（20 ns 周期）下
# 实测余量只剩 +0.105 ns，而且扫 5 个 impl strategy 有 3 个直接违例，设计卡在临界点上。
#   * 路径在核内部：EX/MEM → 前递 mux → M 扩展乘法器（2 个 DSP48E1 级联 + 进位链）→ EX/MEM。
#     AXI 和寄存器堆不在路径上；DTCM 的 BRAM 也不在（那是扩 TCM 后一度冒出来的新瓶颈，
#     被下面的 NetDelay_high 挪走了）。
#   * 40MHz（25 ns）实测 WNS **+1.749 ns**。注意这不是"0.105 + 5"：摆放器有了余量就不再
#     拼命优化，同一条路径从 19.6 ns 长到 22.9 ns（布线 9.9 → 12.5 ns），把多出来的空间
#     拿去做更好布的通路。所以这 +1.749 是**工具主动留在桌上的**，不是已经用满了 ——
#     后面加逻辑时它还会再挤一挤。
#   * **那个 +1.749 是 09-18 那版 RTL 的数**（d7eaa84）。此后 OP-V / 阵列 / 定位加速器
#     陆续进网表，当前 RTL 复测为 **+2.238 ns**（2026-09-20，同一路径
#     22.441 ns，逻辑 10.641 / 布线 11.800，28 级；WHS +0.020、WPWS +11.520，0 违例端点）。
#     两天之间 RTL 换了几版，所以这 0.489 ns 的差**既可能是摆放也可能是版本差** ——
#     无论哪种都不能当预算花，见 README「时序与 FCLK 频率」。
#   * 代价只有吞吐：48kHz 的样本预算从 1041 拍变 833 拍，而路线图里 MAC 阵列只占 1%
#     （README「加速器方案选型」）—— 对落地顺序没有影响。降频比动乘法器结构便宜得多，
#     后者要复制 div 那套多拍机制，还会推翻 README 里"mul 单拍出结果"这个架构决定。
#   * 想把频率提回去，前提是先结构性缩短乘法器那条路径（见 rv32_mul_unit.v 头部）。
set fclk_mhz 40
set stream_dma_enabled 0
if {[info exists ::env(PDM_STREAM_DMA)]} {
    if {$::env(PDM_STREAM_DMA) ni {0 1}} {error "PDM_STREAM_DMA must be 0 or 1"}
    set stream_dma_enabled $::env(PDM_STREAM_DMA)
}

create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 u_ps7

# 先整套套上厂商的 PS7 配置：DDR 型号/时序、MIO 分配、时钟全在里面。
# 不套的话 PS7 是默认配置 —— DDR 型号和 MIO 分配都不对，DDR 跑不起来，裸机程序也没法
# 从 DDR 执行。来源与重新生成方式见 ps7_config.tcl 的文件头。
source [file join $root scripts ps7_config.tcl]
apply_ps7_config u_ps7

# 再按本设计的需要覆盖 PL 侧那几项。
#
# **必须在 apply_ps7_config 之后**：厂商那个例程（1_hello_world）是纯 PS 的，下面这几项
# 在它里面**全是 0**，包括 EN_CLK0_PORT 和 EN_RST0_PORT —— 漏掉任何一项，对应的 PS7 引脚
# 根本不会被创建，后面 connect_bd_net 会报 "No pins matched"（那条错误完全看不出是
# 配置没开）。所以下面紧接着有一道前置检查专门盯这个。
set_property -dict [list \
    CONFIG.PCW_EN_CLK0_PORT             {1} \
    CONFIG.PCW_EN_RST0_PORT             {1} \
    CONFIG.PCW_USE_M_AXI_GP0            {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT     {1} \
    CONFIG.PCW_IRQ_F2P_INTR             {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz \
] [get_bd_cells u_ps7]

if {$stream_dma_enabled} {
    set_property -dict [list CONFIG.PCW_USE_S_AXI_HP0 1 CONFIG.PCW_S_AXI_HP0_DATA_WIDTH 64] [get_bd_cells u_ps7]
}

# ---- I2C0 routed to PL via EMIO (comes from the PS side) ----
#
# The board I2C bus (EEPROM / RTC) has its SCL/SDA on E18/F17, which are PL
# bank pins, while the PS I2C0 hard core has no MIO pin assigned. So the only route is
# via EMIO into the PL, then out through a PL IOBUF.
#
# All four items below must be overridden explicitly, and must come AFTER
# apply_ps7_config: the vendor preset sets every one of them to 0 (ps7_config.tcl
# writes {0} for them at lines 64 / 85 / 127) -- they are not merely "unset", they are
# actively disabled.
#   EN_I2C0                -> enable the I2C0 peripheral
#   I2C0_PERIPHERAL_ENABLE -> enable I2C0 pins/interface
#   I2C0_I2C0_IO = EMIO    -> move the pins from MIO to EMIO
#   EN_EMIO_I2C0           -> generate the u_ps7/IIC_0 bus interface
#
# WARNING: if any one of them is missed, u_ps7/IIC_0 does not exist at all (in
#   component.xml the enablement condition for the IIC_0 interface IS
#   PCW_EN_EMIO_I2C0), and make_bd_intf_pins_external later fails with
#   "Arguments ... cannot be empty" -- a message that gives no hint that a config item
#   is missing. There is a dedicated check for it right below.
#
# Kept as a separate -dict rather than merged into the group above: if one I2C value
# were rejected, a merged group would roll back as a whole, silently taking the six PL
# overrides with it, which is hard to debug.
#
# NOTE: enabling EMIO I2C0 has a side effect -- I2C0's interrupt moves to EMIO as well
#   (PCW_I2C0_GRP_INT_ENABLE 0->1, PCW_I2C0_GRP_INT_IO -> EMIO), and that interrupt line
#   is not connected to anything in the BD. Nothing in this project drives the bus, so
#   the side effect is inert; it is recorded here because it would bite the first program
#   that does (it would have to use the polled APIs, never interrupt mode).
#
# WARNING: another side effect -- the I2C input clock PCW_I2C_PERIPHERAL_FREQMHZ goes
#   from 25 to 111.111115 (CPU_1x = CPU clock / 6). That is NOT on FCLK_CLK0, so
#   changing fclk_mhz does not move the I2C SCL frequency. Verify it with the
#   SCL-back-calculation print in the PS program (expect CR=3700 / SCL=90187Hz).
set_property -dict [list \
    CONFIG.PCW_EN_I2C0                 {1} \
    CONFIG.PCW_I2C0_PERIPHERAL_ENABLE  {1} \
    CONFIG.PCW_I2C0_I2C0_IO           {EMIO} \
    CONFIG.PCW_EN_EMIO_I2C0            {1} \
] [get_bd_cells u_ps7]

# ---- PS Ethernet (GEM0) on MIO16-27, MDIO on MIO52-53 ----
#
# Station 15 (sw/ps_ui.c) serves the diagnosis over HTTP through the PS Ethernet
# port, so GEM0 has to be on. The vendor preset is a *pure PS* example and has it
# off (ps7_config.tcl writes {0} at lines 92 / 133) with no MIO assigned to it --
# not "unset", actively disabled.
#
# Values are taken verbatim from the vendor's own Ethernet example for this board
# (40_lwip_echo_server, ZYNQ_Vitis_7020.rar), not invented:
#   ENET0 = RGMII on MIO 16..27, 1.8V, pull-up enabled, slew fast
#   MDIO  = MIO 52..53,         1.8V, pull-up enabled, slew slow
#   1000 Mbps; ENET0_PERIPHERAL_CLKSRC is already IO PLL in ps7_config.tcl, so it
#   is not repeated here.
#
# Only these peripheral-level items are written: Vivado recomputes the two 54-entry
# MIO map strings (PCW_MIO_TREE_PERIPHERALS / _SIGNALS) from them. Verified with
# build/scratch/probe_enet_ps7.tcl -- after applying exactly this dict it reads back
# "Enet 0 / tx_clk .. rx_ctl" on MIO16-27 and "Enet 0 / mdc, mdio" on MIO52-53, and
# validate_bd_design passes. Hand-writing those trees is unnecessary and is the kind
# of thing that goes stale silently.
#
# WARNING: unlike the I2C0 case above there is nothing to check with get_bd_pins --
#   GEM0 pinned to MIO exposes no port on the BD at all (confirmed in the same probe).
#   So a mistake can only be caught by reading the property back, which the check
#   below does. If EN_ENET0 does not read back 1, the xemacps base address silently
#   disappears and lwIP fails in init -- on hardware only.
#
# Both MIO ranges are all-unassigned in ps7_config.tcl, so this takes no pin away
# from anything else in the design.
set_property -dict [list \
    CONFIG.PCW_EN_ENET0                  {1} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE   {1} \
    CONFIG.PCW_ENET0_ENET0_IO            {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ  {1000 Mbps} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE     {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO         {MIO 52 .. 53} \
    CONFIG.PCW_MIO_16_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_16_PULLUP {enabled} \
    CONFIG.PCW_MIO_16_SLEW   {fast} \
    CONFIG.PCW_MIO_17_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_17_PULLUP {enabled} \
    CONFIG.PCW_MIO_17_SLEW   {fast} \
    CONFIG.PCW_MIO_18_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_18_PULLUP {enabled} \
    CONFIG.PCW_MIO_18_SLEW   {fast} \
    CONFIG.PCW_MIO_19_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_19_PULLUP {enabled} \
    CONFIG.PCW_MIO_19_SLEW   {fast} \
    CONFIG.PCW_MIO_20_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_20_PULLUP {enabled} \
    CONFIG.PCW_MIO_20_SLEW   {fast} \
    CONFIG.PCW_MIO_21_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_21_PULLUP {enabled} \
    CONFIG.PCW_MIO_21_SLEW   {fast} \
    CONFIG.PCW_MIO_22_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_22_PULLUP {enabled} \
    CONFIG.PCW_MIO_22_SLEW   {fast} \
    CONFIG.PCW_MIO_23_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_23_PULLUP {enabled} \
    CONFIG.PCW_MIO_23_SLEW   {fast} \
    CONFIG.PCW_MIO_24_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_24_PULLUP {enabled} \
    CONFIG.PCW_MIO_24_SLEW   {fast} \
    CONFIG.PCW_MIO_25_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_25_PULLUP {enabled} \
    CONFIG.PCW_MIO_25_SLEW   {fast} \
    CONFIG.PCW_MIO_26_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_26_PULLUP {enabled} \
    CONFIG.PCW_MIO_26_SLEW   {fast} \
    CONFIG.PCW_MIO_27_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_27_PULLUP {enabled} \
    CONFIG.PCW_MIO_27_SLEW   {fast} \
    CONFIG.PCW_MIO_52_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_52_PULLUP {enabled} \
    CONFIG.PCW_MIO_52_SLEW   {slow} \
    CONFIG.PCW_MIO_53_IOTYPE {LVCMOS 1.8V} \
    CONFIG.PCW_MIO_53_PULLUP {enabled} \
    CONFIG.PCW_MIO_53_SLEW   {slow} \
] [get_bd_cells u_ps7]

# 把本设计要用的四个 PS7 引脚查一遍再往下走。
# 意义：厂商那整套配置会把 PL 相关端口全关掉，上面 override 若漏了哪一项，这里会以
# 一句能读懂的话报出来，而不是等到 connect_bd_net 报 "No pins matched"。
#
# 分两组查，因为 M_AXI_GP0 是 AXI **接口**引脚（.bd 里它属于 interface_ports），
# 只能用 get_bd_intf_pins；另外三个是普通引脚。这里踩过一次：全用 get_bd_pins，
# 结果 M_AXI_GP0 永远查不到，白白误报了一次"配置有问题"。
#
# 只警告不中断：这是给人看的诊断，不该有能力搞砸构建。真缺引脚的话，下面的
# connect_bd_net 照样会报 No pins matched —— 但那时你已经看到病因了。
set missing {}
foreach p {FCLK_CLK0 FCLK_RESET0_N IRQ_F2P} {
    if {[llength [get_bd_pins -quiet u_ps7/$p]] == 0} { lappend missing $p }
}
if {[llength [get_bd_intf_pins -quiet u_ps7/M_AXI_GP0]] == 0} { lappend missing "M_AXI_GP0 (interface)" }

if {[llength $missing] > 0} {
    puts "==> WARNING: PS7 is missing these ports: $missing"
    puts "==>          Check the override block above: EN_CLK0_PORT -> FCLK_CLK0,"
    puts "==>          EN_RST0_PORT -> FCLK_RESET0_N, USE_M_AXI_GP0 -> M_AXI_GP0,"
    puts "==>          USE_FABRIC_INTERRUPT + IRQ_F2P_INTR -> IRQ_F2P."
    puts "==>          (They are all 0 in the vendor's pure-PS preset, so every one of"
    puts "==>           them must be re-enabled there.)"
} else {
    puts "==> PS7 ports OK: FCLK_CLK0 / FCLK_RESET0_N / M_AXI_GP0 / IRQ_F2P"
}

# GEM0 has no port to inspect (see the note above), so it gets its own read-back.
# Station 15 needs it; without this the only symptom would be lwIP failing to init
# on the board, with nothing in the build log to point at.
if {[get_property CONFIG.PCW_EN_ENET0 [get_bd_cells u_ps7]] ne "1"} {
    puts "==> WARNING: PS Ethernet (GEM0) is NOT enabled -- the override above did not take."
    puts "==>          sw/ps_ui.c cannot work: lwip's xemacps init will fail at runtime."
} else {
    puts "==> PS7 GEM0 OK: ENET0 enabled on MIO16-27 (RGMII) + MIO52-53 (MDIO)"
}

# ---- Externalize I2C0: bring u_ps7/IIC_0 out to the BD top level ----
#
# Why not create an IIC port with create_bd_intf_port: on 2020.2 it cannot be created --
#   CRITICAL WARNING: [BD 41-52]  Could not find the abstraction definition specified by
#                                the vlnv: xilinx.com:interface:iic:1.0
#   CRITICAL WARNING: [BD 41-181] Interface port 'iic_0' cannot be created
# Both are CRITICAL WARNINGs, not exceptions => catch cannot see them, the port is
# silently not created, and the failure only surfaces at the later connect_bd_intf_net,
# whose message gives no hint of the real cause. (The VLNV is not mistyped: it is
# declared exactly like that in data/ip/interfaces/iic_v1_0/iic.xml. It is a BD
# directory lookup problem.)
#
# make_bd_intf_pins_external bypasses the VLNV lookup, and it connects the pin to the
# new port by itself => this branch needs no connect_bd_intf_net.
#
# WARNING: its RETURN VALUE IS EMPTY (measured on 2020.2). Testing it would report a
#   false failure (the first version of this script did exactly that: the port was
#   created fine, yet the script reported ERROR). So only check that the pin exists.
#
# The port name is auto-generated: pin IIC_0 -> BD port IIC_0_0 -> wrapper pins
# IIC_0_0_scl_io / IIC_0_0_sda_io. It is deliberately NOT renamed (set_property name
# fails, and whether the rename sticks decides which name goes into the XDC -- which
# would only add uncertainty).
#
# This one uses error and aborts, unlike the "warn only" PS7 check above: a missing PS7
# pin makes connect_bd_net report "No pins matched" immediately, whereas a missing I2C
# is SILENT -- it drags all the way to bitstream DRC (NSTD-1 / UCIO-1) ten-plus minutes
# later. Here it fails in one minute.
if {[llength [get_bd_intf_pins -quiet u_ps7/IIC_0]] == 0} {
    error "u_ps7/IIC_0 not found -- the 4 PCW I2C CONFIG items above did not take effect. Check EN_I2C0 / I2C0_PERIPHERAL_ENABLE / I2C0_I2C0_IO=EMIO / EN_EMIO_I2C0. ps7_config.tcl sets all four to 0, so they MUST be overridden after apply_ps7_config."
} else {
    make_bd_intf_pins_external [get_bd_intf_pins u_ps7/IIC_0]
    puts "==> I2C0 externalized (pin IIC_0 -> BD port IIC_0_0)"
}

# DDR 和 FIXED_IO 引到顶层（顶层是 BD 的 wrapper，不是 rv32_ps_top）。
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config { \
    make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable" \
} [get_bd_cells u_ps7]

# rv32_ps_top 作为模块引用加进 BD。Vivado 会从 s_axi_* 端口名自动推断出 AXI4-Lite
# 接口。时钟端口叫 clk_i 而不是 s_axi_aclk，本来推断不出关联时钟 —— 但下面那行
# FREQ_HZ 设对之后就自动关联上了，不需要给顶层起别名、也不需要 ASSOCIATED_BUSIF。
create_bd_cell -type module -reference rv32_ps_top u_rv32_ps
if {![info exists ::env(DAS_ACTIVE_CHANNELS)]} { set ::env(DAS_ACTIVE_CHANNELS) 8 }
set pdm_line_count [expr {$::env(DAS_ACTIVE_CHANNELS) >= 8 ? ($::env(DAS_ACTIVE_CHANNELS)+1)/2 : 8}]
if {[info exists ::env(DAS_ACTIVE_CHANNELS)]} {
    if {$::env(DAS_ACTIVE_CHANNELS) ni {8 9}} { error "Supported profiles: planar8 or circular9" }
    set_property CONFIG.DAS_ACTIVE_CHANNELS $::env(DAS_ACTIVE_CHANNELS) [get_bd_cells u_rv32_ps]
    if {$::env(DAS_ACTIVE_CHANNELS) >= 8} {
        set live16_localization 1
        if {[info exists ::env(LIVE16_LOCALIZATION)]} {
            if {$::env(LIVE16_LOCALIZATION) ni {0 1}} { error "LIVE16_LOCALIZATION must be 0 or 1" }
            set live16_localization $::env(LIVE16_LOCALIZATION)
        }
        set_property CONFIG.LIVE16_LOCALIZATION $live16_localization [get_bd_cells u_rv32_ps]
        puts "==> $::env(DAS_ACTIVE_CHANNELS) microphone SRP: localization=$live16_localization / 1024 cells"
        set_property CONFIG.PDM_CHANNELS [expr {2*$pdm_line_count}] [get_bd_cells u_rv32_ps]
        set_property CONFIG.PDM_MICS_PER_LINE 2 [get_bd_cells u_rv32_ps]
    }
}

# PS 的 M_AXI_GP0 接到从端，interconnect 由自动化规则生成。
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config { \
    Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto} \
    Master "/u_ps7/M_AXI_GP0" Slave "/u_rv32_ps/s_axi" \
    intc_ip {New AXI Interconnect} master_apm {0} \
} [get_bd_intf_pins u_rv32_ps/s_axi]

# 时钟、复位、中断。
connect_bd_net [get_bd_pins u_ps7/FCLK_CLK0]        [get_bd_pins u_rv32_ps/clk_i]
# External N16 active-low button and PS reset both reset PL.
create_bd_port -dir I -type rst rst_n
set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports rst_n]
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 u_pl_reset_and
set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] [get_bd_cells u_pl_reset_and]
connect_bd_net [get_bd_pins u_ps7/FCLK_RESET0_N] [get_bd_pins u_pl_reset_and/Op1]
connect_bd_net [get_bd_ports rst_n] [get_bd_pins u_pl_reset_and/Op2]
connect_bd_net [get_bd_pins u_pl_reset_and/Res] [get_bd_pins u_rv32_ps/rst_n_i]
connect_bd_net [get_bd_pins u_rv32_ps/irq_o]        [get_bd_pins u_ps7/IRQ_F2P]

# LED 出顶层。固件写核侧 MMIO 0x5000 → led_o[2:0] → 引脚，约束在 constrs/ps_pl_wrapper.xdc。
#
# 用显式 create_bd_port 而不是 make_bd_pins_external：后者自动起名，撞名时会加后缀
# （led_o_0 之类），XDC 里的 get_ports 就对不上了，而且是静默不约束。
# -from 是 MSB、-to 是 LSB，这里生成 output [2:0] led_o（领航者全板 3 个 PL LED）。
#
# 宽度靠 LED_WIDTH 的默认值 3 推出来 —— 改 rv32_ps_top 的参数默认值就必须重跑本脚本，
# 否则引脚宽度和 BD 端口对不上，validate_bd_design 会报宽度不匹配。
create_bd_port -dir O -from 2 -to 0 led_o
connect_bd_net [get_bd_pins u_rv32_ps/led_o] [get_bd_ports led_o]
# Navigator V3.4: J3 pin 25 = B34_L20_N = R18 (shared with RGB LCD G3).
# 原在 J3.11/N18，挪过来是为了和麦克风阵列共用那根 2x8 IDC —— J3 只有 37/39 两个 GND，
# 被阵列块全占了。管脚表与待实测项见 docs/board_io.md。
create_bd_port -dir I tacho_i
connect_bd_net [get_bd_ports tacho_i] [get_bd_pins u_rv32_ps/tacho_i]

# ---- PDM 麦阵列引脚（9 根：1 根共享时钟 + 8 根数据）----
# 约束在 constrs/ps_pl_wrapper.xdc 末尾，线序表见 docs/board_io.md §8。
#
# ⚠ 漏掉这一段**不会报错**，只会打一条 CRITICAL WARNING：
#     [BD 41-759] /u_rv32_ps/pdm_din_i 没接、也没 tie-off
#   然后**把输入 tie 成 0** —— 综合照样过、位流照样出，
#   上板现象是「麦一点反应都没有」，而 RTL、TB、约束全都是对的。
#   （这正是第一版漏掉时的实测现象，见 docs/issues/051。）
#
# pdm_din_i 是 8 位，**必须写 -from 7 -to 0**：-from 是 MSB、-to 是 LSB（与 led_o 同规矩）。
# 写成 -from 8 -to 1 会得到 [8:1]，而 xdc 约束的是 [7:0]，两边静默对不上。
create_bd_port -dir O pdm_clk_o
connect_bd_net [get_bd_pins u_rv32_ps/pdm_clk_o] [get_bd_ports pdm_clk_o]

create_bd_port -dir I -from [expr {$pdm_line_count-1}] -to 0 pdm_din_i
connect_bd_net [get_bd_ports pdm_din_i] [get_bd_pins u_rv32_ps/pdm_din_i]

# 模块引用的 AXI 接口带一个 FREQ_HZ=100MHz 的默认值，FCLK 一旦不是 100MHz 就会撞上
# [BD 41-237] FREQ_HZ 不匹配（接口 100MHz 对互联 50MHz）。默认值恰好是 100 时不暴露，
# 所以这行是改频率的必备项。注意只能设在接口引脚上：时钟引脚上的 FREQ_HZ/CLK_DOMAIN
# 是派生属性，写了会报 "parameter does not exist" 或不持久。
set_property CONFIG.FREQ_HZ [expr {$fclk_mhz * 1000000}] [get_bd_intf_pins u_rv32_ps/s_axi]

assign_bd_address

# 把从端地址钉死。不钉的话 assign_bd_address 会从 0x40000000 起自动分配，重建一次工程
# 就可能变，Vitis 那边的 RV32_BASE 就得跟着改 —— 这种"换个地址就要重编软件"的坑没必要留。
#
# -target_address_space 不能省：只给 -offset/-range 时报 [BD 5-669]，而且那是 ERROR。
# 这一句以前就死在这个错上（catch 吞掉之后继续跑），连带 -range 4K 也没落地，
# BD 里留下的是自动分配给的 64K。本设计只有一个主地址空间：u_ps7/Data。
#
# -range 必须 4K，不能 64K：rv32_ps_top 的 s_axi_*addr 硬写 [11:0]，从端 ADDR_WIDTH=12。
# 给 64K 时访问 0x43C01000 会被互联正常路由进来、从端把高 4 位丢掉，**静默命中同一个
# 寄存器**（拿到正常应答而不是 SLVERR）。将来要加宽窗口，这四处必须一起改，只改这里会
# 静默别名：rv32_ps_top 的 s_axi_*addr 位宽 / rv32_axi_lite_slave.ADDR_WIDTH /
# rv32_ps_regs.ADDR_WIDTH / 这里的 -range。
#
# 用 catch 包住：万一片选路径的写法不对，也只是没钉住，不该让整个 BD 建不起来。
set rv32_offset 0x43C00000
if {[catch {
    assign_bd_address -target_address_space [get_bd_addr_spaces u_ps7/Data] \
        -offset $rv32_offset -range 4K -force \
        [get_bd_addr_segs u_rv32_ps/s_axi/reg0]
} err]} {
    puts "==> NOTE: could not pin the slave at $rv32_offset ($err)"
    puts "==>       Use the actual offset printed at the end as RV32_BASE in sw/ps_main.c"
} else {
    puts "==> Slave pinned at $rv32_offset (range 4K) -- use it as RV32_BASE"
}

source [file join $root scripts connect_stream_dma.tcl]

validate_bd_design
save_bd_design

puts "==> BD validated (FCLK_CLK0 and s_axi both ${fclk_mhz}MHz, no 41-967/41-237)"

# ---- 顶层换成 BD wrapper ----
set bd_file [get_files [file join $proj_dir $proj_name.srcs sources_1 bd $bd_name ${bd_name}.bd]]
make_wrapper -files $bd_file -top
add_files -norecurse [file join $proj_dir $proj_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- I2C port name self-check ----
# The two set_property lines in constrs/ps_pl_wrapper.xdc use the names
# IIC_0_0_scl_io / IIC_0_0_sda_io, which must match the wrapper EXACTLY. If they do not,
# Vivado only reports
#     WARNING:          [Vivado 12-584] No ports matched 'IIC_0_0_scl_io'.
#     CRITICAL WARNING: [Common 17-55] 'set_property' expects at least one object.
# Neither is an ERROR => the script keeps going, both pins end up unconstrained, and
# nothing is caught until bitstream DRC.
#
# This searches the wrapper file for the `inout <name>;` declaration instead of using
# get_ports: at this point in the script there is no elaborated design, so get_ports
# would always return nothing and produce a FALSE failure.
set iic_missing {}
set wrapper_v [file join $proj_dir $proj_name.gen sources_1 bd $bd_name hdl ${bd_name}_wrapper.v]
if {[catch {
    set fh  [open $wrapper_v r]
    set txt [read $fh]
    close $fh
    foreach sig {IIC_0_0_scl_io IIC_0_0_sda_io} {
        if {![regexp "inout\\s+$sig\\s*;" $txt]} { lappend iic_missing $sig }
    }
} err]} {
    puts "==> WARNING: could not read $wrapper_v ($err); I2C port names unchecked"
} else {
    if {[llength $iic_missing] > 0} {
        error "wrapper is missing $iic_missing -- constrs/ps_pl_wrapper.xdc uses these exact names, so those pins would end up unconstrained (silently) and only fail at bitstream DRC."
    } else {
        puts "==> I2C wrapper ports OK: IIC_0_0_scl_io / IIC_0_0_sda_io"
    }
}
# tacho 这一条以前是缺的：I2C 有自检，tacho 没有，于是它的端口名写错会
# 一路静默到 bitstream DRC（十几分钟），而不是在这里一分钟内报出来。
# ⚠ 加新引脚（比如麦克风阵列那 6 根）时，这里也要照着加一段 —— 否则就是同一个缺口。
set tacho_missing {}
if {[catch {
    set fh  [open $wrapper_v r]
    set txt [read $fh]
    close $fh
    if {![regexp "input\\s+tacho_i\\s*;" $txt]} { lappend tacho_missing tacho_i }
} err]} {
    puts "==> WARNING: could not read $wrapper_v ($err); tacho port name unchecked"
} else {
    if {[llength $tacho_missing] > 0} {
        error "wrapper is missing $tacho_missing -- constrs/ps_pl_wrapper.xdc uses this exact name, so the pin would end up unconstrained (silently) and only fail at bitstream DRC."
    } else {
        puts "==> tacho wrapper port OK: 1 input"
    }
}

# PDM 那 9 根 —— 照上面那段注释的提醒补的（"加新引脚时这里也要照着加一段"）。
# 宽度也要核：XDC 里写的是 {pdm_din_i[7]} 这种**位选**，wrapper 里若声明成
# 别的宽度，位选要么越界、要么只约束到一部分，两种都只是 WARNING。
set pdm_missing {}
if {[catch {
    set fh  [open $wrapper_v r]
    set txt [read $fh]
    close $fh
    # ⚠ `\]` 与端口名之间**可能有也可能没有空格**：Vivado 生成的 wrapper 实际写的是
    #   `input [7:0]pdm_din_i;`（`led_o` 那行也是 `output [2:0]led_o;`）。
    #   写成 `\]\s+pdm_din_i` 会要求一个空格，于是**明明建出来了却报"缺端口"** ——
    #   自检拦下真问题之前，先得保证它自己不是假的。两种写法都用 `\s*` 兜住。
    if {![regexp "output\\s+pdm_clk_o\\s*;" $txt]} { lappend pdm_missing pdm_clk_o }
    set pdm_pattern [format {input\s+\[%d:0\]\s*pdm_din_i\s*;} [expr {$pdm_line_count-1}]]
    if {![regexp $pdm_pattern $txt]} { lappend pdm_missing "pdm_din_i width $pdm_line_count" }
} err]} {
    puts "==> WARNING: could not read $wrapper_v ($err); PDM port names unchecked"
} else {
    if {[llength $pdm_missing] > 0} {
        error "wrapper is missing $pdm_missing -- constrs/ps_pl_wrapper.xdc uses these exact names and widths, so those pins would end up unconstrained (silently) and only fail at bitstream DRC."
    } else {
        puts "==> PDM wrapper ports OK: pdm_clk_o (out) + $pdm_line_count DINs (in)"
    }
}

# ---- Constraints: LED + I2C pins ----
# The XDC below now holds two sections: the LED pins (above) and the I2C0/EMIO pair
# IIC_0_0_scl_io / IIC_0_0_sda_io (the PS-side addition).
# ---- 约束：LED 引脚 ----
# 本脚本每次都 create_project -force，在 GUI 里手动 Add Sources 加的约束下次跑就没了，
# 所以只能写进脚本。add_files -fileset constrs_1 就够：进了 constrs_1 就自动参与综合
# 与实现，不需要 set_property target_constrs_file（那是同一个 XDC 服务多个顶层才要），
# 也不需要 import_files。放在 make_wrapper 之后，端口名对不上时报错更靠后、更好读。
set xdc_file [file join $root constrs ps_pl_wrapper.xdc]
if {[file exists $xdc_file]} {
    source [file join $root scripts apply_pdm_constraints.tcl]
    apply_pdm_constraints $::env(DAS_ACTIVE_CHANNELS)
} else {
    puts "==> WARNING: $xdc_file not found; led_o will not be constrained to pins"
}

if {[info exists ::env(DAS_ACTIVE_CHANNELS)] && $::env(DAS_ACTIVE_CHANNELS) == 4} {
    source [file join $root scripts configure_debug4_pins.tcl]
}

# ---- 实现策略 ----
# 默认 strategy 下关键路径差 0.501ns（WNS -0.501 / TNS -5.440 / 19 个违例端点）。
# 下面这条是拿 5 个 strategy 实测比出来的，不是按名字挑的 —— 五个里有三个反而违例：
#   NetDelay_high +0.105 | ExplorePostRoutePhysOpt +0.014 | Explore -0.018
#   RefinePlacement -0.135 | ExtraTimingOpt -0.500
# NetDelay_high 是唯一既抬高 WNS、又把关键路径从 DTCM 的 BRAM 挪回核内的。
# 病因是摆放：TCM 扩到 16KB 后 8 片 BRAM 全落在器件的 X0/X1 两列（**7z010 只有这两条
# BRAM 列**），而消费它们的核逻辑在 SLICE_X23~X33，DTCM 出来那根线单根就要走 1.2ns。
#
# ⚠ **换到 7020 之后这一段的前提变了**：7z020 的 BRAM 列比 7z010 多，8 片 BRAM 不再
#   必然挤在同一对列上，摆放压力应当下降。但**这是推的，没有实测** ——
#   `synth_design` 在本机原生崩溃（docs/issues/039），量不了。
#   所以这条 strategy 暂时**保持不动**：它的代价只是跑得慢一点，
#   而在没有新数字之前换掉它，等于用一个猜测替换一个实测过的选择。
#   等 issue 039 解决、能跑通实现之后，**重跑五个 strategy 重新比一次**再决定去留。
#
# 注意上面这个 +0.105ns 是在 50MHz 下量的。fclk_mhz 现在已经是 40（见上文），周期 25ns，
# 实际余量约 5.4ns —— 所以选这条 strategy 主要是为了**让关键路径离开 DTCM 的 BRAM**，
# 而不是抠那 0.1ns。三个 strategy 直接违例也说明这块设计对摆放很敏感，改动后要复测。
set_property strategy Performance_NetDelay_high [get_runs impl_1]

# synth_1 的 strategy 这里**故意不设**：rv32 核在 BD 里是模块引用，走 OOC 独立综合
# （ps_pl_u_rv32_ps_0_synth_1，命令里没有 -directive），关键路径根本不在 synth_1 里。
# 实测把 synth_1 换成 Flow_PerfOptimized_high 对收敛没有任何作用。
#
# **2026-10-03：上面那句"要压核自己的路径得单独 reset 那个 OOC 子 run"现在做了。**
#   当时的判断是"那是另一件事"，而现在**关键路径恰恰就在核里**：
#     u_ex_mem_reg/u_payload_dff/q_o_reg[6] → …34 级… → q_o_reg[108]/D
#     Data Path Delay 25.404ns (logic 11.090 + **route 14.314，占 56%**)
#     Logic Levels 34 (CARRY4=12 **DSP48E1=2** LUT6=11 …)
#   这是工程注释里记的那条「EX/MEM → 前递 mux → **M 扩展乘法器（2 个 DSP48E1 级联）** → EX/MEM」，
#   09-20 实测 22.441 ns（布线 11.8）—— **逻辑几乎没变，涨的全是布线**。
#   物理手段已全部用尽（见 docs/issues/057/060）：4 个 impl strategy 全更差、
#   phys_opt/route 的 directive 档全更差、LUT 从 74.8% 压到 45.2% 对 WNS 毫无帮助。
#   ⇒ 剩下唯一没试的就是**换核自己的综合指令**：让综合器换一种方式实现那条乘法链
#     （输入/输出寄存器打包进 DSP、进位链重构）。合成 netlist 不同，物理优化才有东西可摆。
#
# ⚠ 代价：这会重综合核（OOC 子 run），约 20 分钟；且 netlist 变化要重跑全部 TB 复验。
# ⚠ 试过 `set_property strategy Flow_PerfOptimized_high` —— **不生效**：
#   它是 BD 模块引用的 OOC run，有自己的命令模板，runme.log 里那行 `synth_design`
#   照旧没有 `-directive`（实测 2026-10-03）。**要改的是步骤参数**，不是 strategy。
set core_ooc [get_runs -quiet ps_pl_u_rv32_ps_0_synth_1]
if {$core_ooc ne ""} {
    if {[catch {
        set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized $core_ooc
    } e]} {
        puts "==> ⚠ 核的 OOC DIRECTIVE 设不上: $e"
    } else {
        puts "==> 核的 OOC 综合用 DIRECTIVE=PerformanceOptimized（压 M 扩展那条路径）"
    }
} else {
    puts "==> ⚠ 没找到 ps_pl_u_rv32_ps_0_synth_1，核的 OOC DIRECTIVE 未设"
}

puts "==> Project created at $proj_dir"
puts "==> Top = ${bd_name}_wrapper, PS7 M_AXI_GP0 connected to rv32_ps_top"
# 这个偏移量要填进 sw/ps_main.c 的 RV32_BASE —— 顺手打出来，省得去 GUI 里翻。
#
# 必须从**主端** segment 上取。get_bd_addr_segs -of_objects [get_bd_cells u_rv32_ps]
# 拿到的是从端 segment（/u_rv32_ps/s_axi/reg0），那个对象是"浮动"的、**没有 offset
# 属性** —— get_property 对它返回空串而不报错，catch 也就抓不到，所以这里曾经一直
# 打出空的 offset。沿 addr_spaces → segs 走到主端 segment 才有 offset/range。
puts "==> Slave address map (put this offset into RV32_BASE in sw/ps_main.c):"
set n_seg 0
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces u_ps7/Data]] {
    incr n_seg
    puts "      $seg"
    puts "        offset = [get_property offset $seg]   range = [get_property range $seg]"
}
if {$n_seg == 0} {
    puts "      !! nothing under u_ps7/Data -- check that name, available spaces are:"
    puts "      !! [get_bd_addr_spaces]"
}

# 顺手把脚本自己钉的期望值和 sw/ps_main.c 里的 RV32_BASE 对一下。地址漂了是这条路上
# 最难从现象反推的错（读回来全是 0 或全 F），在这里提前报出来。
set ps_main [file join $root sw ps_main.c]
if {[file exists $ps_main]} {
    set fp2 [open $ps_main r]
    set src [read $fp2]
    close $fp2
    if {[regexp {define\s+RV32_BASE\s+(0x[0-9A-Fa-f]+)} $src whole base_in_c]} {
        if {[expr {$base_in_c == $rv32_offset}]} {
            # 方括号在双引号里是**命令替换**，不是字面量：写成 "[ok]" 会让 Tcl 去找名为 ok
            # 的命令，整个建工程脚本当场 "invalid command name"。这四条以前跑不到
            # （地址一直对不上，走的是 else），刚把地址钉住就撞上了。
            puts "==> \[ok\] sw/ps_main.c RV32_BASE = $base_in_c matches the pinned offset"
        } else {
            puts "==> \[WARN\] sw/ps_main.c RV32_BASE = $base_in_c but pinned = $rv32_offset"
        }
    } else {
        puts "==> \[WARN\] no 'define RV32_BASE' found in sw/ps_main.c"
    }
} else {
    puts "==> \[WARN\] sw/ps_main.c not found at $ps_main"
}
