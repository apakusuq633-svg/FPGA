set root [file normalize [file join [file dirname [info script]] ..]]
source [file join $root scripts jtag_guard.tcl]
open_hw_manager
connect_hw_server
open_hw_target
set dev [get_hw_devices xc7z020_1]
if {[llength $dev] != 1 || [get_property PART $dev] ne "xc7z020"} {error "Unexpected target"}
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
set_property PROGRAM.FILE [file join $root build pdm_ila_20261021 idle pdm_idle.bit] $dev
program_hw_devices $dev
puts "PDM_IDLE_PROGRAM_PASS clock_V16=constant_0 other_PL_IO=undriven flash=unchanged"
exit
