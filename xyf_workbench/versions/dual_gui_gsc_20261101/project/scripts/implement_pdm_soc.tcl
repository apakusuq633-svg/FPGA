# Full current SoC, fresh project, route/reports only. Never programs hardware.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_shared_remediation vivado_soc]
if {$argc > 0 && [lindex $argv 0] ne "--resume"} {set out [file normalize [lindex $argv 0]]}
set resume [expr {$argc > 0 && [lindex $argv end] eq "--resume"}]
if {[file exists $out] && !$resume} {error "Output already exists"}
file mkdir $out
set ::env(ZYNQ_PROJ_DIR) [file join $out project]
set ::env(DAS_ACTIVE_CHANNELS) 8
set ::env(LIVE16_LOCALIZATION) 1
if {[catch {
    if {$resume} {
        open_project [file join $out project rv32_zynq.xpr]
        reset_run synth_1
    } else {
        source [file join $root scripts create_zynq_project.tcl]
    }
    launch_runs synth_1 -scripts_only
    set core [get_runs ps_pl_u_rv32_ps_0_synth_1]
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized $core
    reset_run $core
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis incomplete"}
    launch_runs impl_1 -to_step route_design -jobs 4
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "Implementation incomplete"}
    open_run impl_1
    phys_opt_design
    route_design
    report_timing_summary -delay_type min_max -file [file join $out timing.rpt]
    report_utilization -file [file join $out utilization.rpt]
    report_io -file [file join $out io.rpt]
    write_checkpoint [file join $out routed.dcp]
    source [file join $root scripts report_pdm_interface.tcl]
    report_pdm_interface [file join $out interface_reports]
    set setup [get_property SLACK [get_timing_paths -delay_type max]]
    set hold [get_property SLACK [get_timing_paths -delay_type min]]
    if {$setup < 0 || $hold < 0} {error "Full SoC timing failed setup=$setup hold=$hold"}
    puts "PDM_SOC_IMPL_PASS_CONDITIONAL setup=$setup hold=$hold hardware=UNVERIFIED"
} message]} {puts "PDM_SOC_IMPL_FAIL $message";exit 1}
exit 0
