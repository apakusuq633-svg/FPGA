# OOC check; this does not replace full SoC implementation.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build accelerator_optimization]
file mkdir $out
set tag [lindex $argv 0]
set source [lindex $argv 1]
if {$tag eq ""} {set tag after}
if {$source eq ""} {set source [file join $root rtl srp rv32_srp_scan.v]}
if {[catch {
  read_verilog $source
  synth_design -top rv32_srp_scan -part xc7z020clg400-1 -mode out_of_context \
    -generic {N_PAIR=66 N_GRID=1024 R_LEN=32 IDX_W=5 GRID_IDX_W=10 ADDR_W=17}
  create_clock -name clk -period 25.000 [get_ports clk_i]
  opt_design
  place_design
  route_design
  report_utilization -file [file join $out ${tag}_utilization.rpt]
  report_timing_summary -file [file join $out ${tag}_timing.rpt]
  write_checkpoint -force [file join $out ${tag}_srp.dcp]
  set setup [get_timing_paths -delay_type max -max_paths 1]
  set hold [get_timing_paths -delay_type min -max_paths 1]
  if {[llength $setup] == 0 || [llength $hold] == 0} {error "No internal timing paths"}
  set wns [get_property SLACK $setup]
  set whs [get_property SLACK $hold]
  if {$wns < 0 || $whs < 0} {error "Internal timing failed WNS=$wns WHS=$whs"}
  puts "SRP_OOC_PASS tag=$tag WNS=$wns WHS=$whs"
} reason]} {
  puts "SRP_OOC_FAIL tag=$tag reason=$reason"
  exit 1
}
exit 0
