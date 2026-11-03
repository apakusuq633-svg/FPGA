# ⚠⚠ 更正：本文件是照着**一个错误的因果**写的，先读这段再看下面。
#
# 它当时的假设是「跑 A9 app 会把 JTAG 的 DAP 弄坏」，于是想二分出是哪一步。
# **那个因果不成立** —— 真相是**另一个项目（multichannel_acoustic）在抢同一块板子的
# JTAG**：两个 XSCT 复用同一个 hw_server 互相踩，表现为 Cannot reset DAP。
# 「跑 app 之后必坏」纯粹是**时间巧合**。见 docs/issues/065。
#
# ⇒ **别再拿它去追"是谁弄坏了 DAP"**。它现在唯一的价值是：将来真出现 DAP 问题时，
#   可以按步二分「下位流 / dow / con」哪一步使 DAP 不可用。但**第一步永远是先跑
#   scripts/check_jtag_owner.ps1 排除别人在抢** —— 那是本次真正的原因。

# 二分：**到底是哪一步把 JTAG 的 DAP 弄坏的？**
#
#   xsct scripts/probe_dap_bisect.tcl
#
# ── 为什么要做这个 ──────────────────────────────────────────────────────
# 实测对照（都是真跑出来的）：
#   * `test_pdm_onboard.tcl` —— 下位流 + `ps7_init`，然后反复 `mrd`/`mwr`，
#     **从不让 A9 跑 app** ⇒ DAP **一直正常**，跑了很多次都没事。
#   * `run_board.tcl` / `probe_core_alive.tcl` —— `dow` + **`con` 让 app 跑起来**
#     ⇒ **之后 DAP 就坏**（`Cannot reset DAP. AP transaction error,
#     DAP status 0x30000021`），而且**不断电不恢复**。已复现两次。
#
# 所以怀疑对象就是「让 A9 跑 app」这个动作。但中间有好几步，得逐个切开。
#
# ── 每步都试读一次 ──────────────────────────────────────────────────────
# 判据：**哪一步做完之后 `mrd` 开始失败，就是它。**
# ⚠ 读之前先 `stop` —— A9 在跑的时候 `mrd` 会报
#   "Execution context is running"，那是**另一种**失败，别混进来。
#
# ⚠ 每败一次都要**断电重上电**才能继续（`rst -system` 这时也做不了）。
#   所以这个脚本一次跑完所有步，中途一失败就停在那里报告。

set root [file normalize [file join [file dirname [info script]] ..]]
set ws   D:/Vitis
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init [file join $ws PS-PL hw ps7_init.tcl]
set elf  [file join $ws rv32_app Debug rv32_app.elf]
foreach p [list $bit $init $elf] { if {![file isfile $p]} { error "缺文件: $p" } }

# B 口（vitis/ITCM 窗口）与 AXI 寄存器都在 0x43C00000 这 4 KB 里
proc try_read {tag} {
    if {[catch {set v [mrd -force 0x43C00000]} e]} {
        puts "  [$tag] 读失败: $e"
        return 0
    }
    puts "  [$tag] 读到了: $v"
    return 1
}

puts "==> 连接"
connect

# 先确保 APU 在。刚上电时它可能短暂缺失（见 issues/064）。
if {[catch {targets -set -filter {name =~ "APU"}} e]} {
    puts "    APU 不在，先对 DAP 做 system reset"
    targets 1
    rst -system
    after 3000
}
targets -set -filter {name =~ "APU"}
rst -system
after 1000
targets -set -filter {name =~ "xc7z020*"}
puts "==> 器件: [lindex [targets] 0]"

puts ""
puts "==== 步 1：下位流 ===="
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config
stop
after 300
if {![try_read "步1 下位流+ps7_init 之后"]} { puts "BISECT_STOP: 步 1"; exit 0 }

puts ""
puts "==== 步 2：dow（只下载，不运行）===="
rst -processor
dow $elf
stop
after 300
if {![try_read "步2 dow 之后"]} { puts "BISECT_STOP: 步 2"; exit 0 }

puts ""
puts "==== 步 3：con（真的跑起来），2 秒后 stop 再读 ===="
con
after 2000
stop
after 300
if {![try_read "步3 con+stop 之后"]} { puts "BISECT_STOP: 步 3（con 之后 DAP 不可用）—— 注意：先按 065 排除别人抢板子，别急着下因果结论"; exit 0 }

puts ""
puts "==== 步 4：再 con 一次，只是确认可重复 ===="
con
after 1000
stop
after 300
if {![try_read "步4 第二次 con 之后"]} { puts "BISECT_STOP: 步 4"; exit 0 }

puts ""
puts "BISECT_DONE: 四步全过 —— DAP 没坏，问题不在这个序列里"
disconnect
