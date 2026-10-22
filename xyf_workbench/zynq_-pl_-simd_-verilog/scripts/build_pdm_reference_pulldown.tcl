# Isolate weak input bias from the original reference's clock/receiver.
set root [file normalize [file join [file dirname [info script]] ..]]
set base [file join $root build pdm_ila_20261021]
set out [file join $base reference768_pd]
file mkdir $out
open_checkpoint [file join $base reference768 routed.dcp]
set_property PULLDOWN true [get_ports {pdm_data[*]}]
set_property PULLUP false [get_ports {pdm_data[*]}]
report_io -file [file join $out io.rpt]
write_debug_probes -force [file join $out pdm_ila.ltx]
write_checkpoint -force [file join $out routed.dcp]
write_bitstream -force [file join $out pdm_ila.bit]
puts "PDM_REFERENCE_PULLDOWN_BUILD_PASS only_input_bias_changed=1"
exit
