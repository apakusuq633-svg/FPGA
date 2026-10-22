# Analysis only; hypothetical external delay budgets, no board access.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021 window_recheck_20261022]
open_checkpoint [file join $root build pdm_ila_20261021 sync40 routed.dcp]
source [file join $root scripts pdm_external_window.tcl]
pdm_external_window $out 6 14
pdm_assert_window
# Prove the gate rejects budgets that exceed setup or hold margins.
foreach name {late_setup early_hold} dmax {206.0 106.0} dmin {5.0 -195.0} {
  pdm_external_window [file join $out $name] 6 14 $dmax $dmin
  if {![catch {pdm_assert_window} message]} {error "Negative control unexpectedly passed: $name"}
  if {![string match "External * failure*" $message]} {error "Unexpected negative-control failure: $message"}
  puts "PDM_WINDOW_NEGATIVE_DETECTED $name $message"
}
close_design
exit
