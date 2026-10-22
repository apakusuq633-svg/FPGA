# Read-only full routed candidate audit, before separate qualification-clock analysis.
if {$argc!=2} {error "Usage: checkpoint fresh_output"}
set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
if {[file exists $out]} {error "Fresh output required"}
file mkdir $out
if {[catch {
 open_checkpoint $checkpoint
 report_utilization -hierarchical -hierarchical_depth 8 -file [file join $out hierarchy.rpt]
 report_ram_utilization -file [file join $out ram.rpt]
 report_route_status -file [file join $out route.rpt]
 report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
 report_drc -file [file join $out drc.rpt]
 set fp [open [file join $out bram.csv] w]
 puts $fp "name,primitive,write_mode_a,write_mode_b"
 foreach cell [get_cells -hier -filter {REF_NAME =~ RAMB*}] {
  set values [list $cell [get_property REF_NAME $cell]]
  foreach prop {WRITE_MODE_A WRITE_MODE_B} {
   if {[lsearch -exact [list_property $cell] $prop]>=0} {lappend values [get_property $prop $cell]} else {lappend values UNAVAILABLE}
  }
  puts $fp [join $values ,]
 }
 close $fp
 puts "PDM_RAM_ROUTED_AUDIT_DONE hardware=UNVERIFIED_HARDWARE"
} message]} {puts "PDM_RAM_ROUTED_AUDIT_FAIL $message";exit 1}
exit 0
