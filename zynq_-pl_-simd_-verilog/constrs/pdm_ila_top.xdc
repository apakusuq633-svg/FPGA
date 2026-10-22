# Matches user-specified PDM_48K_8ch/constr/pdm_mic_8ch.xdc.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports clk_50m]
# pdm_debug_clock supplies the 20 ns primary input clock constraint.
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports rst_n]
set_false_path -from [get_ports rst_n]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33 DRIVE 12 SLEW SLOW} [get_ports pdm_clk_o]
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[0]}]
set_property -dict {PACKAGE_PIN Y17 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[2]}]
set_property -dict {PACKAGE_PIN T15 IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[3]}]
set_max_delay -datapath_only 5.000 -from [get_ports {pdm_din_i[*]}]
set_max_delay -datapath_only 10.000 -from [all_registers -clock_pins] -to [get_ports pdm_clk_o]
