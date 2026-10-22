# XSCT 2020.2: test the PL tacho input directly, with the RV32 core halted.
# Current Navigator Zynq-7010 bitstream: FCLK=40 MHz, J3.25/R18, 0..3.3 V.
# ⚠ 引脚号只是给人看的说明文字，不是程序输入 —— 真正生效的是位流里固化的约束。
#   改了 ps_pl_wrapper.xdc 的引脚就必须重出位流，否则这里会拿旧脚去量。
# No ELF, codec initialization or UART is needed. A real run resets the board.
set root [file normalize [file join [file dirname [info script]] ..]]
set ws D:/Vitis
set seconds 30
set expected_hz 25.0
set check_only 0
for {set i 0} {$i < [llength $argv]} {incr i} {
    set option [lindex $argv $i]
    switch -- $option {
        -check { set check_only 1 }
        -ws - -seconds - -hz {
            incr i
            if {$i >= [llength $argv]} { error "Missing value for $option" }
            set value [lindex $argv $i]
            switch -- $option {
                -ws { set ws $value }
                -seconds { set seconds $value }
                -hz { set expected_hz $value }
            }
        }
        default { error "Usage: test_tacho.tcl ?-hz 25? ?-seconds 30? ?-ws D:/Vitis? ?-check?" }
    }
}
if {![string is integer -strict $seconds] || $seconds < 1 || $seconds > 3600} {
    error "-seconds must be an integer from 1 to 3600"
}
if {![string is double -strict $expected_hz] || !($expected_hz > 1.0 && $expected_hz <= 1000.0)} {
    error "-hz must be greater than 1 and at most 1000 (one-second loss timeout)"
}
set bit [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init [file join $ws PS-PL hw ps7_init.tcl]
foreach path [list $bit $init] {
    if {![file isfile $path]} { error "Build artifact missing: $path" }
    puts "Artifact: $path"
}

proc tacho_read {address} {
    # XSCT -value returns numeric Tcl values, not the formatted hex display.
    return [expr {[lindex [mrd -value $address] 0] & 0xffffffff}]
}

proc tacho_snapshot {} {
    # cfg32..38: period, age, stamp, sample index, edge count, timeout, flags.
    # Reject reads straddling an edge; these registers have no snapshot latch.
    for {set attempt 0} {$attempt < 8} {incr attempt} {
        set before [tacho_read 0x43C00190]
        set words [mrd -value 0x43C00180 7]
        set after [tacho_read 0x43C00190]
        if {[llength $words] != 7} { error "Incomplete tacho register read" }
        set clean {}
        foreach word $words { lappend clean [expr {$word & 0xffffffff}] }
        if {$before == $after && $before == [lindex $clean 4]} { return $clean }
    }
    return {}
}

if {$check_only} {
    puts "CHECK OK: paths and arguments validated; no hardware connection attempted."
    exit 0
}

connect
set failed [catch {
    targets -set -filter {name =~ "APU"}
    rst -system
    after 1000
    targets -set -filter {name =~ "xc7z020*"}
    fpga -file $bit
    targets -set -filter {name =~ "Cortex-A9 #0"}
    source $init
    ps7_init
    ps7_post_config
    rst -processor
    mwr 0x43C00000 0x12
    after 10
    if {([tacho_read 0x43C00004] & 4) == 0} { error "RV32 did not halt" }
    mwr 0x43C000AC 0
    mwr 0x43C00194 40000000
    if {[tacho_read 0x43C00194] != 40000000} { error "Tacho timeout write/readback failed" }

    puts "TACHO: FCLK=40000000 Hz, expected=$expected_hz Hz, timeout=1 s"
    puts "During this run: output ON, then OFF for over 2 s, then ON again."
    puts "sec,count,seen,valid,period_ticks,age_ms,pulse_hz,state"
    set start [clock milliseconds]
    set matched 0
    set mismatched 0
    while {[clock milliseconds] - $start < $seconds * 1000} {
        set snapshot [tacho_snapshot]
        set elapsed [expr {([clock milliseconds] - $start) / 1000.0}]
        if {[llength $snapshot] == 0} {
            puts [format "%.2f,,,,,,,RETRY_EDGE_DURING_READ" $elapsed]
        } else {
            lassign $snapshot period age stamp sample count timeout flags
            set seen [expr {($flags >> 1) & 1}]
            set valid [expr {$flags & 1}]
            set hz_text NA
            set state WAIT
            if {$seen} { set state LOST }
            if {$valid && $period > 0} {
                set hz [expr {40000000.0 / $period}]
                set hz_text [format %.3f $hz]
                set state FREQ_MISMATCH
                if {abs($hz - $expected_hz) <= $expected_hz * 0.01} {
                    set state OK
                    incr matched
                } else { incr mismatched }
            }
            puts [format "%.2f,%u,%u,%u,%u,%.3f,%s,%s" $elapsed $count $seen $valid $period [expr {$age / 40000.0}] $hz_text $state]
        }
        flush stdout
        after 500
    }
    puts "DONE: frequency-matched polls=$matched; mismatched valid polls=$mismatched."
    puts "Verify count growth, loss after output OFF, and recovery after output ON in this log."
    if {$matched == 0} { error "No valid input matching the requested frequency was observed" }
} message]
catch {disconnect}
if {$failed} {
    puts stderr "ERROR: $message"
    exit 1
}
exit 0
