# Reuse completed synthesis after a four-microphone pin-only correction.
set root [file normalize [file join [file dirname [info script]] ..]]
set proj_dir [file join $root build das4_zynq]
set output_dir [file join $root build das4]
open_project [file join $proj_dir rv32_zynq.xpr]
source [file join $root scripts configure_debug4_pins.tcl]
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis must be complete" }
reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation incomplete" }
open_run impl_1
foreach channel {0 1 2 3} pin {T14 Y17 T15 W16} {
    set port [get_ports [format {pdm_din_i[%d]} $channel]]
    if {[get_property PACKAGE_PIN $port] ne $pin} { error "Wrong debug4 package pin" }
}
phys_opt_design
route_design
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $output_dir timing_zynq.rpt]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
if {$wns eq "" || $whs eq "" || $wns < 0 || $whs < 0} { error "Timing failed: $wns/$whs" }
write_bitstream -force [file join $proj_dir rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
report_utilization -file [file join $output_dir util_zynq.rpt]
report_io -file [file join $output_dir io_zynq.rpt]
write_checkpoint -force [file join $output_dir das_fir_routed.dcp]
write_hw_platform -fixed -include_bit -force -file [file join $output_dir das_fir.xsa]
puts "FLOW_PASS: debug4 corrected pins; setup=$wns hold=$whs"
