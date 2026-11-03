# Only invoked by the integrity-checked PowerShell entry with -Program.
if {$argc!=1} {error "Usage: program.tcl release_directory"}
set dir [file normalize [lindex $argv 0]]
source [file join $dir jtag_guard.tcl]
connect
targets -set -filter {name =~ "APU"}
rst -system
after 1000
targets -set -filter {name =~ "xc7z020*"}
fpga -file [file join $dir pl.bit]
targets -set -filter {name =~ "*Cortex-A9*#0"}
source [file join $dir ps7_init.tcl]
ps7_init
ps7_post_config
rst -processor
dow [file join $dir ps_ui.elf]
con
puts "FULL_GUI9_RUNNING"
disconnect
exit 0
