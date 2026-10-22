# Analysis-only qualification clocks. Never add the exported XDC to a build.
proc pdm_external_window {out hold consume {dmax 106.0} {dmin 5.0} {uncertainty 2.0}} {
    file mkdir $out
    set root_name ""
    foreach c [get_clocks] {
        if {[get_property PERIOD $c] == 25.0} {set root_name [get_property SOURCE_PINS $c];break}
    }
    if {$root_name eq ""} {error "Missing 40MHz master"}
    set source [get_ports -quiet $root_name]
    if {![llength $source]} {set source [get_pins $root_name]}
    set a [get_cells -hier -filter {NAME =~ *phase_a_q_reg*}]
    set b [get_cells -hier -filter {NAME =~ *g_phase_b.u_cic_b/bit_q_reg}]
    set lines [llength [get_ports {pdm_din_i[*]}]]
    if {$lines < 1 || [llength $a]!=$lines || [llength $b]!=$lines} {error "Sampling cell count does not match DATA ports"}
    set ::pdm_window_hold $hold
    set ::pdm_window_consume $consume
    reset_timing
    create_clock -name PDM_MODEL_SYS -period 25.000 $source
    create_generated_clock -name PDM_PAD -source $source -edges {17 33 49} [get_ports pdm_clk_o]
    set captures {}
    foreach group {A B} cells [list $a $b] tick [list $hold $consume] {
        set i 0
        foreach cell $cells {
            set name PDM_SAMPLE_${group}_${i}
            set edge [expr {2*($tick+1)+1}]
            create_generated_clock -name $name -source $source -edges [list $edge [expr {$edge+16}] [expr {$edge+32}]] [get_pins -of_objects $cell -filter {REF_PIN_NAME == C}]
            lappend captures [get_clocks $name]
            incr i
        }
    }
    set din [get_ports {pdm_din_i[*]}]
    # max: tDV100 + PCB CLK3 + PCB DATA3; output and input FPGA arcs are propagated.
    # min: earliest invalidation tHZ5 after the OPPOSITE physical pad edge.
    foreach edge {rise fall} {
        set opt {}
        if {$edge eq "fall"} {set opt {-clock_fall}}
        set_input_delay -clock PDM_PAD -max $dmax -add_delay {*}$opt $din
        set_input_delay -clock PDM_PAD -min $dmin -add_delay {*}$opt $din
    }
    # Separate setup launch and hold invalidation edges, retaining both physical arcs.
    set_false_path -setup -rise_from [get_clocks PDM_PAD] -to $a
    set_false_path -hold -fall_from [get_clocks PDM_PAD] -to $a
    set_false_path -setup -fall_from [get_clocks PDM_PAD] -to $b
    set_false_path -hold -rise_from [get_clocks PDM_PAD] -to $b
    set_clock_uncertainty -setup $uncertainty -from [get_clocks PDM_PAD] -to $captures
    set_clock_uncertainty -hold $uncertainty -from [get_clocks PDM_PAD] -to $captures
    report_clocks -file [file join $out clocks.rpt]
    report_timing -from $din -to [concat $a $b] -delay_type max -max_paths 24 -path_type full_clock_expanded -file [file join $out setup.rpt]
    report_timing -from $din -to [concat $a $b] -delay_type min -max_paths 24 -path_type full_clock_expanded -file [file join $out hold.rpt]
    write_xdc -force [file join $out ANALYSIS_ONLY_NOT_FOR_BUILD.xdc]
    set fp [open [file join $out paths.csv] w]
    puts $fp "group,cell,kind,slack,requirement,datapath,source_clock_delay,capture_clock_delay,source_edge,capture_edge,exception"
    set summary [open [file join $out summary.txt] w]
    foreach group {A B} cells [list $a $b] {
        foreach kind {max min} {
            set worst 10000.0
            foreach cell $cells {
                set paths [get_timing_paths -from $din -to $cell -delay_type $kind -max_paths 1]
                if {[llength $paths]!=1} {error "Missing $group $kind path for $cell"}
                set p [lindex $paths 0]
                set ex [get_property EXCEPTION $p]
                if {[string match *datapath_only* $ex]} {error "Old max datapath exception survived"}
                set slack [get_property SLACK $p]
                if {$slack < $worst} {set worst $slack}
                puts $fp "$group,$cell,$kind,$slack,[get_property REQUIREMENT $p],[get_property DATAPATH_DELAY $p],[get_property STARTPOINT_CLOCK_DELAY $p],[get_property ENDPOINT_CLOCK_DELAY $p],[get_property STARTPOINT_CLOCK_EDGE $p],[get_property ENDPOINT_CLOCK_EDGE $p],$ex"
            }
            puts $summary "$group $kind $worst"
        }
    }
    close $fp;close $summary
    puts "PDM_WINDOW_ANALYSIS_DONE hold=$hold consume=$consume dmax=$dmax dmin=$dmin"
}

# Mandatory acceptance gate, not just a report writer. Operates on the loaded model.
proc pdm_assert_window {} {
    set din [get_ports {pdm_din_i[*]}]
    set lines [llength $din]
    if {$lines < 1} {error "Missing DATA ports"}
    set checked 0
    foreach pattern {*phase_a_q_reg* *g_phase_b.u_cic_b/bit_q_reg} {
        set cells [get_cells -hier -filter "NAME =~ $pattern"]
        if {[llength $cells]!=$lines} {error "Sampling endpoint count mismatch for $pattern"}
        set sample_ns [expr {($::pdm_window_hold+1)*25.0}]
        if {$pattern eq "*g_phase_b.u_cic_b/bit_q_reg"} {set sample_ns [expr {($::pdm_window_consume-7)*25.0}]}
        foreach cell $cells {
            foreach kind {max min} requirement [list $sample_ns [expr {$sample_ns-200.0}]] {
                set paths [get_timing_paths -from $din -to $cell -delay_type $kind -max_paths 1]
                if {[llength $paths]!=1} {error "Missing $kind path for $cell"}
                set p [lindex $paths 0]
                if {[get_property EXCEPTION $p] ne ""} {error "Unexpected timing exception for $cell"}
                if {[get_property REQUIREMENT $p] != $requirement} {error "Wrong sampling phase for $cell"}
                if {[get_property STARTPOINT_CLOCK_DELAY $p]<=0 || [get_property ENDPOINT_CLOCK_DELAY $p]<=0} {error "Missing propagated clock for $cell"}
                if {[get_property SLACK $p]<0} {error "External $kind failure at $cell slack=[get_property SLACK $p]"}
                incr checked
            }
        }
    }
    if {$checked!=4*$lines} {error "Incomplete endpoint coverage"}
    puts "PDM_EXTERNAL_ENDPOINTS_PASS endpoints=[expr {2*$lines}] checks=$checked hardware=UNVERIFIED_HARDWARE"
}
