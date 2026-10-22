# A9 从 **OCM** 跑（绕开坏掉的 DDR）—— 验证「PS 侧能不能跑起来」。
#
#   xsct scripts/probe_a9_run_from_ocm.tcl
#
# ✅ **DDR 已于 2026-10-04 修好**（docs/issues/067），所以 OCM 这条路**不再是必需的**。
#    保留它的理由有两个：
#      1. DDR 万一再出问题，这是现成的退路（`run_board.tcl -elf <OCM版>` 即可）
#      2. 它是"只依赖片上 SRAM"的最小验证，用来把「PS 侧/PL 侧」与「DDR」两类故障分开
#    日常上板请直接用 `run_board.tcl -app rv32_app`（走 Vitis 的 DDR 版）。
#
# 为什么改成从 OCM 跑（判据链，别再回头查 DDR）：
#
#   probe_write_drop_ocm_vs_ddr.tcl 的对照实验：
#       往 OCM（片上 SRAM）写 128 字 -> **0 错**
#       往 DDR 写同样的 128 字        -> **11 错**，且只有低 16 位落盘
#     同一套 mwr 循环、同一种回读方式 => 不是 DAP/JTAG 的问题，**是 DDR 写不可靠**。
#
#   根因：核心板原理图（第 8 页）上 DDR3 是 **NT5CC256M16**（256M×16 = 4Gb，两颗 = 1GB），
#   而 scripts/ps7_config.tcl 配的是 **MT41K128M16**（128M×16 = 2Gb，512MB）。
#   4Gb 要 15 根行地址、2Gb 只要 14 根，tRCD/tRP/tRFC/tRAS 也整套不同
#   => 写时序余量不够 => 约 9% 的写丢掉。ps7_init 的 DDR PHY 校准**照样能过**
#   （它只看 PHY 能不能锁），所以一直没报错，被误判成正常。
#
#   这就是 board_io.md 在 2026-10-01 换 7020 核心板当天标成
#   「整个换板动作里风险最高的一项……在这件事做完之前」的那一条，**一直没做**。
#
# 在 DDR 参数修好之前，app 改从 OCM 跑：
#   app 实测 48 KB，OCM 可用 128 KB（低 128 KB 被 BootROM 占着），放得下。
#   链接脚本 sw/lscript_ocm.ld，ELF 在 build/a9_ocm/rv32_app_ocm.elf。
#
# ⚠ 仍然有风险：万一 app 执行到野生地址，PS 互连和 DAP 会一起锁死，需要断电重上电。
#   所以第 3 步先**在 main 上设断点**，确认 boot.S/crt0 走过去了再放它自由跑。
# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
set elf  [file join $root build a9_ocm rv32_app_ocm.elf]

# OCM 版 ELF 不在版本库里（是 build/ 下的产物）。没构建过就直接说清楚怎么构建，
# 而不是让 Tcl 抛一个 "couldn't open ... no such file"。
if {![file isfile $elf]} {
    puts "OCM 版 ELF 不存在：$elf"
    puts "先构建（在 zynq_-pl_-simd_-verilog 目录下）："
    puts "  bash scripts/build_a9_ocm.sh"
    exit 1
}

# 从 `arm-none-eabi-nm -n build/a9_ocm/rv32_app_ocm.elf | grep ' main$'` 得到。
# 链接脚本一改这里就要跟着改，所以下面第 1 步会**核对它确实是 main 的入口**
# （main 的开头是 push {..., lr}，ARM 编码 E92D4FF0 或类似）。
set MAIN_ADDR 0x00020948

proc fmt32 {v} { return [format "0x%08X" [expr {$v & 0xFFFFFFFF}]] }

proc rd1 {vaddr} {
    if {[catch {set s [mrd -force $vaddr 1]} e]} { return "ERR" }
    if {![regexp {([0-9A-Fa-f]{8})[ \t\r\n]*$} [string trim $s] -> h]} { return "?" }
    return [string tolower $h]
}
proc tryrd {off} {
    if {[catch {set v [mrd -force [expr {0x43C00000 + $off}]]} e]} { return "-" }
    if {![regexp {([0-9A-Fa-f]{8})[ \t\r\n]*$} [string trim [join $v " "]] -> h]} { return "-" }
    return [format "0x%08X" [expr "0x$h"]]
}

