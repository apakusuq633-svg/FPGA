# Offline DCP audits only. No hardware manager, reset, programming or download.
set root [file normalize [file join [file dirname [info script]] ..]]
if {$argc!=2} {error "Usage: audit_m10_routed.tcl routed.dcp new_output_dir"}
set common_path [file join $root scripts audit_m6_routed.tcl]
set fp [open $common_path r];set common [read $fp];close $fp
set body ""
foreach line [split $common \n] {
 if {[string trim $line] ne "exit"} {append body $line \n}
}
if {[catch {
 eval $body
 source [file join $root scripts report_pdm_interface.tcl]
 report_pdm_interface [file join $out pdm_interface]
 report_design_analysis -congestion -file [file join $out congestion.rpt]
 report_power -file [file join $out power_vectorless_after.rpt]
 # Freeze the already-reviewed M9 qualification model for this analysis.
 file copy [file join $root build m9_merge_20261016 external_window pdm_external_window.tcl] [file join $out pdm_external_window.tcl]
 source [file join $out pdm_external_window.tcl]
 foreach {name dmax dmin} {nominal 106 5 late_setup 206 5 early_hold 106 -195} {
  pdm_external_window [file join $out external_window $name] 4 12 $dmax $dmin
  set fp [open [file join $out external_window $name summary.txt] r];set data [read $fp];close $fp
  set negative 0
  foreach line [split $data \n] {
   if {[llength $line]!=3} {continue}
   lassign $line group kind slack
   if {$name eq "nominal" && $slack<0} {error "Nominal external timing failed: $line"}
   if {$name eq "late_setup" && $kind eq "max" && $slack<0} {incr negative}
   if {$name eq "early_hold" && $kind eq "min" && $slack<0} {incr negative}
  }
  if {$name ne "nominal" && $negative!=2} {error "Missing A/B negative controls: $name"}
 }
 close_design
 open_checkpoint [file join $root build zynq12_integrated_plan m9_merge_impl_20261016 das_fir_routed.dcp]
 report_power -file [file join $out power_vectorless_before.rpt]
 puts "M10_ROUTED_AUDIT_PASS power=VECTORLESS_ESTIMATE_ONLY external_window=CONDITIONAL board=UNVERIFIED_HARDWARE"
} message]} {puts "M10_ROUTED_AUDIT_FAIL $message";puts $::errorInfo;exit 1}
exit
