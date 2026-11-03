# Volatile PL programming only; no flash, PS reset, DDR or external power writes.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build pdm_ila_20261021]
set label baseline
if {$argc > 0} {set label [lindex $argv 0]}
set artifact $out
if {$argc > 2} {set artifact [file join $out [lindex $argv 2]]}
source [file join $root scripts jtag_guard.tcl]
open_hw_manager
connect_hw_server
open_hw_target
try {
set dev [get_hw_devices xc7z020_1]
if {[llength $dev] != 1 || [get_property PART $dev] ne "xc7z020"} {error "Unexpected FPGA"}
current_hw_device $dev
set_property PROBES.FILE [file join $artifact pdm_ila.ltx] $dev
set_property FULL_PROBES.FILE [file join $artifact pdm_ila.ltx] $dev
if {$label eq "baseline" || ($argc > 1 && [lindex $argv 1] eq "--program")} {
  if {![file exists [file join $artifact io.rpt]] || ![file exists [file join $artifact pdm_ila.bit]]} {error "Missing audited build"}
  set_property PROGRAM.FILE [file join $artifact pdm_ila.bit] $dev
  program_hw_devices $dev
}
refresh_hw_device $dev
foreach ila [get_hw_ilas] {puts "PDM_ILA $ila CELL=[get_property CELL_NAME $ila]"}
set raw [get_hw_ilas -filter {CELL_NAME =~ *u_ila_raw*}]
set pcm [get_hw_ilas -filter {CELL_NAME =~ *u_ila_pcm*}]
if {[llength $raw] != 1 || [llength $pcm] != 1} {error "Expected two ILAs"}
if {[info exists ::env(PDM_EDGE_NAMED_PROBES)] && $::env(PDM_EDGE_NAMED_PROBES) eq "1"} {
  foreach name {DATA1_RAW U1_LOW_SLOT_HELD U2_INPUT_FF U1_LOW_SLOT_EN U2_HIGH_SLOT_EN PCM_VALID CLK_PDM} bit {0 4 8 12 13 14 15} {
    create_hw_probe -map [format {probe0[%d]} $bit] $name $raw
  }
}
foreach p [get_hw_probes -of_objects $pcm] {puts "PDM_PCM_PROBE $p"}
set raw_count 1
if {$argc > 4} {set raw_count [lindex $argv 4]}
for {set k 0} {$k < $raw_count} {incr k} {
  set suffix raw
  if {$k > 0} {set suffix raw$k}
  run_hw_ila -trigger_now $raw
  wait_on_hw_ila -timeout 15 $raw
  set data [upload_hw_ila_data $raw]
  write_hw_ila_data -force [file join $out ${label}_${suffix}.ila] $data
  write_hw_ila_data -force -csv_file [file join $out ${label}_${suffix}.csv] $data
}
set vp [get_hw_probes -of_objects $pcm -filter {NAME =~ *valid*}]
if {[llength $vp] != 1} {error "PCM valid probe missing"}
set_property CONTROL.CAPTURE_MODE BASIC $pcm
set_property CONTROL.CAPTURE_CONDITION AND $pcm
set_property CAPTURE_COMPARE_VALUE "eq1'b1" $vp
set_property TRIGGER_COMPARE_VALUE "eq1'b1" $vp
set_property CONTROL.TRIGGER_POSITION 0 $pcm
report_property $pcm
report_property $vp
# Optional coordination for live acoustic tests: arm only after the operator
# has been prompted to speak. Timeout returns the board to idle via finally.
if {[info exists ::env(PDM_CAPTURE_GO_FILE)]} {
  if {![info exists ::env(PDM_CAPTURE_READY_FILE)]} {error "Acoustic ready file missing"}
  set ready_fd [open $::env(PDM_CAPTURE_READY_FILE) w]
  puts $ready_fd "READY $label";close $ready_fd
  puts "PDM_ACOUSTIC_READY $label"
  set deadline [expr {[clock milliseconds]+60000}]
  while {![file exists $::env(PDM_CAPTURE_GO_FILE)]} {
    if {[clock milliseconds]>$deadline} {error "Acoustic start timeout"}
    after 100
  }
}
for {set k 0} {$k < 3} {incr k} {
  run_hw_ila $pcm
  wait_on_hw_ila -timeout 15 $pcm
  set data [upload_hw_ila_data $pcm]
  write_hw_ila_data -force [file join $out ${label}_pcm${k}.ila] $data
  write_hw_ila_data -force -csv_file [file join $out ${label}_pcm${k}.csv] $data
}
puts "PDM_ILA_CAPTURE_PASS label=$label"
} finally {
  if {$argc > 3 && [lindex $argv 3] eq "--idle-after" && [info exists dev] && [llength $dev] == 1} {
    set_property PROBES.FILE {} $dev
    set_property FULL_PROBES.FILE {} $dev
    set_property PROGRAM.FILE [file join $out idle pdm_idle.bit] $dev
    program_hw_devices $dev
    puts "PDM_IDLE_AFTER_CAPTURE_PASS clock_V16=constant_0"
  }
}
exit
