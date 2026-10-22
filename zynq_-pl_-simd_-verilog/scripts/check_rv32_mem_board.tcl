# Current bit/XSA and test-only RV32 image. No CPU RTL changes.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build rv32_mem_perf]
if {[info exists ::env(RV32_MEM_PERF_DIR)]} {set out [file normalize $::env(RV32_MEM_PERF_DIR)]}
set bit [file join $out hw das_fir.bit]
set init [file join $out hw ps7_init.tcl]
foreach p [list $bit $init [file join $out itcm.hex]] {if {![file isfile $p]} {error "MISSING $p"}}
proc wr {off value} {mwr -force [expr {0x43c00000+$off}] $value}
proc rd {off} {
 set s [mrd -force [expr {0x43c00000+$off}]]
 if {![regexp {([0-9A-Fa-f]+)\s*$} $s -> h]} {error "READ_PARSE $s"}
 return [expr "0x$h"]
}
connect
targets -set -filter {name =~ "APU"}
rst -system
after 500
targets -set -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config
catch {stop}
wr 0 3
puts "BOARD_MEM_HALT ctrl=[rd 0] status=[rd 4]"
set fp [open [file join $out itcm.hex] r];set words [split [string trim [read $fp]] "\n"];close $fp
wr 0x80 0
foreach w $words {wr 0x84 [expr "0x[string trim $w]"]}
wr 0x80 0
set errors 0
foreach w $words {if {[rd 0x88] != [expr "0x[string trim $w]"]} {incr errors}}
puts "BOARD_MEM_ITCM words=[llength $words] readback_errors=$errors"
if {$errors} {error "ITCM_VERIFY_FAIL"}
wr 0x80 0x80000000
for {set i 0} {$i<4096} {incr i} {
 wr 0x84 [expr {$i>=2560 && $i<2816 ? 0 : 0x80ff80ff}]
}
# FIR coefficient channel 1, all zero. CPU remains halted while programming.
wr 0xc0 0x400
for {set i 0} {$i<32} {incr i} {wr 0xc4 0}
wr 0x300 1
wr 0x308 512
wr 0x300 7
after 100
puts "BOARD_MEM_CAPTURE ready=[rd 0x304] seq=[rd 0x310] first=[rd 0x314]"
wr 0x380 5
wr 0 1
after 30
if {[rd 0x34]!=0x600dcafe} {error "BOARD_MEM_FIRMWARE_NOT_DONE tohost=[rd 0x34] trap=[rd 0x30]"}
set trap [rd 0x30]
wr 0 3
wr 0x80 [expr {0x80000000 | (0x2800>>2)}]
set f [open [file join $out board_raw_cycles.csv] w];puts $f "id,rdcycle"
for {set i 1} {$i<=76} {incr i} {puts $f "$i,[rd 0x88]"}
close $f
set audio_drop [rd 0x390]
puts "BOARD_MEM_AUDIO drops=$audio_drop status=[rd 0x384]"
puts "BOARD_MEM_RESULT trap=$trap errors=$errors"
if {$trap || $errors || $audio_drop} {error "BOARD_MEM_FAIL"}
puts "BOARD_MEM_PERF_PASS cycles_archived=76"
disconnect
exit
