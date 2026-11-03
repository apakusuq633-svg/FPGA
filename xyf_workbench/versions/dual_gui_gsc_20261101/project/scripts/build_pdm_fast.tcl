# Controlled comparison: retain routed logic, 175 ns sampling and DATA pulldowns.
# Change only CLOCK slew; DRIVE remains the reference default of 12 mA.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_checkpoint [file join $out routed.dcp]
set trial [file join $out fast12]
file mkdir $trial
set_property SLEW FAST [get_ports pdm_clk_o]
if {[get_property PACKAGE_PIN [get_ports pdm_clk_o]] ne "V16" ||
    [get_property IOSTANDARD [get_ports pdm_clk_o]] ne "LVCMOS33" ||
    [get_property DRIVE [get_ports pdm_clk_o]] != 12} {error "Unexpected CLOCK configuration"}
report_io -file [file join $trial io.rpt]
write_debug_probes -force [file join $trial pdm_ila.ltx]
write_bitstream -force [file join $trial pdm_ila.bit]
puts "PDM_FAST12_BUILD_PASS"
exit
