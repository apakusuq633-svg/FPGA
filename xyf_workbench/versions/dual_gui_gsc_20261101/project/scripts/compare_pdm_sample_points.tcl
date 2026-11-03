# Three independent experiment designs. Production RTL defaults are never edited.
set root [file normalize [file join [file dirname [info script]] ..]]
set base [file join $root build pdm_convergence phase_impl]
if {$argc==1} {set base [file normalize [lindex $argv 0]]}
if {[file exists $base]} {error "Fresh output directory required"}
file mkdir $base
source [file join $root scripts apply_pdm_constraints.tcl]
source [file join $root scripts pdm_external_window.tcl]
if {[catch {
    foreach ns {125 150 175} h {4 5 6} c {12 13 14} {
        set out [file join $base $ns];file mkdir $out
        create_project phase_$ns [file join $out project] -part xc7z020clg400-1
        foreach f {rv32_pdm_clkgen.v rv32_pdm_cic.v rv32_pdm_array_rx.v} {read_verilog [file join $root rtl array $f]}
        read_verilog [file join $root scripts pdm_interface_timing_top.v]
        synth_design -top pdm_interface_timing_top -part xc7z020clg400-1 -generic [list HOLD_TICK=$h CONSUME_TICK=$c]
        create_clock -name pl40 -period 25 [get_ports clk_i]
        set_property PACKAGE_PIN N18 [get_ports clk_i]
        set_property IOSTANDARD LVCMOS33 [get_ports clk_i]
        set_false_path -from [get_ports rst_n_i]
        set_input_delay -clock pl40 -max 5 [get_ports en_i]
        set_input_delay -clock pl40 -min 0 [get_ports en_i]
        set_output_delay -clock pl40 -max 5 [get_ports {signature_o[*] sample_valid_o}]
        set_output_delay -clock pl40 -min 0 [get_ports {signature_o[*] sample_valid_o}]
        write_pdm_constraints [file join $root constrs ps_pl_wrapper.xdc] [file join $out profile.xdc] 6
        set fp [open [file join $out profile.xdc] r];set text [read $fp];close $fp
        set begin [string first {# PDM default:} $text]
        set fp [open [file join $out interface.xdc] w];puts $fp [string range $text $begin end];close $fp
        read_xdc [file join $out interface.xdc]
        opt_design;place_design;route_design
        write_checkpoint [file join $out routed.dcp]
        report_timing_summary -file [file join $out internal_timing.rpt]
        report_utilization -file [file join $out utilization.rpt]
        pdm_external_window [file join $out external_window] $h $c
        puts "PDM_PHASE_IMPLEMENTED ns=$ns h=$h c=$c"
        close_project
    }
    puts "PDM_PHASE_COMPARISON_DONE"
} message]} {puts "PDM_PHASE_COMPARISON_ERROR $message";exit 1}
exit 0
