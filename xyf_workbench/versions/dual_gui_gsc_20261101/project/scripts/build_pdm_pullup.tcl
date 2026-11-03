# Controlled electrical diagnostic: identical routed circuit, weak DATA bias only.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_checkpoint [file join $out routed.dcp]
set trial [file join $out pullup]
file mkdir $trial
set_property PULLDOWN false [get_ports {pdm_din_i[*]}]
set_property PULLUP true [get_ports {pdm_din_i[*]}]
report_io -file [file join $trial io.rpt]
write_debug_probes -force [file join $trial pdm_ila.ltx]
write_bitstream -force [file join $trial pdm_ila.bit]
puts "PDM_PULLUP_BUILD_PASS"
exit
