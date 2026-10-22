# Run after route_design in the intended design. No hardware access.
proc report_pdm_interface {out_dir} {
    file mkdir $out_dir
    set din [get_ports {pdm_din_i[*]}]
    set pout [get_ports pdm_clk_o]
    if {[llength $din] != 6 || [llength $pout] != 1} {error "Expected six DATA and one CLOCK port"}
    report_timing -from $din -delay_type max -max_paths 24 -path_type full_clock_expanded -file [file join $out_dir data_max.rpt]
    report_timing -from $din -delay_type min -max_paths 24 -path_type full_clock_expanded -file [file join $out_dir data_min.rpt]
    report_timing -to $pout -delay_type max -max_paths 4 -path_type full_clock_expanded -file [file join $out_dir clock_max.rpt]
    report_timing -to $pout -delay_type min -max_paths 4 -file [file join $out_dir clock_min.rpt]
    report_exceptions -coverage -file [file join $out_dir exceptions.rpt]
    report_cdc -details -file [file join $out_dir cdc.rpt]
    set endpoints {}
    foreach port $din {
        set paths [get_timing_paths -from $port -delay_type max -nworst 24 -max_paths 24]
        if {[llength $paths] < 2} {error "Missing A/B timing paths for $port"}
        foreach path $paths {
            set endpoint [get_property ENDPOINT_PIN $path]
            lappend endpoints $endpoint
            if {[get_property SLACK $path] < 0} {error "PDM DATA datapath budget failed"}
        }
    }
    set clock_paths [get_timing_paths -to $pout -delay_type max -max_paths 4]
    if {[llength $clock_paths] == 0} {error "CLOCK budget is not analyzed"}
    foreach path $clock_paths {if {[get_property SLACK $path] < 0} {error "PDM CLOCK datapath budget failed"}}
    set fp [open [file join $out_dir status.txt] w]
    puts $fp "PDM_MAX_DATAPATH_PASS_CONDITIONAL_HOLD_ANALYTIC_ONLY"
    puts $fp "DATA endpoints: [lsort -unique $endpoints]"
    puts $fp "Board delays, power, pin wiring and actual relative clock skew remain UNVERIFIED_HARDWARE."
    close $fp
}
