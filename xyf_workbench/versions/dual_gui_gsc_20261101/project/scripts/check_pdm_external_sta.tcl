set root [file normalize [file join [file dirname [info script]] ..]]
if {$argc>0 && [lindex $argv 0] eq "--accept"} {
    if {[catch {
        if {$argc!=4} {error "Usage: --accept checkpoint output generated_numeric_config.tcl"}
        set checkpoint [file normalize [lindex $argv 1]]
        set out [file normalize [lindex $argv 2]]
        if {[file exists $out]} {error "Fresh output directory required"}
        source [lindex $argv 3]
        open_checkpoint $checkpoint
        if {[get_property PART [current_design]] ne "xc7z020clg400-1"} {error "Unexpected part"}
        source [file join $root scripts pdm_external_window.tcl]
        pdm_external_window $out 4 12 $pdm_dmax $pdm_dmin $pdm_uncertainty
        pdm_assert_window
        puts "PDM_EXTERNAL_ACCEPTANCE_PASS_CONDITIONAL"
    } message]} {puts "PDM_EXTERNAL_ACCEPTANCE_FAIL $message";exit 1}
    exit 0
}
set out [file join $root build pdm_convergence external_sta]
if {$argc == 1} {set out [file normalize [lindex $argv 0]]}
if {[file exists $out]} {error "Output exists"}
file mkdir $out
if {[catch {
    open_checkpoint [file join $root build pdm_shared_remediation vivado_soc routed.dcp]
    source [file join $root scripts pdm_external_window.tcl]
    pdm_external_window [file join $out nominal125] 4 12
    pdm_external_window [file join $out late_setup_negative] 4 12 206 5
    pdm_external_window [file join $out early_hold_negative] 4 12 106 -195
    puts "PDM_EXTERNAL_STA_ANALYSIS_DONE"
} message]} {puts "PDM_EXTERNAL_STA_ERROR $message";exit 1}
exit 0
