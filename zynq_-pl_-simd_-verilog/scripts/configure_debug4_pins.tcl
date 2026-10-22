# Generate one complete XDC; assigning overlapping package pins in an overlay fails.
set fp [open [file join $root constrs ps_pl_wrapper.xdc] r]
set pin_constraints [read $fp]
close $fp
foreach channel {0 3 4} old_pin {Y16 T14 W16} new_pin {T14 W16 Y16} {
    set old_line [format {set_property -dict {PACKAGE_PIN %s IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[%d]}]} $old_pin $channel]
    set new_line [format {set_property -dict {PACKAGE_PIN %s IOSTANDARD LVCMOS33 PULLDOWN true} [get_ports {pdm_din_i[%d]}]} $new_pin $channel]
    if {[string first $old_line $pin_constraints] < 0} { error "Base pin constraint changed" }
    set pin_constraints [string map [list $old_line $new_line] $pin_constraints]
}
set generated_xdc [file join $proj_dir debug4_wrapper.xdc]
set fp [open $generated_xdc w]
puts -nonewline $fp $pin_constraints
close $fp
foreach name {ps_pl_wrapper.xdc debug4_pins.xdc debug4_wrapper.xdc} {
    set old_files [get_files -quiet *$name]
    if {[llength $old_files]} { remove_files $old_files }
}
add_files -fileset constrs_1 -norecurse $generated_xdc
puts "DEBUG4_PINS_CONFIGURED: DIN0..3=T14/Y17/T15/W16 CLK=V16"
