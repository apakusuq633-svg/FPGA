# Isolated implementation. Run only while no other Vivado build is active.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_shared_remediation vivado_interface]
if {$argc == 1} {set out [file normalize [lindex $argv 0]]}
if {[file exists $out]} {error "Output exists; choose a fresh destination instead of overwriting evidence"}
file mkdir $out
set fp [open [file join $out version.txt] w];puts $fp [version];close $fp
if {[catch {
    create_project pdm_interface [file join $out project] -part xc7z020clg400-1
    foreach f {rv32_pdm_clkgen.v rv32_pdm_cic.v rv32_pdm_array_rx.v} {read_verilog [file join $root rtl array $f]}
    read_verilog [file join $root scripts pdm_interface_timing_top.v]
    synth_design -top pdm_interface_timing_top -part xc7z020clg400-1
    create_clock -period 25 -name pl40 [get_ports clk_i]
    set_property PACKAGE_PIN N18 [get_ports clk_i]
    set_property IOSTANDARD LVCMOS33 [get_ports clk_i]
    set_false_path -from [get_ports rst_n_i]
    set_input_delay -clock pl40 -max 5 [get_ports en_i]
    set_input_delay -clock pl40 -min 0 [get_ports en_i]
    set_output_delay -clock pl40 -max 5 [get_ports {signature_o[*] sample_valid_o}]
    set_output_delay -clock pl40 -min 0 [get_ports {signature_o[*] sample_valid_o}]
    source [file join $root scripts apply_pdm_constraints.tcl]
    write_pdm_constraints [file join $root constrs ps_pl_wrapper.xdc] [file join $out full_profile.xdc] 6
    set fp [open [file join $out full_profile.xdc] r];set text [read $fp];close $fp
    set begin [string first {# PDM default:} $text]
    if {$begin < 0} {error "Missing PDM profile marker"}
    set fp [open [file join $out interface.xdc] w];puts $fp [string range $text $begin end];close $fp
    read_xdc [file join $out interface.xdc]
    opt_design
    place_design
    route_design
    write_checkpoint [file join $out routed.dcp]
    report_timing_summary -file [file join $out timing_summary.rpt]
    report_utilization -file [file join $out utilization.rpt]
    source [file join $root scripts report_pdm_interface.tcl]
    report_pdm_interface [file join $out interface_reports]
    puts "PDM_INTERFACE_IMPLEMENTATION_DONE_CONDITIONAL"
} message]} {puts "PDM_INTERFACE_IMPLEMENTATION_FAIL $message";exit 1}
exit 0
