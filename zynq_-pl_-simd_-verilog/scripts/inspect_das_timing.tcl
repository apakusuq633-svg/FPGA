set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] != 1} { error "Usage: inspect_das_timing.tcl checkpoint.dcp" }
open_checkpoint [lindex $argv 0]
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $root build das_debug_timing.rpt]
report_utilization -file [file join $root build das_debug_util.rpt]
puts "DAS_TIMING_INSPECT_PASS"
