# Read-only runtime status. Do not halt CPUs or pop the audio FIFO.
source [file join [file dirname [info script]] jtag_guard.tcl]
connect
targets -set -filter {name =~ "*Cortex-A9*#0"}
foreach offset {0x30 0x34 0x304 0x32c 0x330 0x380 0x384 0x390 0x39c 0x3c0} {
    set address [expr {0x43c00000+$offset}]
    puts [format "LIVE4_REG offset=0x%x value=%s" $offset [mrd -force -value $address]]
}
disconnect
exit
