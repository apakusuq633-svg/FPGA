# 只读：看 A9 app 跑完之后，PL 侧到底成了什么状态。
#
#   xsct scripts/probe_ps_state.tcl
#
# 用途：区分「app 没跑起来」和「app 跑了但没做对事」。
# ⚠ 读之前必须 `stop` —— A9 在跑时 `mrd` 会报 "Execution context is running"。

source [file join [file dirname [info script]] jtag_guard.tcl]

proc rd {off} {
    if {[catch {set v [mrd -force [expr {0x43C00000 + $off}]]} e]} { return "FAIL($e)" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { return "PARSE($s)" }
    return [expr "0x$h"]
}

connect
targets -set -filter {name =~ "APU"}
if {[catch {stop} e]} { puts "   (stop: $e)" }
after 300
targets -set -filter {name =~ "*Cortex-A9*#0"}

puts "==== A9 看到的 PL 状态 ===="
foreach {name off} {CTRL 0x000 STATUS 0x004 RETIRE_CNT 0x020 RETIRE_PC 0x024 TRAP_CNT 0x030 TOHOST 0x034 LED_STATE 0x090} {
    puts [format "   %-11s = %s" $name [rd $off]]
}
puts ""
puts "   判读："
puts "     RETIRE_CNT = 0 且 CTRL 的 HALT 位 = 1  ⇒ app 没把核放起来（或没跑到那一步）"
puts "     RETIRE_CNT > 0                        ⇒ app 放核成功了"
disconnect