connect
targets -set -filter {name =~ "APU"}
catch {rst -system}
after 1000
targets -set -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
catch {ps7_init}
catch {ps7_post_config}
foreach core {0 1} {
    catch {targets -set -filter [list name =~ "*Cortex-A9*#$core"]}
    catch {rst -processor -clear-registers}
}
catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}
after 300

puts ""
puts "########## 步骤 1  dow 到 OCM 并核对 ##########"
if {[catch {dow $elf} e]} { puts "   dow 失败: $e"; catch {disconnect}; exit 1 }
puts "   dow OK: $elf"

# 从文件里取前 8 个字，和 OCM 里回读的比 —— OCM 实测零错误，这一步应该全对
set f [open $elf rb]
seek $f 0x010000 start
set data [read $f 32]
close $f
binary scan $data i* words
set bad 0
set i 0
foreach w $words {
    set a [fmt32 [expr {0x00020000 + $i*4}]]
    set want [string tolower [string range [fmt32 [expr {$w & 0xFFFFFFFF}]] 2 end]]
    set got [rd1 $a]
    if {$got ne $want} { puts "   $a want $want got $got"; incr bad }
    incr i
}
set verdict "BAD"
if {$bad == 0} { set verdict "OK" }
puts "   OCM 回读核对：$bad / 8 不符（$verdict）"

set mn [rd1 $MAIN_ADDR]
puts "   main 入口 $MAIN_ADDR 的第一个字 = 0x[string toupper $mn]"

puts ""
puts "########## 步骤 2  断点在 main，放进 boot.S ##########"
catch {bpadd -addr $MAIN_ADDR}
catch {puts "   bplist: [bplist]"}
catch {con}
after 1500

# `rrd pc` 回的是不带 0x 的裸十六进制，而 fmt32 给的是 "0x00020948"。
# 直接拿 `string range ... 2 end` 去比会把 "00020948" 削成 "020948"，
# 于是 PC 明明就是 main 也判成没到（这个 bug 真出现过，别再踩）。
proc hexnorm {s} {
    set s [string tolower [string trim $s]]
    regsub {^0x} $s "" s
    return $s
}

set reached 0
if {[catch {set p [rrd pc]} e]} {
    puts "   读 PC 失败（核在跑）: $e"
} else {
    puts "   读 PC = [lindex $p end]"
    if {[hexnorm [lindex $p end]] eq [hexnorm [fmt32 $MAIN_ADDR]]} { set reached 1 }
}

puts ""
puts "########## 步骤 3  放它自由跑，看 PS->PL 有没有真的写进去 ##########"
if {$reached} {
    puts "   \[ok\] **boot.S / crt0 全过，到达 main** —— A9 这条执行路径是通的"
} else {
    puts "   注意：没能确认停在 main。继续往下走，但判读时留个心眼。"
}
catch {bpdel -addr $MAIN_ADDR}
catch {con}
# 10 秒足够 app 走完：软复位 -> 灌 ITCM -> 放核 -> 6 轮 x 300 ms 采样 -> 打印 [5] 结果
# 和最后的 ===== PASS/FAIL =====。这段时间也正好用来抓 UART0（见 record_board_uart.ps1）。
after 10000
if {[catch {stop} e]} {
    puts "   stop 失败: $e   <= 可能卡住了；这条和以前不同，以前是从 DDR 跑才卡"
} else {
    puts "   stop OK"
    puts "   PL 侧寄存器（app 应该已经写过）："
    puts "     CTRL      = [tryrd 0x000]   (bit1=HALT；app 释放核后会清掉)"
    puts "     STATUS    = [tryrd 0x004]"
    puts "     RETIRE_CNT= [tryrd 0x020]   (RV32 核退休指令数)"
    puts "     TOHOST    = [tryrd 0x034]"
    puts "     LED_STATE = [tryrd 0x090]"
    puts "   判读：CTRL 的 HALT 被清掉、RETIRE_CNT 在涨 => app 跑到了「放核」那一步，"
    puts "         也就是 PS->PL 的 AXI 通路和 app 主体都是好的。"
}
puts ""
puts "OCM_RUN_DONE"
catch {disconnect}
