# Isolated RAM-shape experiments only. Does not modify production sources/projects.
set root [file normalize [file join [file dirname [info script]] ..]]
if {$argc!=2} {error "Usage: candidate_directory fresh_output_directory"}
set candidates [file normalize [lindex $argv 0]]
set base [file normalize [lindex $argv 1]]
if {[file exists $base]} {error "Fresh output required"}
file mkdir $base
set fp [open [file join $base summary.csv] w]
puts $fp "module,variant,RAMB36,RAMB18,LUT,FF,DSP,WNS,WHS"
if {[catch {
 foreach module {srp localizer} {
  foreach variant {baseline banked} {
   if {$module eq "srp"} {set top rv32_srp_scan;set sub [expr {$variant eq "baseline"?"baseline":"srp_banked"}];set generics {N_PAIR=66 N_GRID=1024 R_LEN=32 IDX_W=5 GRID_IDX_W=10 ADDR_W=17 FAST_SCAN=1}} else {set top rv32_overlap_localizer;set sub [expr {$variant eq "baseline"?"baseline":"raw_banked"}];set generics {CPU_SCHEDULED=1}}
   set out [file join $base ${module}_${variant}];file mkdir $out
   create_project ${module}_${variant} [file join $out project] -part xc7z020clg400-1
   read_verilog [file join $candidates $sub ${top}.v]
   synth_design -top $top -part xc7z020clg400-1 -mode out_of_context -generic $generics
   create_clock -name pl40 -period 25 [get_ports clk_i]
   opt_design;place_design;route_design
   report_utilization -file [file join $out utilization.rpt]
   report_ram_utilization -file [file join $out ram.rpt]
   report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
   write_checkpoint [file join $out routed.dcp]
   set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
   set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
   set counts {}
   foreach pattern {RAMB36* RAMB18* LUT* FD* DSP*} {lappend counts [llength [get_cells -hier -filter "IS_PRIMITIVE && REF_NAME =~ $pattern"]]}
   puts $fp "$module,$variant,[join $counts ,],$wns,$whs";flush $fp
   puts "RAM_MAPPING_MEASURED module=$module variant=$variant counts=$counts WNS=$wns WHS=$whs"
   close_project
  }
 }
 close $fp
 puts "PDM_RAM_MAPPING_EXPERIMENT_DONE promotion=NOT_AUTHORIZED_BY_THIS_RESULT"
} message]} {puts "PDM_RAM_MAPPING_EXPERIMENT_FAIL $message";puts $::errorInfo;close $fp;exit 1}
exit 0
