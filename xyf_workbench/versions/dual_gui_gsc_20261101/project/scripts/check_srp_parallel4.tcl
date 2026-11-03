# Standalone area/timing evidence for the 36-pair four-bank SRP scanner.
# Full SoC implementation and board validation remain separate checks.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build srp_lag_ring ooc]
file mkdir $out
if {[catch {
  read_verilog [file join $root rtl srp rv32_srp_scan.v]
  synth_design -top rv32_srp_scan -part xc7z020clg400-1 -mode out_of_context \
    -generic {N_PAIR=36 N_GRID=1024 R_LEN=64 IDX_W=6 GRID_IDX_W=10 ADDR_W=16 FAST_SCAN=4}
  create_clock -name clk -period 25.000 [get_ports clk_i]
  opt_design
  place_design
  route_design
  report_utilization -file [file join $out utilization.rpt]
  report_timing_summary -file [file join $out timing.rpt]
  report_drc -file [file join $out drc.rpt]
  write_checkpoint -force [file join $out srp_parallel4.dcp]
  set setup [get_timing_paths -delay_type max -max_paths 1]
  set hold [get_timing_paths -delay_type min -max_paths 1]
  if {[llength $setup] == 0 || [llength $hold] == 0} {error "No internal timing paths"}
  set wns [get_property SLACK $setup]
  set whs [get_property SLACK $hold]
  if {$wns < 0 || $whs < 0} {error "Internal timing failed WNS=$wns WHS=$whs"}
  puts "SRP_PARALLEL4_OOC_PASS WNS=$wns WHS=$whs"
} reason]} {
  puts "SRP_PARALLEL4_OOC_FAIL reason=$reason"
  exit 1
}
exit 0
