# Sourced by create_zynq_project.tcl. Only adds an internal optional HP0 transport.
if {!$stream_dma_enabled} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 gsc_sink_ready
    set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL 1] [get_bd_cells gsc_sink_ready]
    connect_bd_net [get_bd_pins gsc_sink_ready/dout] [get_bd_pins u_rv32_ps/gsc_ready_i]
    puts "STREAM_DMA_DISABLED"
} else {
    if {$::env(DAS_ACTIVE_CHANNELS) ni {9 12}} {error "Stream/GSC ABI requires circular9 v2 or legacy12 v1"}
    create_bd_cell -type module -reference rv32_stream_dma u_stream_dma
    set_property CONFIG.ACTIVE_CHANNELS $::env(DAS_ACTIVE_CHANNELS) [get_bd_cells u_stream_dma]
    foreach bus {s_axi} {
        set_property CONFIG.FREQ_HZ 40000000 [get_bd_intf_pins u_stream_dma/$bus]
    }
    connect_bd_net [get_bd_pins u_ps7/FCLK_CLK0] [get_bd_pins u_stream_dma/clk_i] [get_bd_pins u_ps7/S_AXI_HP0_ACLK]
    connect_bd_net [get_bd_pins u_rv32_ps/gsc_valid_o] [get_bd_pins u_stream_dma/stream_valid_i]
    connect_bd_net [get_bd_pins u_rv32_ps/gsc_data_o] [get_bd_pins u_stream_dma/stream_data_i]
    connect_bd_net [get_bd_pins u_rv32_ps/gsc_timestamp_o] [get_bd_pins u_stream_dma/stream_timestamp_i]
    connect_bd_net [get_bd_pins u_stream_dma/stream_ready_o] [get_bd_pins u_rv32_ps/gsc_ready_i]
    # Reuse the established GP0 crossbar, preserving the original 4K slave map.
    set_property CONFIG.NUM_MI 2 [get_bd_cells u_ps7_axi_periph]
    connect_bd_intf_net [get_bd_intf_pins u_ps7_axi_periph/M01_AXI] [get_bd_intf_pins u_stream_dma/s_axi]
    connect_bd_net [get_bd_pins u_ps7/FCLK_CLK0] [get_bd_pins u_ps7_axi_periph/M01_ACLK]
    set reset_net [get_bd_nets -of_objects [get_bd_pins u_ps7_axi_periph/M00_ARESETN]]
    connect_bd_net -net $reset_net [get_bd_pins u_ps7_axi_periph/M01_ARESETN]
    connect_bd_net -net $reset_net [get_bd_pins u_stream_dma/rst_n_i]
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config {
        Clk_master {Auto} Clk_slave {Auto} Clk_xbar {Auto}
        Master "/u_stream_dma/m_axi" Slave "/u_ps7/S_AXI_HP0"
        intc_ip {New AXI Interconnect} master_apm {0}
    } [get_bd_intf_pins u_ps7/S_AXI_HP0]
    assign_bd_address
    assign_bd_address -target_address_space [get_bd_addr_spaces u_ps7/Data] -offset 0x43C00000 -range 4K -force [get_bd_addr_segs u_rv32_ps/s_axi/reg0]
    assign_bd_address -target_address_space [get_bd_addr_spaces u_ps7/Data] -offset 0x43C10000 -range 4K -force [get_bd_addr_segs u_stream_dma/s_axi/reg0]
    puts "STREAM_DMA_CONNECTED control=0x43C10000 data=HP0 clock=40000000 slot_bytes=128"
}
