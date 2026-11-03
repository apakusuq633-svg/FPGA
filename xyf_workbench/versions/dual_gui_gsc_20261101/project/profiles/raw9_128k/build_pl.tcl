# Independent project. Refuses overwrite. No hardware-manager commands.
set root [file normalize [file join [file dirname [info script]] ../..]]
set profile [file join $root profiles raw9_128k]
set out [file join $root build raw9_128k_pl_try3]
if {[info exists ::env(RAW9_BUILD_DIR)]} {set out [file normalize $::env(RAW9_BUILD_DIR)]}
if {[file exists $out]} {error "Independent build directory exists; choose a fresh directory explicitly"}
create_project raw9 $out -part xc7z020clg400-1
foreach f {raw9_clkgen.v raw9_rx.v raw9_frontend.v} {add_files [file join $profile rtl $f]}
foreach f {rtl/array/rv32_pdm_cic.v rtl/transport/rv32_stream_dma.v rtl/soc/rv32_axi_lite_slave.v} {add_files [file join $root $f]}
create_bd_design raw9
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 u_ps7
source [file join $root scripts ps7_config.tcl]
apply_ps7_config u_ps7
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
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 1 CONFIG.PCW_USE_S_AXI_HP0 1 CONFIG.PCW_EN_CLK0_PORT 1 CONFIG.PCW_EN_RST0_PORT 1 CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ 40] [get_bd_cells u_ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} [get_bd_cells u_ps7]
create_bd_cell -type module -reference raw9_frontend u_raw
create_bd_cell -type module -reference rv32_stream_dma u_dma
set_property CONFIG.ACTIVE_CHANNELS 9 [get_bd_cells u_dma]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 ctrl
set_property -dict [list CONFIG.C_GPIO_WIDTH 1 CONFIG.C_ALL_OUTPUTS 1 CONFIG.C_IS_DUAL 1 CONFIG.C_GPIO2_WIDTH 32 CONFIG.C_ALL_INPUTS_2 1 CONFIG.C_DOUT_DEFAULT {0x00000000}] [get_bd_cells ctrl]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 identity
set_property -dict [list CONFIG.CONST_WIDTH 32 CONFIG.CONST_VAL 1379479858] [get_bd_cells identity]
connect_bd_net [get_bd_pins identity/dout] [get_bd_pins ctrl/gpio2_io_i]
connect_bd_net [get_bd_pins ctrl/gpio_io_o] [get_bd_pins u_raw/en_i]
connect_bd_net [get_bd_pins u_ps7/FCLK_CLK0] [get_bd_pins u_ps7/M_AXI_GP0_ACLK] [get_bd_pins u_ps7/S_AXI_HP0_ACLK] [get_bd_pins u_raw/clk_i] [get_bd_pins u_dma/clk_i]
foreach s {u_dma/s_axi ctrl/S_AXI} {apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {Master "/u_ps7/M_AXI_GP0" Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto}} [get_bd_intf_pins $s]}
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 hp_bridge
set_property -dict [list CONFIG.NUM_SI 1 CONFIG.NUM_MI 1] [get_bd_cells hp_bridge]
connect_bd_intf_net [get_bd_intf_pins u_dma/m_axi] [get_bd_intf_pins hp_bridge/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins hp_bridge/M00_AXI] [get_bd_intf_pins u_ps7/S_AXI_HP0]
connect_bd_net [get_bd_pins u_ps7/FCLK_CLK0] [get_bd_pins hp_bridge/ACLK] [get_bd_pins hp_bridge/S00_ACLK] [get_bd_pins hp_bridge/M00_ACLK]
set rn [get_bd_nets -of_objects [get_bd_pins u_dma/rst_n_i]]
connect_bd_net -net $rn [get_bd_pins hp_bridge/ARESETN] [get_bd_pins hp_bridge/S00_ARESETN] [get_bd_pins hp_bridge/M00_ARESETN]
connect_bd_net -net $rn [get_bd_pins u_raw/rst_n_i]
connect_bd_net [get_bd_pins u_raw/stream_valid_o] [get_bd_pins u_dma/stream_valid_i]
connect_bd_net [get_bd_pins u_raw/stream_data_o] [get_bd_pins u_dma/stream_data_i]
connect_bd_net [get_bd_pins u_raw/stream_timestamp_o] [get_bd_pins u_dma/stream_timestamp_i]
create_bd_port -dir I -from 4 -to 0 pdm_din_i
create_bd_port -dir O pdm_clk_o
connect_bd_net [get_bd_ports pdm_din_i] [get_bd_pins u_raw/pdm_din_i]
connect_bd_net [get_bd_ports pdm_clk_o] [get_bd_pins u_raw/pdm_clk_o]
assign_bd_address
assign_bd_address -target_address_space [get_bd_addr_spaces u_ps7/Data] -offset 0x43C10000 -range 4K -force [get_bd_addr_segs u_dma/s_axi/reg0]
set_property offset 0x41200000 [get_bd_addr_segs u_ps7/Data/SEG_ctrl_Reg]
validate_bd_design
save_bd_design
set bd [get_files */raw9.bd]
generate_target all $bd
add_files [make_wrapper -files $bd -top]
set_property top raw9_wrapper [current_fileset]
add_files -fileset constrs_1 [file join $profile pins.xdc]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_timing_summary -file [file join $out timing.rpt]
report_utilization -file [file join $out utilization.rpt]
if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {error "Implementation incomplete"}
if {[get_property SLACK [get_timing_paths -delay_type max -max_paths 1]] < 0} {error "Setup timing failed"}
write_hw_platform -fixed -include_bit -force -file [file join $out raw9.xsa]
