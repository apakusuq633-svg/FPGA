# Run in the Vivado Tcl console: source this file, then apply_pdm_constraints 8.
set pdm_constraints_root [file normalize [file join [file dirname [info script]] ..]]

proc write_pdm_constraints {template destination line_count} {
    if {$line_count ni {4 5 6 8}} {error "PDM constraint profile must have 4, 5, 6 or 8 DINs"}
    set fp [open $template r]
    fconfigure $fp -encoding utf-8
    set text [read $fp]
    close $fp
    set selected {}
    foreach line [split $text \n] {
        if {[regexp {^\s*(if|foreach|for|while|puts|source)\M} $line]} {
            error "Unsupported control flow in XDC template: $line"
        }
        if {[regexp {pdm_din_i\[([0-9]+)\]} $line -> index] && $index >= $line_count} {continue}
        lappend selected $line
    }
    if {$line_count == 5} {
        set extra [open [file join [file dirname $template] circular9_extra.xdc] r]
        lappend selected [read $extra]
        close $extra
    }
    file mkdir [file dirname $destination]
    set fp [open $destination w]
    fconfigure $fp -encoding utf-8 -translation lf
    puts -nonewline $fp [join $selected \n]
    close $fp
}

proc apply_pdm_constraints {{active_channels 8}} {
    global pdm_constraints_root
    if {$active_channels ni {4 8 9 12 16}} {error "Active channels must be 4, 8, 9, 12 or 16"}
    if {[llength [current_project -quiet]] == 0} {error "Open the intended project first"}
    set line_count [expr {$active_channels >= 8 ? ($active_channels+1)/2 : 8}]
    set project_dir [get_property DIRECTORY [current_project]]
    set destination [file join $project_dir generated_constraints ps_pl_wrapper.xdc]
    write_pdm_constraints [file join $pdm_constraints_root constrs ps_pl_wrapper.xdc] $destination $line_count
    set old_files [get_files -quiet -of_objects [get_filesets constrs_1] *ps_pl_wrapper.xdc]
    if {[llength $old_files]} {remove_files $old_files}
    add_files -fileset constrs_1 -norecurse $destination
    puts "PDM_CONSTRAINTS_APPLIED channels=$active_channels DINs=$line_count XDC=$destination"
    puts "Re-run synthesis and implementation before using a new bitstream."
}
