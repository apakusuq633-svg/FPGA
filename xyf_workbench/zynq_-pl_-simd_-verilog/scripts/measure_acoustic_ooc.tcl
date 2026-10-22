# Resource and internal timing experiments only; no board access or production bitstream.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build system_optimization ooc]
if {[info exists ::env(ACOU_OOC_DIR)]} {set out [file normalize $::env(ACOU_OOC_DIR)]}
file mkdir $out
set experiments {
  {srp8_before rv32_srp_scan build/system_optimization/srp_before.v {N_PAIR=28 N_GRID=1024 R_LEN=32 IDX_W=5 GRID_IDX_W=10 ADDR_W=17}}
  {srp8_after rv32_srp_scan rtl/srp/rv32_srp_scan.v {N_PAIR=28 N_GRID=1024 R_LEN=32 IDX_W=5 GRID_IDX_W=10 ADDR_W=17}}
  {srp12_after rv32_srp_scan rtl/srp/rv32_srp_scan.v {N_PAIR=66 N_GRID=1024 R_LEN=32 IDX_W=5 GRID_IDX_W=10 ADDR_W=17}}
  {acou4 rv32_acoustic_ext rtl/acoustic/rv32_acoustic_ext.v {LANES=4}}
  {acou8 rv32_acoustic_ext rtl/acoustic/rv32_acoustic_ext.v {LANES=8}}
  {acou16 rv32_acoustic_ext rtl/acoustic/rv32_acoustic_ext.v {LANES=16}}
}
foreach experiment $experiments {
  lassign $experiment tag top source parameters
  if {[info exists ::env(ACOU_OOC_ONLY)] && $::env(ACOU_OOC_ONLY) && ![string match acou* $tag]} {continue}
  if {[llength [current_project -quiet]]} {close_project}
  create_project -in_memory -part xc7z020clg400-1
  if {[catch {
    read_verilog [file join $root $source]
    synth_design -top $top -mode out_of_context -part xc7z020clg400-1 -generic $parameters
    create_clock -name clk -period 25.000 [get_ports clk_i]
    opt_design
    place_design
    route_design
    report_utilization -file [file join $out ${tag}_util.rpt]
    report_utilization -hierarchical -file [file join $out ${tag}_hier.rpt]
    report_timing_summary -file [file join $out ${tag}_timing.rpt]
    report_timing -max_paths 10 -file [file join $out ${tag}_paths.rpt]
    write_checkpoint -force [file join $out ${tag}.dcp]
    set setup [get_timing_paths -delay_type max -max_paths 1]
    set hold [get_timing_paths -delay_type min -max_paths 1]
    set wns [get_property SLACK $setup]
    set whs [get_property SLACK $hold]
    puts "SYSTEM_OOC_RESULT tag=$tag WNS=$wns WHS=$whs"
  } error]} {
    puts "SYSTEM_OOC_FAIL tag=$tag reason=$error"
    exit 1
  }
}
puts "SYSTEM_OOC_ALL_PASS"
exit 0
