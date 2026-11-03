# Offline checkpoint audit only. Never opens hardware manager or downloads.
if {$argc != 2} {error "Usage: audit_m6_routed.tcl routed.dcp new_output_dir"}
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error "Output already exists"}
file mkdir $out
open_checkpoint $checkpoint
if {[get_property PART [current_design]] ne "xc7z020clg400-1"} {error "Unexpected part"}
set ports [get_ports -quiet {pdm_din_i[*]}]
if {[llength $ports]!=6} {error "Expected six configured DATA ports"}
set expected {Y16 Y17 T15 T14 W16 T17}
for {set i 0} {$i<6} {incr i} {
    set port [get_ports [format {pdm_din_i[%d]} $i]]
    if {[get_property PACKAGE_PIN $port] ne [lindex $expected $i]} {error "PDM pin mismatch $i"}
}
if {[get_property PACKAGE_PIN [get_ports pdm_clk_o]] ne "V16"} {error "Clock pin mismatch"}
report_clocks -file [file join $out clocks.rpt]
check_timing -verbose -file [file join $out check_timing.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_io -file [file join $out io.rpt]
report_exceptions -file [file join $out exceptions.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -file [file join $out timing.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup]!=1 || [llength $hold]!=1} {error "Missing timing paths"}
if {[get_property SLACK $setup]<0 || [get_property SLACK $hold]<0} {error "Timing failed"}
puts "M6_ROUTED_AUDIT_PASS part=xc7z020clg400-1 data_lines=6 hardware=UNVERIFIED_HARDWARE"
exit
