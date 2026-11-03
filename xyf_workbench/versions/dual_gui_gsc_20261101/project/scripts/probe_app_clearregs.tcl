# 对照实验：`rst -processor` 加不加 `-clear-registers`，A9 到底会不会执行我们的 ELF。
#
#   xsct scripts/probe_app_clearregs.tcl
#
# 背景：跑 `run_board.tcl -app rv32_app` 时 XSCT 报过
#   WARNING: If the reset is being triggered after powering on the device,
#            write bootloop at reset vector address (0xffff0000), or use
#            -clear-registers option, to avoid unpredictable behavior.
# 而实测现象与该警告吻合：**UART 一个字节都没有、CTRL 停在软复位默认值 (HALT=1)、
# RETIRE_CNT=0** —— 也就是 app 压根没跑起来。
#
# ⚠ 读之前先 `stop`：A9 在跑时 `mrd` 报 "Execution context is running"（良性）。
#   反过来 `stop` 对已停的目标报 "Already stopped"（也是良性）—— 两个都要包 catch。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
set elf  D:/Vitis/rv32_app/Debug/rv32_app.elf
foreach p [list $bit $init $elf] { if {![file isfile $p]} { error "缺文件: $p" } }

proc rd {off} {
    if {[catch {set v [mrd -force [expr {0x43C00000 + $off}]]} e]} { return "FAIL" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { return "PARSE" }
    return [expr "0x$h"]
}

connect
targets -set -filter {name =~ "APU"}
if {[catch {rst -system} e]} { puts "(rst -system: $e)" }
after 1000
targets -set -filter {name =~ "xc7z020*"}
puts "==> 器件: [lindex [targets] 0]"
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config

puts ""
puts "==== 关键一步：rst -processor **带 -clear-registers** ===="
if {[catch {rst -processor -clear-registers} e]} {
    puts "   带 -clear-registers 失败: $e"
    puts "   （该版本的 rst 可能不支持这个选项，见结论）"
} else {
    puts "   ok"
}
after 200

dow $elf
puts "   dow 完成，PC = [lindex [rrd pc] 0]"

# 先记下 con 之前的 CTRL，con 之后再读一次对比
if {[catch {stop} e]} { }
after 200
puts [format "   con 之前 CTRL = 0x%08X  RETIRE_CNT = %s" [rd 0x000] [rd 0x020]]

con
after 2500
if {[catch {stop} e]} { puts "   (stop: $e)" }
after 300
puts [format "   con 之后 CTRL = 0x%08X  RETIRE_CNT = %s  TRAP_CNT = %s  LED = 0x%08X" \
      [rd 0x000] [rd 0x020] [rd 0x030] [rd 0x090]]

puts ""
puts "   判读：RETIRE_CNT > 0 ⇒ app 跑起来并放核成功 ✓（那就是 -clear-registers 的功劳）"
puts "         RETIRE_CNT = 0 ⇒ 加了这个选项也没用，问题在别处"
puts "PROBE_DONE"
disconnect
