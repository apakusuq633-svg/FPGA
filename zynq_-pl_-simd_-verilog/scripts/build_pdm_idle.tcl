# Safe idle configuration for suspected shared-line contention: CLOCK held low,
# all other PL user I/O un-driven. No PS or flash programming.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021 idle]
file mkdir $out
create_project -in_memory -part xc7z020clg400-2
set f [open [file join $out pdm_idle_top.v] w]
puts $f {module pdm_idle_top(output pdm_clk_o); assign pdm_clk_o=1'b0; endmodule}
close $f
read_verilog [file join $out pdm_idle_top.v]
synth_design -top pdm_idle_top -part xc7z020clg400-2
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33 DRIVE 12 SLEW SLOW} [get_ports pdm_clk_o]
opt_design
place_design
route_design
report_io -file [file join $out io.rpt]
write_bitstream -force [file join $out pdm_idle.bit]
puts "PDM_IDLE_BUILD_PASS"
exit
