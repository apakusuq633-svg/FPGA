# 在真硅上证明「RISC-V 核在跑」—— **不依赖 UART**。
#
#   xsct scripts/probe_core_alive.tcl
#
# ── 为什么不用 UART ──────────────────────────────────────────────────────
# `run_board.tcl` 跑完会提示「Read PS UART0 at 115200 8N1」，但本机串口那边
# 实测**一个字节都收不到**（`build/board_uart_*.log` 全是 0 字节），
# 而串口本身是打开成功的。与其继续猜 UART 走线/回环，不如换一个
# **走 JTAG、且判据是数值**的观测量 —— 反正 JTAG 已经通了。
#
# ── 判据 ────────────────────────────────────────────────────────────────
# `rv32_ps_regs.v` 把 retire 观测暴露在 AXI 上（`ADDR_RETIRE_CNT = 0x020`）：
#
#   RETIRE_CNT 在涨  ⇒ **核正在退休指令** ⇒ 固件真的在真硅上跑
#   TRAP_CNT 不变    ⇒ 没有异常陷阱
#
# LED 走马灯固件的 retire 计数会一直涨（它是个死循环），所以这个判据是稳的。
# ⚠ 别把「AXI 能读」当成「核在跑」：AXI 通只说明 PS↔PL 的总线活着。
#   今天之前一直缺的正是**这一条**。

# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）
source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set ws   D:/Vitis
set app  rv32_app

set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init [file join $ws PS-PL hw ps7_init.tcl]
set elf  [file join $ws $app Debug ${app}.elf]
foreach p [list $bit $init $elf] {
    if {![file isfile $p]} { error "缺文件: $p" }
}

set BASE 0x43C00000
proc rd {off} {
    if {[catch {set v [mrd -force [expr {0x43C00000 + $off}]]} e]} { error "mrd 失败: $e" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { error "mrd 解析失败: $s" }
    return [expr "0x$h"]
}

puts "==> 连接"
connect

# ⚠ 先选中 DAP 再 rst -system。板子重新上电后 APU 会短暂缺失，
#   而 `targets -set -filter {name =~ "APU"}` 在复位**之前**执行 ⇒ 先有鸡先有蛋。
#   见 scripts/probe_ps_recover.tcl。
if {[catch {targets -set -filter {name =~ "APU"}} e]} {
    puts "    APU 不在，先对 DAP 做 system reset"
    targets 1
    rst -system
    after 3000
}
targets -set -filter {name =~ "APU"}
# ⚠ **必须无条件复位**，不能在"APU 已经在"时跳过：A9 这时多半还在跑上一个
#   app，`ps7_init` 里的 DAP 读会报
#   "Memory read error ... Execution context is running"，看着像 ps7_init 坏了。
rst -system
after 1000
targets -set -filter {name =~ "xc7z020*"}
puts "==> 器件: [lindex [targets] 0]"
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config
rst -processor
dow $elf
con
after 2000

# ⚠ 让固件先跑一会儿，**再停下 A9** —— 不停就读不了（见 rd_retry 上面的注释）。
#   停下的是 A9；PL 里的 RV32 核**不受影响**，它继续跑，RETIRE_CNT 继续涨。
puts "==> 停 A9（PL 的 RV32 核不受影响，继续跑）"
stop
after 500

# ⚠ 每读一个就打印一个。DAP 会偶发 `AP transaction error`，而**异常会吃掉
#   之前读到的所有值** —— 第一次跑就是这么白跑的。另外重试几次，DAP 的错误
#   常常是瞬时的。
# ⚠⚠ **读之前必须把 A9 停下（`stop`）**。XSCT 的 `mrd` 是走 **A9 的执行上下文**
#    去访问内存的，A9 在跑（`con` 之后）时 DAP 直接拒绝：
#        Memory read error ... Cannot access virtual memory. Execution context is running
#    这就是本项目**真凶**：`test_pdm_onboard.tcl` 一直读得到，是因为它从来没让
#    A9 跑起来；而这里 `con` 之后马上读，就全失败。`ps7_init` 那次同源。
#    报错**要打出来** —— 被 catch 吃掉之后只剩"读失败"，看不出是哪一种失败。
proc rd_retry {off tag} {
    for {set k 0} {$k < 5} {incr k} {
        if {![catch {set v [rd $off]} e]} { puts "   $tag = $v"; return $v }
        puts "   $tag 第[expr {$k+1}]次失败: $e"
        after 300
    }
    return -1
}

puts ""
puts "==== 核状态（AXI 0x020 起）===="
set c1 [rd_retry 0x020 "RETIRE_CNT(1)"]
set t1 [rd_retry 0x030 "TRAP_CNT(1)  "]
after 1000
set c2 [rd_retry 0x020 "RETIRE_CNT(2)"]
set t2 [rd_retry 0x030 "TRAP_CNT(2)  "]
set pc [rd_retry 0x024 "RETIRE_PC   "]
set ins [rd_retry 0x028 "RETIRE_INS  "]
set cyc [rd_retry 0x040 "CYC_TOTAL   "]

puts ""
if {$c1 < 0 || $c2 < 0} {
    puts "PROBE_INCONCLUSIVE: RETIRE_CNT 没读全（DAP 不稳），无法判断核是否在跑"
} elseif {$c2 > $c1} {
    puts [format "CORE_ALIVE: 1 秒内退休 %d 条指令 —— RISC-V 核在真硅上运行 ✓" [expr {$c2 - $c1}]]
    if {$t1 >= 0 && $t2 > $t1} { puts "  ⚠ TRAP_CNT 在涨，固件可能进了异常" }
} else {
    puts "CORE_STUCK: RETIRE_CNT 没有前进 —— 核没在跑"
}

puts "PROBE_DONE"
disconnect
