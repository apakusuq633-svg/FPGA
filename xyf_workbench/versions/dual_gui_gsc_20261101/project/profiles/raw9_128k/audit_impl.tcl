set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build raw9_128k_pl_try3]
open_checkpoint [file join $out raw9.runs impl_1 raw9_wrapper_routed.dcp]
report_io -file [file join $out io.rpt]
report_drc -file [file join $out drc.rpt]
foreach port [get_ports {pdm_din_i[*]}] {
 puts "RAW9_DIN $port [get_property PACKAGE_PIN $port] [get_property IOSTANDARD $port] [get_property PULLDOWN $port]"
}
puts "RAW9_CLK [get_property PACKAGE_PIN [get_ports pdm_clk_o]]"
if {[llength [get_ports {pdm_din_i[*]}]]!=5} {error "DIN width mismatch"}
foreach i {0 1 2 3 4} pin {T14 Y17 W16 T15 Y16} {
 set port [get_ports [format {pdm_din_i[%d]} $i]]
 if {[get_property PACKAGE_PIN $port] ne $pin || [get_property IOSTANDARD $port] ne "LVCMOS33" || ![get_property PULLDOWN $port]} {error "IO mismatch"}
}
if {[get_property PACKAGE_PIN [get_ports pdm_clk_o]] ne "V16"} {error "CLK pin mismatch"}
if {[get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]<0} {error "hold failed"}
puts RAW9_IMPLEMENTED_IO_PASS
