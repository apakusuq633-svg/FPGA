# 只用 JTAG 把 RV32 核跑起来，证明它活着 —— 不经过 A9 app。
#
#   xsct scripts/probe_core_by_jtag.tcl
#
# ── ⚠ 先看这条更正，别信本文件旧版的说法 ────────────────────────────────
# 本文件**旧版**的头注释写着「一旦 `dow`+`con` 让 A9 跑起 app，DAP 必坏，
# 所以要用 JTAG 绕开」——**那个因果是错的**。真相是**另一个项目在抢同一块板子的
# JTAG**（见 [docs/issues/065]）：两个 XSCT 复用同一个 hw_server 互相踩，
# 表现为 `Cannot reset DAP ... 0x30000021`。当时只是**时间上巧合**：
# 我们跑 app 的那几次恰好对方也在访问。**已按 065 更正，别再照旧版理解。**
#
# ── 那这个探针现在还有什么用 ─────────────────────────────────────────────
# 它证明的是**硬件本身**：ITCM 装载通路 + 放核 + 核侧 MMIO，全程不依赖 PS 软件。
# 实测结果（2026-10-04）：
#     RETIRE_CNT 1 秒涨 40,825,093   ≈ 1 指令/周期 @40 MHz
#     TRAP_CNT = 0                    LED_STATE = 0x00000002
# ⇒ 补上 §68「RISC-V 正常运行」那个空勾，判据是**可测量的数**。
#
# 而且它现在有个**现实的**用处：**A9 app 那条路是坏的**（`con` 之后
# `Cannot halt processor core, timeout`，PL 侧 CTRL 停在 0x02、RETIRE_CNT=0
# ⇒ app 从没走到放核那一步）。在查清 A9 之前，这个探针是**唯一**能在真硅上
# 跑起核并留下证据的路。两条路互不相干，别把它们混成一个问题。
#
# 寄存器与顺序全部照 `sw/ps_main.c`（它头注释里把协议写死了）：
#   CTRL=0x3 (START|HALT)  → 保持停止并清计数器
#   MEM_CTRL=1 (RST_ADDR)  → 地址自增计数器归零
#   逐个 mwr MEM_WDATA     → 固件推进 ITCM
#   CTRL=0x1               → 清 HALT，**核开始跑**
#   RETIRE_CNT 在涨        → 核在真硅上执行指令 ✓

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set fw   [file join $root sw led_demo.h]
# ps7_init 在 Vitis 工作区里，不在仓库里（脚本目录推不出来），单独写
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
foreach p [list $bit $init $fw] { if {![file isfile $p]} { error "缺文件: $p" } }

set BASE 0x43C00000
set R_CTRL      0x000
set R_STATUS    0x004
set R_RETIRE    0x020
set R_TRAP      0x030
set R_MEM_ADDR  0x080
set R_MEM_WDATA 0x084
set R_MEM_CTRL  0x08C

proc wr {off v} { if {[catch {mwr -force [expr {0x43C00000 + $off}] $v} e]} { error "mwr $off: $e" } }
proc rd {off} {
    if {[catch {set v [mrd -force [expr {0x43C00000 + $off}]]} e]} { error "mrd $off: $e" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { error "mrd 解析失败: $s" }
    return [expr "0x$h"]
}

# 从 led_demo.h 里把固件字抠出来（形如 `0xFE0312E3,`）
set fp [open $fw r]
set text [read $fp]
close $fp
set words {}
# 只收 `0x........,`（行尾带逗号）那种 —— 文件里还有别的十六进制常量（如立即数注释）
foreach line [split $text "\n"] {
    if {[regexp {^\s*0x([0-9A-Fa-f]{8})\s*,} $line -> w]} { lappend words "0x$w" }
}
if {[llength $words] < 8} { error "led_demo.h 里只抠到 [llength $words] 个字，解析失败" }
puts "==> 固件 [llength $words] 个字"

puts "==> 连接"
connect
if {[catch {targets -set -filter {name =~ "APU"}} e]} {
    targets 1; rst -system; after 3000
}
targets -set -filter {name =~ "APU"}
rst -system
after 1000
targets -set -filter {name =~ "xc7z020*"}
puts "==> 器件: [lindex [targets] 0]"
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config

# ⚠ 千万不要 `con`。A9 停在原地就好；下面全部由 JTAG 完成。
# ⚠ `stop` 对**已经停止**的目标会抛 "Already stopped" —— 那是个良性错误，
#   但它会把整个脚本带停（实测就是这样白跑了一次）。包起来。
if {[catch {stop} e]} { puts "   (stop: $e —— 本来就停着，继续)" }
after 300

puts ""
puts "==== 1. 保持 HALT 并清计数器 (CTRL=0x3) ===="
wr $R_CTRL 0x3
after 50
puts [format "   CTRL readback = 0x%08X" [rd $R_CTRL]]

puts "==== 2. 归零自增地址 (MEM_CTRL=1) ===="
wr $R_MEM_CTRL 1
after 50

puts "==== 3. 推固件进 ITCM ===="
set i 0
foreach w $words {
    wr $R_MEM_WDATA $w
    incr i
    if {[catch {set a [rd $R_MEM_ADDR]} e]} { error "第 $i 个字后读 MEM_ADDR 失败: $e" }
}
after 100
puts "   推了 [llength $words] 个字；MEM_ADDR 现在 = 0x[format %08X [rd $R_MEM_ADDR]]"

puts "==== 4. 放核 (CTRL=0x1，清 HALT) ===="
wr $R_CTRL 0x1
after 100
puts [format "   CTRL readback = 0x%08X" [rd $R_CTRL]]

puts ""
puts "==== 5. 核在跑吗（RETIRE_CNT 两次相减）===="
set c1 [rd $R_RETIRE]
set t1 [rd $R_TRAP]
after 1000
set c2 [rd $R_RETIRE]
set t2 [rd $R_TRAP]
puts [format "   RETIRE_CNT: %u -> %u  (差 %d)" $c1 $c2 [expr {$c2 - $c1}]]
puts [format "   TRAP_CNT  : %u -> %u" $t1 $t2]
puts [format "   LED_STATE : 0x%08X" [rd 0x090]]

puts ""
if {$c2 > $c1} {
    puts [format "CORE_ALIVE: 1 秒退休 %d 条指令 —— RISC-V 核在真硅上运行 ✓（全程只用 JTAG，没跑 A9 app）" [expr {$c2 - $c1}]]
} else {
    puts "CORE_STUCK: RETIRE_CNT 没前进"
}
puts "PROBE_DONE"
disconnect
