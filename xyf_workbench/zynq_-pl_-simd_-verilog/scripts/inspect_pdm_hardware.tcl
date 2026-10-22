source [file join [file dirname [info script]] jtag_guard.tcl]
open_hw_manager
connect_hw_server
open_hw_target
foreach dev [get_hw_devices] {
  puts "PDM_HW_DEVICE $dev PART=[get_property PART $dev]"
}
exit
