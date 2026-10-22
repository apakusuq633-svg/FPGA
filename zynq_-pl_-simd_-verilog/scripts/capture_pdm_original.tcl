# Volatile PL only, capture the original ILA and added fast ILA when present.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
if {$argc!=2} {error "Usage: label artifact_subdirectory"}
set label [lindex $argv 0]
set artifact [file join $out [lindex $argv 1]]
if {![file exists [file join $artifact io.rpt]]} {error "Missing audited IO"}
source [file join $root scripts jtag_guard.tcl]
open_hw_manager
connect_hw_server
open_hw_target
set dev [get_hw_devices xc7z020_1]
if {[llength $dev]!=1 || [get_property PART $dev] ne "xc7z020"} {error "Unexpected device"}
try {
  current_hw_device $dev
  set_property PROBES.FILE [file join $artifact pdm_ila.ltx] $dev
  set_property FULL_PROBES.FILE [file join $artifact pdm_ila.ltx] $dev
  set_property PROGRAM.FILE [file join $artifact pdm_ila.bit] $dev
  program_hw_devices $dev
  refresh_hw_device $dev
  foreach ila [get_hw_ilas] {
    set kind stock
    if {[string match *u_ila_edge* [get_property CELL_NAME $ila]]} {set kind edge}
    if {$kind eq "edge"} {
      foreach name {DATA1_RAW DATA1_SYNC1 DATA1_SYNC2 CLK_PDM U1_LOW_SLOT_EN U2_HIGH_SLOT_EN U1_PCM_VALID U2_PCM_VALID} bit {0 1 2 3 4 5 6 7} {
        create_hw_probe -map [format {probe0[%d]} $bit] $name $ila
      }
      create_hw_probe -map {probe0[37:22]} {PCM_U1_LOW_SLOT[15:0]} $ila
      create_hw_probe -map {probe0[53:38]} {PCM_U2_HIGH_SLOT[15:0]} $ila
    }
    puts "PDM_ORIGINAL_CORE kind=$kind cell=[get_property CELL_NAME $ila]"
    foreach probe [get_hw_probes -of_objects $ila] {puts "PDM_ORIGINAL_PROBE [get_property NAME $probe] [get_property MAP $probe]"}
    for {set k 0} {$k<3} {incr k} {
      run_hw_ila -trigger_now $ila
      wait_on_hw_ila -timeout 15 $ila
      set data [upload_hw_ila_data $ila]
      write_hw_ila_data -force [file join $out ${label}_${kind}${k}.ila] $data
      write_hw_ila_data -force -csv_file [file join $out ${label}_${kind}${k}.csv] $data
    }
  }
  puts "PDM_ORIGINAL_CAPTURE_PASS $label"
} finally {
  set_property PROBES.FILE {} $dev
  set_property FULL_PROBES.FILE {} $dev
  set_property PROGRAM.FILE [file join $out idle pdm_idle.bit] $dev
  program_hw_devices $dev
  puts "PDM_ORIGINAL_IDLE_RESTORED"
}
exit
