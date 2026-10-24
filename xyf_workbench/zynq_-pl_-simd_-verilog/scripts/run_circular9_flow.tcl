# Isolated build of the proposed board. Does not connect to JTAG or program hardware.
set circular9_root [file normalize [file join [file dirname [info script]] ..]]
set ::env(DAS_ACTIVE_CHANNELS) 9
set ::env(ZYNQ_PROJ_DIR) [file join $circular9_root build circular9_impl]
set ::env(ZYNQ_OUTPUT_DIR) [file join $circular9_root build circular9]
source [file join $circular9_root scripts run_zynq_flow.tcl]
