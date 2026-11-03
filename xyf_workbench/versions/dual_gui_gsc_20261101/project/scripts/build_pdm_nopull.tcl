# Reference-like DATA inputs: neither internal pullup nor pulldown.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_checkpoint [file join $out routed.dcp]
set trial [file join $out nopull12]
file mkdir $trial
set_property SLEW FAST [get_ports pdm_clk_o]
set_property PULLDOWN false [get_ports {pdm_din_i[*]}]
set_property PULLUP false [get_ports {pdm_din_i[*]}]
report_io -file [file join $trial io.rpt]
write_debug_probes -force [file join $trial pdm_ila.ltx]
write_bitstream -force [file join $trial pdm_ila.bit]
puts "PDM_NOPULL12_BUILD_PASS"
exit
