# Full 9-channel PL plus independent HP0 raw/beam stream for PS GSC.
set circular9_root [file normalize [file join [file dirname [info script]] ..]]
set ::env(DAS_ACTIVE_CHANNELS) 9
set ::env(PDM_STREAM_DMA) 1
if {![info exists ::env(ZYNQ_PROJ_DIR)]} {set ::env(ZYNQ_PROJ_DIR) [file join $circular9_root build circular9_gsc_impl]}
set ::env(ZYNQ_OUTPUT_DIR) [file join $circular9_root build circular9_gsc]
source [file join $circular9_root scripts run_zynq_flow.tcl]
