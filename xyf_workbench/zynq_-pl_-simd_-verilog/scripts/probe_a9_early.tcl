# A9 一跑就"停不下来"（Cannot halt processor core, timeout）—— 那就**尽早停**，抓它在哪。
#
#   xsct scripts/probe_a9_early.tcl
#
# 已知（上一步实测）：
#   rst -processor -clear-registers → 选项有效但不解决问题
#   dow 完成（PC 读不出）→ con 之后 stop 超时
# 而**同样的硬件走纯 JTAG 灌 ITCM + 放核完全正常**（CORE_ALIVE），
# 所以卡点在 A9 的执行路径上，不在 PL / 板子 / 固件。
#
# 这里的做法：con 之后**只等 10 ms 就 stop**，逐次加长，看它是在哪一步没的。
# ⚠ 每个节点都包 catch —— `stop` 失败后 mrd 会跟着失败，不能让它带停脚本。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
set elf  D:/Vitis/rv32_app/Debug/rv32_app.elf

proc tryrd {off} {
    if {[catch {set v [mrd -force [expr {0x43C00000 + $off}]]} e]} { return "-" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { return "-" }
    return [format "0x%08X" [expr "0x$h"]]
}
proc snapshot {tag} {
    if {[catch {stop} e]} { puts "   [$tag] stop 失败: $e" ; return 0 }
    puts [format "   [%s] 停住了  CTRL=%s RETIRE=%s TRAP=%s LED=%s" \
          $tag [tryrd 0x000] [tryrd 0x020] [tryrd 0x030] [tryrd 0x090]]
    return 1
}

connect
targets -set -filter {name =~ "APU"}
if {[catch {rst -system} e]} { }
after 1000
targets -set -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config
if {[catch {rst -processor -clear-registers} e]} { puts "(rst: $e)" }
after 200
dow $elf
if {[catch {stop} e]} { }
after 200
puts [format "==> con 之前: CTRL=%s RETIRE=%s" [tryrd 0x000] [tryrd 0x020]]

foreach d {10 30 100 300 1000} {
    puts ""
    puts "==== con 后等 $d ms 再停 ===="
    con
    after $d
    if {![snapshot "${d}ms"]} {
        puts "   ⇒ **在 $d ms 这个窗口里就停不住了** —— 卡点在这之前"
        break
    }
    # 停住之后不要 resume，直接进下一轮（每轮重新 con）
}

puts ""
puts "   判读：第一个失败的窗口就是卡死发生的地方；上一个成功的窗口里 PC 还有效"
puts "PROBE_DONE"
disconnect
