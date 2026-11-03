# Called with the routed design open and output_dir defined by the product flow.
report_utilization -hierarchical -file [file join $output_dir localizer_hierarchy.rpt]
set ram_cells [get_cells -hier -quiet -filter {IS_PRIMITIVE && REF_NAME =~ RAMB* && (NAME =~ */u_soc/g_localizer* || NAME =~ */u_soc/u_srp/* || NAME =~ */u_soc/u_core/u_fft_bfly/*)}]
set csv [open [file join $output_dir localizer_bram_locations.csv] w]
puts $csv "cell,primitive,site,write_mode_a,write_mode_b"
foreach cell $ram_cells {puts $csv "[get_property NAME $cell],[get_property REF_NAME $cell],[get_property LOC $cell],[get_property WRITE_MODE_A $cell],[get_property WRITE_MODE_B $cell]"}
close $csv
if {[llength $ram_cells]} {
    set pins [get_pins -of_objects $ram_cells -filter {DIRECTION == OUT}]
    report_timing -through $pins -delay_type max -max_paths 10 -file [file join $output_dir localizer_bram_paths.rpt]
}
report_timing -delay_type max -max_paths 10 -file [file join $output_dir localizer_critical_paths.rpt]
foreach {group pattern} {raw *raw_mem* prepared *prepared* spectrum *spectrum* phat *phi* srp_lut */u_srp/*lut_mem* srp_ring */u_srp/*r_mem* srp_score */u_srp/*p_mem*} {
    set group_cells [filter $ram_cells "NAME =~ $pattern"]
    if {[llength $group_cells]} {
        report_timing -through [get_pins -of_objects $group_cells -filter {DIRECTION == OUT}] -delay_type max -max_paths 3 -file [file join $output_dir localizer_${group}_paths.rpt]
    }
}
puts "LOCALIZER_PHYSICAL_REPORT bram_cells=[llength $ram_cells]"
