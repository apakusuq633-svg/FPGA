# Use the routed default 4/12 sampling receiver and match production default
# LVCMOS33 output drive (12 mA SLOW). No receiver logic is edited.
set root [file normalize [file join [file dirname [info script]] ..]]
set base [file join $root build pdm_ila_20261021]
set out [file join $base current_default125]
file mkdir $out
open_checkpoint [file join $base initial_125ns_drive4 routed.dcp]
set expected [dict create clk_50m {U18 IN} rst_n {N16 IN} pdm_clk_o {V16 OUT} {pdm_din_i[0]} {T14 IN} {pdm_din_i[1]} {Y17 IN} {pdm_din_i[2]} {W16 IN} {pdm_din_i[3]} {T15 IN}]
if {[llength [get_ports]]!=7} {error "Unexpected IO"}
dict for {name spec} $expected {
  set p [get_ports $name]
  if {[get_property PACKAGE_PIN $p] ne [lindex $spec 0] || [get_property DIRECTION $p] ne [lindex $spec 1] || [get_property IOSTANDARD $p] ne "LVCMOS33"} {error "Unsafe IO $name"}
}
set_property DRIVE 12 [get_ports pdm_clk_o]
set_property SLEW SLOW [get_ports pdm_clk_o]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
report_io -file [file join $out io.rpt]
report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
write_debug_probes -force [file join $out pdm_ila.ltx]
write_checkpoint -force [file join $out routed.dcp]
write_bitstream -force [file join $out pdm_ila.bit]
puts "PDM_CURRENT_DEFAULT_EDGE_BUILD_PASS hold=4 consume=12 drive=12 slew=SLOW"
exit
