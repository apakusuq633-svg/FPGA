# Fresh implementation; never programs a board or reuses old RTL evidence.
set c9_root [file normalize [file join [file dirname [info script]] ..]]
set ::env(DAS_ACTIVE_CHANNELS) 9
set ::env(PDM_STREAM_DMA) 1
set ::env(ZYNQ_PROJ_DIR) [file join $c9_root build c9opt]
set ::env(ZYNQ_OUTPUT_DIR) [file join $c9_root build circular9_optimized_hw]
set c9_python C:/msys64/ucrt64/bin/python.exe
set c9_proof [file join $c9_root scripts circular9_routed_evidence.py]
puts [exec $c9_python -I $c9_proof begin --project $::env(ZYNQ_PROJ_DIR) --output $::env(ZYNQ_OUTPUT_DIR)]
source [file join $c9_root scripts run_zynq_flow.tcl]
if {[catch {exec $c9_python -I $c9_proof finish --project $::env(ZYNQ_PROJ_DIR) --output $::env(ZYNQ_OUTPUT_DIR)} c9_error]} {
 puts "FLOW_FAIL: routed source evidence: $c9_error";exit 1
}
puts $c9_error
exit 0
