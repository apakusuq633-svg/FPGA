# Fresh local nine-microphone build; no programming commands.
set root [file normalize [file join [file dirname [info script]] ../..]]
if {[info exists ::env(GUI9_PYTHON)]} {
    set py $::env(GUI9_PYTHON)
} else {
    set py [auto_execok python]
}
if {$py eq ""} { error "Python not found: set GUI9_PYTHON or add python to PATH" }
set ::env(DAS_ACTIVE_CHANNELS) 9
set ::env(PDM_STREAM_DMA) 1
set ::env(ZYNQ_PROJ_DIR) [file join $root build gui9_impl]
set ::env(ZYNQ_OUTPUT_DIR) [file join $root build gui9_hw]
set proof [file join $root scripts circular9_routed_evidence.py]
puts [exec $py -I $proof begin --project $::env(ZYNQ_PROJ_DIR) --output $::env(ZYNQ_OUTPUT_DIR)]
source [file join $root scripts run_zynq_flow.tcl]
puts [exec $py -I $proof finish --project $::env(ZYNQ_PROJ_DIR) --output $::env(ZYNQ_OUTPUT_DIR)]
exit 0
