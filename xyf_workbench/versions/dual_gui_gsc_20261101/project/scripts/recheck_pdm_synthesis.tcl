# Rebuild the offending OOC ILA, then the top; no hardware access.
set root [file normalize [file join [file dirname [info script]] ..]]
set project [file join $root build pdm_ila_20261021 sync40 project pdm_ila.xpr]
if {$argc > 0} {set project [file normalize [lindex $argv 0]]}
open_project $project
# Force a real compile rather than accepting a checkpoint from the IP cache.
config_ip_cache -disable_for_ip [get_ips ila_pdm_raw]
reset_run ila_pdm_raw_synth_1
launch_runs ila_pdm_raw_synth_1 -jobs 1
wait_on_run ila_pdm_raw_synth_1
if {[get_property PROGRESS [get_runs ila_pdm_raw_synth_1]] ne "100%"} {error "ILA synthesis failed"}
reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Top synthesis failed"}
foreach name {ila_pdm_raw_synth_1 synth_1} {
  set log [file join [get_property DIRECTORY [get_runs $name]] runme.log]
  set fd [open $log r];set contents [read $fd];close $fd
  if {[regexp {ERROR:} $contents]} {error "Synthesis log still contains ERROR: $log"}
  puts "PDM_SYNTHESIS_CLEAN $name"
}
close_project
exit
