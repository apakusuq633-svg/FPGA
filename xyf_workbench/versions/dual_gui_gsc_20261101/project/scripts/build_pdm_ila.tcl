set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
if {[info exists ::env(PDM_ILA_OUT)]} {set out [file normalize $::env(PDM_ILA_OUT)]}
set clock_mhz 40.000
if {[info exists ::env(PDM_ILA_CLOCK_MHZ)]} {set clock_mhz $::env(PDM_ILA_CLOCK_MHZ)}
set top_source [file join $root rtl debug pdm_ila_top.v]
set sync_capture [expr {[info exists ::env(PDM_ILA_SYNC)] && $::env(PDM_ILA_SYNC) eq "1"}]
if {$sync_capture} {set top_source [file join $root scripts pdm_ila_sync_top.v]}
file mkdir $out
if {$argc > 0 && [lindex $argv 0] eq "--resume"} {
open_project [file join $out project pdm_ila.xpr]
reset_run impl_1
} else {
create_project pdm_ila [file join $out project] -part xc7z020clg400-2 -force
set_property target_language Verilog [current_project]
add_files [list $top_source \
  [file join $root rtl array rv32_pdm_array_rx.v] \
  [file join $root rtl array rv32_pdm_cic.v] \
  [file join $root rtl array rv32_pdm_clkgen.v]]
add_files -fileset constrs_1 [file join $root constrs pdm_ila_top.xdc]
set_property top pdm_ila_top [current_fileset]
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name pdm_debug_clock
set_property -dict [list CONFIG.PRIM_IN_FREQ {50.000} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $clock_mhz CONFIG.RESET_TYPE {ACTIVE_LOW}] [get_ips pdm_debug_clock]
if {$clock_mhz != 40.000} {
  # Trial-specific copy: leave the main source constraints untouched.
  set fd [open [file join $root constrs pdm_ila_top.xdc] r]
  set trial_xdc [read $fd];close $fd
  set trial_xdc [string map {"SLEW SLOW" "SLEW FAST"} $trial_xdc]
  set path [file join $out trial.xdc]
  set fd [open $path w];puts $fd $trial_xdc;close $fd
  remove_files [get_files -of_objects [get_filesets constrs_1] *pdm_ila_top.xdc]
  add_files -fileset constrs_1 $path
}
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_pdm_raw
set_property -dict [list CONFIG.C_NUM_OF_PROBES {1} CONFIG.C_PROBE0_WIDTH {26} CONFIG.C_DATA_DEPTH {4096}] [get_ips ila_pdm_raw]
if {$sync_capture} {
  set_property -dict [list CONFIG.C_NUM_OF_PROBES {3} CONFIG.C_PROBE1_WIDTH {192} CONFIG.C_PROBE2_WIDTH {32} CONFIG.C_DATA_DEPTH {8192}] [get_ips ila_pdm_raw]
}
create_ip -name ila -vendor xilinx.com -library ip -module_name ila_pdm_pcm
set_property -dict [list CONFIG.C_NUM_OF_PROBES {4} CONFIG.C_PROBE0_WIDTH {192} CONFIG.C_PROBE1_WIDTH {1} CONFIG.C_PROBE2_WIDTH {32} CONFIG.C_PROBE3_WIDTH {8} CONFIG.C_DATA_DEPTH {8192} CONFIG.C_EN_STRG_QUAL {1}] [get_ips ila_pdm_pcm]
generate_target all [get_ips]
# Serialize tool startup for the OOC IP runs. The previous parallel build
# could leave Common 17-354 in a successful run's startup log.
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
# Vivado can report 100% even when a child logged a startup ERROR.
foreach run [get_runs -filter {IS_SYNTHESIS == 1}] {
  set log_path [file join [get_property DIRECTORY $run] runme.log]
  if {![file exists $log_path]} {continue}
  set log_fd [open $log_path r];set log_text [read $log_fd];close $log_fd
  if {[regexp {ERROR:} $log_text]} {error "Synthesis child logged an error: $log_path"}
}
}
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Route failed"}
open_run impl_1
report_io -file [file join $out io.rpt]
report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
report_drc -file [file join $out drc.rpt]
set expected [dict create clk_50m {U18 IN} rst_n {N16 IN} pdm_clk_o {V16 OUT} {pdm_din_i[0]} {T14 IN} {pdm_din_i[1]} {Y17 IN} {pdm_din_i[2]} {W16 IN} {pdm_din_i[3]} {T15 IN}]
if {[llength [get_ports]] != [dict size $expected]} {error "Unexpected top ports"}
dict for {port spec} $expected {
  set p [get_ports $port]
  if {[get_property PACKAGE_PIN $p] ne [lindex $spec 0] || [get_property DIRECTION $p] ne [lindex $spec 1] || [get_property IOSTANDARD $p] ne "LVCMOS33"} {error "Unsafe pin/direction/standard: $port"}
}
foreach kind {max min} {
  set slack [get_property SLACK [get_timing_paths -delay_type $kind]]
  if {$slack < 0} {error "Timing failed $kind $slack"}
}
write_debug_probes -force [file join $out pdm_ila.ltx]
write_checkpoint -force [file join $out routed.dcp]
write_bitstream -force [file join $out pdm_ila.bit]
puts "PDM_ILA_BUILD_PASS"
exit
