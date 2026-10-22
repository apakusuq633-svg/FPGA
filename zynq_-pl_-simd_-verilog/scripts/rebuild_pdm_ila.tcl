set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
open_project [file join $out project pdm_ila.xpr]
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
close_project
set argv {--resume}
set argc 1
source [file join $root scripts build_pdm_ila.tcl]
