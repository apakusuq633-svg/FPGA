# Exact screenshot-reference acquisition source plus passive 200 MHz trace.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021 original_pdm_edge]
set src [file join $out source_snapshot]
create_project original_pdm_edge [file join $out project] -part xc7z020clg400-2 -force
add_files [list [file join $src pdm_top.v] [file join $root scripts pdm_original_edge_observe.v]]
add_files -fileset constrs_1 [file join $src original.xdc]
set_property top pdm_original_edge_observe [current_fileset]
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_pdm
set cfg [list CONFIG.C_NUM_OF_PROBES 11 CONFIG.C_DATA_DEPTH 4096 CONFIG.C_INPUT_PIPE_STAGES 2 CONFIG.C_ADV_TRIGGER true]
for {set i 0} {$i<11} {incr i} {
  set width 16
  if {$i==8} {set width 8}
  if {$i>8} {set width 1}
  lappend cfg CONFIG.C_PROBE${i}_WIDTH $width
}
set_property -dict $cfg [get_ips ila_pdm]
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_pdm_edge200
set_property -dict [list CONFIG.C_NUM_OF_PROBES 1 CONFIG.C_PROBE0_WIDTH 96 CONFIG.C_DATA_DEPTH 8192] [get_ips ila_pdm_edge200]
generate_target all [get_ips]
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Reference synthesis failed"}
foreach run [get_runs -filter {IS_SYNTHESIS == 1}] {
  set log [file join [get_property DIRECTORY $run] runme.log]
  if {![file exists $log]} {continue}
  set fd [open $log];set text [read $fd];close $fd
  if {[regexp {ERROR:} $text]} {error "Synthesis log error: $log"}
}
launch_runs impl_1 -to_step route_design -jobs 2
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Reference route failed"}
open_run impl_1
set expected [dict create clk_50m {U18 IN} rst_n {N16 IN} pdm_clk {V16 OUT} led {H15 OUT} {pdm_data[0]} {T14 IN} {pdm_data[1]} {Y17 IN} {pdm_data[2]} {W16 IN} {pdm_data[3]} {T15 IN}]
if {[llength [get_ports]]!=8} {error "Unexpected IO"}
dict for {name spec} $expected {
  set p [get_ports $name]
  if {[get_property PACKAGE_PIN $p] ne [lindex $spec 0] || [get_property DIRECTION $p] ne [lindex $spec 1] || [get_property IOSTANDARD $p] ne "LVCMOS33"} {error "Unsafe IO: $name"}
}
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
report_io -file [file join $out io.rpt]
report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
report_drc -file [file join $out drc.rpt]
foreach kind {max min} {
  if {[get_property SLACK [get_timing_paths -delay_type $kind]]<0} {error "Reference $kind timing failure"}
}
write_debug_probes -force [file join $out pdm_ila.ltx]
write_checkpoint -force [file join $out routed.dcp]
write_bitstream -force [file join $out pdm_ila.bit]
puts "PDM_ORIGINAL_EDGE_BUILD_PASS acquisition_source_unchanged=1"
exit
