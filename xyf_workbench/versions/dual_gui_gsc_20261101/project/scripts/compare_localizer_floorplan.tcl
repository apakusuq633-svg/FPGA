# Same synthesized netlist and directives; no placement regions, for a routed A/B.
set root [file normalize [file join [file dirname [info script]] ..]]
set here [file join $root scripts]
set output_dir [file join $root build localizer12_final unconstrained]
file mkdir $output_dir
if {[catch {
 open_project [file join $root build localizer12_final zynq rv32_zynq.xpr]
 open_run synth_1
 if {[llength [get_pblocks -quiet]]} {error "Synthesis baseline unexpectedly has placement regions"}
 if {[get_property PERIOD [get_clocks clk_fpga_0]] != 25} {error "Expected 40 MHz product clock"}
 write_checkpoint -force [file join $output_dir linked_synthesis.dcp]
 opt_design
 place_design -directive ExtraNetDelay_high
 phys_opt_design -directive AggressiveExplore
 route_design -directive NoTimingRelaxation
 phys_opt_design
 route_design
 report_timing_summary -delay_type min_max -file [file join $output_dir timing_zynq.rpt]
 report_utilization -file [file join $output_dir util_zynq.rpt]
 source [file join $here report_localizer_physical.tcl]
 write_checkpoint -force [file join $output_dir routed.dcp]
 set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
 set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
 puts "LOCALIZER_UNCONSTRAINED_COMPLETE wns=$wns whs=$whs"
} why]} {puts "LOCALIZER_UNCONSTRAINED_FAIL $why";exit 1}
exit 0
