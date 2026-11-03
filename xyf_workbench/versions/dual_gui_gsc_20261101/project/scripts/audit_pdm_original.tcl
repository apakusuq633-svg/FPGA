set root [file normalize [file join [file dirname [info script]] ..]]
set original C:/Users/lenovo/Desktop/FPGA/PDM/pdm_mic_8ch.runs/impl_1
set out [file join $root build pdm_ila_20261021 original_pdm_stock]
file mkdir $out
open_checkpoint [file join $original pdm_top_routed.dcp]
if {[get_property PART [current_design]] ne "xc7z020clg400-2"} {error "Unexpected reference part"}
set expected [dict create clk_50m {U18 IN} rst_n {N16 IN} pdm_clk {V16 OUT} led {H15 OUT} {pdm_data[0]} {T14 IN} {pdm_data[1]} {Y17 IN} {pdm_data[2]} {W16 IN} {pdm_data[3]} {T15 IN}]
if {[llength [get_ports]]!=8} {error "Unexpected reference IO"}
dict for {name spec} $expected {
  set p [get_ports $name]
  if {[get_property PACKAGE_PIN $p] ne [lindex $spec 0] || [get_property DIRECTION $p] ne [lindex $spec 1] || [get_property IOSTANDARD $p] ne "LVCMOS33"} {error "Unsafe IO: $name"}
}
report_io -file [file join $out io.rpt]
report_clocks -file [file join $out clocks.rpt]
file copy -force [file join $original pdm_top.bit] [file join $out pdm_ila.bit]
file copy -force [file join $original pdm_top.ltx] [file join $out pdm_ila.ltx]
puts "PDM_SCREENSHOT_ORIGINAL_IO_AUDIT_PASS copied_bit_unchanged=1"
exit
