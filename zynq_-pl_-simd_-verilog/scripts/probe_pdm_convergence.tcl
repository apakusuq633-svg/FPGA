# Read-only checkpoint interrogation: command semantics, clocks and resource ownership.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_convergence probe]
file mkdir $out
open_checkpoint [file join $root build pdm_shared_remediation vivado_soc routed.dcp]
help reset_timing
catch {help reset_path}
help create_generated_clock
set fp [open [file join $out clocks.txt] w]
foreach c [get_clocks] {puts $fp "$c SOURCE_PINS=[get_property SOURCE_PINS $c]"}
close $fp
set p [lindex [get_timing_paths -from [get_ports {pdm_din_i[0]}] -delay_type max -max_paths 1] 0]
report_property $p -file [file join $out timing_path_properties.txt]
report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out utilization_hierarchical.rpt]
if {[llength [info commands report_ram_utilization]]} {report_ram_utilization -file [file join $out ram_utilization.rpt]}
set fp [open [file join $out bram_cells.csv] w]
puts $fp "name,primitive,read_width_a,read_width_b,write_width_a,write_width_b,ram_mode"
foreach c [get_cells -hier -filter {REF_NAME =~ RAMB*}] {
    puts $fp "[get_property NAME $c],[get_property REF_NAME $c],[get_property READ_WIDTH_A $c],[get_property READ_WIDTH_B $c],[get_property WRITE_WIDTH_A $c],[get_property WRITE_WIDTH_B $c],[get_property RAM_MODE $c]"
}
close $fp
puts "PDM_CONVERGENCE_PROBE_DONE"
exit 0
