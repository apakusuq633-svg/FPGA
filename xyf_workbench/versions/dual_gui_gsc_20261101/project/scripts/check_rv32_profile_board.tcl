set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build rv32_mem_perf]
connect
targets -set -filter {name =~ "APU"};rst -system;after 500
targets -set -filter {name =~ "xc7z020*"};fpga -file [file join $out hw das_fir.bit]
targets -set -filter {name =~ "*Cortex-A9*#0"}
source [file join $out hw ps7_init.tcl];ps7_init;ps7_post_config
catch {stop}
dow [file join $out board_profile loader.elf]
con
after 2500
stop
set fp [open [file join $out board_profile telemetry.txt] w]
puts $fp [mrd -force 0xffff0000 1056]
close $fp
puts [mrd -force 0xffff0000 10]
puts "BOARD_PROFILE_TELEMETRY_SAVED"
disconnect
exit
