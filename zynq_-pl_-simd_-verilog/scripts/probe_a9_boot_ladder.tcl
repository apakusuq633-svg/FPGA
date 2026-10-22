# A9「一 con 就停不住、还把 DAP 一起弄挂」的阶梯定位。
#
#   xsct scripts/probe_a9_boot_ladder.tcl
#
# ✅ **已结案（2026-10-04）**：根因是 DDR 颗粒型号配错（4Gb 的板配成 2Gb），
#    写 DDR 约 9% 丢掉 ⇒ `dow` 下去的 app 是坏的 ⇒ A9 执行到野生地址把互连锁死。
#    已按 7020 厂商例程把 `ps7_config.tcl` 的两条 DDR 参数改对，实测通过。
#    详见 docs/issues/067。
#
#    本脚本保留作**诊断工具**（阶梯本身没错，第 1 步的零风险 DDR 对照现在也仍然有用），
#    但**不要再把它的输出当成"还有 DDR 故障"的证据** —— 先看 docs/issues/067。
#
# 为什么要有这个脚本（上一轮实测的结论，别再重复走）：
#
#   测试 A  不下 app，直接 con + stop        -> **成功**，PC=0x10，PL 寄存器也读得到
#   测试 B  dow app 之后 con + stop          -> `AP transaction timeout`
#           之后连 A9#1 都报 DAP 0xF0000021
#
#   而且失败之后：换新 hw_server、换 JTAG 频率（3M/1M/500k/200k）、
#   `targets 1` + `rst -system`、disconnect/connect —— **全部无效**。
#   但 `fpga -file` 在 xc7z020 上仍然成功 ⇒ **JTAG 线缆和 PL TAP 完好，
#   坏的只有 PS 侧的 DAP**，只有 PS 级复位（断电重上电）能清。
#
#   ⇒ 结论：不是「核停不住」，是 **A9 执行某个永不完成的访问，把 PS 互连
#     连同 DAP 一起锁死**。所以每跑一次失败的 con，就要赔一次断电。
#     本脚本的排序原则就是「**把风险最高的放在最后**」，一次会话拿最多答案。
#
# 已排除（不要再查）：
#   * MMU 页表：.mmu_tbl 是完整 16KB，在单个 LOAD 段内；PL 区 0x43C00C02（Section，
#     强序），UART/SLCR/SCU 均为 device，未用区是 FAULT —— 映射本身没问题。
#   * ps7_init：日志里从来没有 `Mask poll` / `Timeout Reached`，DDR PHY 校准是过的。
#   * 复位序列、位流、`dow`、PL 寄存器读写：测试 A 已证明全好。
#
# 未决的主要假设：
#   H1  DDR 执行不了。`board_io.md` 2026-10-01 换 7020 核心板时明确写过
#       「ps7_config.tcl 是从 7010 的厂商例程导出的，DDR 那 77 条参数依赖核心板，
#         是风险最高的一项」。app 链在 DDR 0x00100000，而 BootROM 跑在 OCM ——
#         这正好能解释「BootROM 正常 / app 一跑就死」。
#   H2  app 里某条 load/store 打到不响应的地址（第 4/5 步会指到具体指令）。
#
# 步骤顺序（前一步不过就停，不再冒险）：
#   1  DAP 直读直写 DDR（**不执行**，零风险）—— 查容量/寻址是否对
#   2  A9 在 OCM 里跑 `b .`（低风险，BootROM 已证明 OCM 可执行）
#   3  A9 在 DDR 里跑 `b .`（**有风险**）—— 一条指令就分辨 H1
#   4  完整 dow + 断点在 main（**有风险**）
#
# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
set elf  D:/Vitis/rv32_app/Debug/rv32_app.elf

# 采样 DDR 寻址用的步长。1 MB 一跳，正好覆盖到行地址位级别的别名。
# 若实际几何是 15 行位而控制器只配了 14 位，A14 不会被驱动，
# 于是 0x00400000 这一档会别名回 0x00000000 那一档 —— 被下面的回读抓住。
#
# 注意：**不要把这个地址交给 `incr` 之后再直接塞进 `mwr`** —— Tcl 的 incr
# 会把 "0x00100000" 归一化成十进制字符串，而 mwr/mrd 对十进制大数的处理
# 不如十六进制明确。这里全程用 fmt32 显式格式化成 8 位十六进制。
set DDR_FIRST 0x00100000
set DDR_STEP  0x00100000
set DDR_LAST  0x1FF00000

proc fmt32 {v} { return [format "0x%08X" $v] }

proc rd32 {a} {
    if {[catch {set v [mrd -force $a]} e]} { return "ERR($e)" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { return "?" }
    return [format "0x%08X" [expr "0x$h"]]
}

# 返回 1 = 停住了（含 PC），0 = **没停住**（这一条就是卡点）
proc trystop {tag {ms 300}} {
    catch {con}
    after $ms
    if {[catch {stop} e]} {
        puts "   \[$tag\] **stop 失败: $e**"
        puts "   \[$tag\] ⇒ 卡点就在这一步或之前；DAP 已锁死，需要断电重上电"
        return 0
    }
    set pc "?"
    catch {set pc [lindex [rrd pc] end]}
    puts "   \[$tag\] stop OK   PC=$pc"
    return 1
}

proc banner {t} { puts ""; puts "########## $t ##########"; }

connect
targets -set -filter {name =~ "APU"}
catch {rst -system}
after 1000
targets -set -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init

puts "----- ps7_init 全文（重点看有没有 Mask poll 超时） -----"
if {[catch {ps7_init} e]} { puts "ps7_init 报错: $e" }
puts "----- ps7_init 结束 -----"
catch {ps7_post_config}
catch {rst -processor -clear-registers}
after 300

# ---------------------------------------------------------------- 步骤 1（零风险）
banner "步骤 1  DAP 直接读写 DDR —— 不执行任何代码"
set bad 0
set n 0
for {set a $DDR_FIRST} {$a <= $DDR_LAST} {incr a $DDR_STEP} {
    catch {mwr [fmt32 $a] [fmt32 $a]}
    incr n
}
puts "   已写入 $n 个采样点（每点写自己的地址）"
for {set a $DDR_FIRST} {$a <= $DDR_LAST} {incr a $DDR_STEP} {
    set want [fmt32 $a]
    set got  [rd32 $want]
    if {$got ne $want} {
        puts "   **$want -> $got**  (别名/丢数)"
        incr bad
        if {$bad >= 8} { puts "   ... 只列前 8 个"; break }
    }
}
if {$bad == 0} {
    puts "   \[ok\] 全部回读一致 ⇒ DDR 控制器 + PHY + 寻址在 0x00100000..$DDR_LAST 都对"
    puts "        （H1 里「容量/寻址配错」这一支被排除；但不等于 A9 经 L2 的取指路径也好）"
} else {
    puts "   \[FAIL\] $bad 个采样点回读不符 ⇒ **DDR 寻址配置与板上实际颗粒不符**"
    puts "        ⇒ 回到 board_io.md：ps7_config.tcl 的 DDR 参数是 7010 例程的，"
    puts "          需要拿 7020 的厂商例程重跑 scripts/gen_ps7_config.py"
}

# ---------------------------------------------------------------- 步骤 2（低风险）
banner "步骤 2  A9 在 OCM 里执行 b .（0x00010000）"
catch {mwr 0x00010000 0xEAFFFFFE}
if {[catch {rwr pc 0x00010000} e]} {
    puts "   rwr pc 失败（语法？）: $e"
} else {
    trystop "OCM执行"
}
catch {rst -processor -clear-registers}
after 300

# ---------------------------------------------------------------- 步骤 3（有风险）
banner "步骤 3  A9 在 DDR 里执行 b .（0x00100000）—— H1 的判决点"
puts "   同一条指令，只是从 OCM 换到 DDR。若这里停住而步骤 2 通过，"
puts "   则 DDR 的**取指路径**（SCU/L2/PL310 -> DDRC）是坏的，而 DAP 直读是好的。"
catch {mwr 0x00100000 0xEAFFFFFE}
if {![catch {rwr pc 0x00100000} e]} {
    if {![trystop "DDR执行"]} {
        puts ""
        puts "LADDER_STOP: 卡在步骤 3，无法继续（板子需要断电重上电）"
        catch {disconnect}
        exit 0
    }
}

# ---------------------------------------------------------------- 步骤 4（有风险）
banner "步骤 4  完整 dow + 断点在 main（0x100948）"
catch {rst -processor -clear-registers}
after 300
if {[catch {dow $elf} e]} { puts "   dow 失败: $e" } else { puts "   dow OK" }
catch {bpadd -addr 0x100948}
catch {puts "   bplist: [bplist]"}
catch {con}
after 1500
if {[catch {stop} e]} {
    puts "   **从入口走到 main 的路上就挂了: $e**"
    puts "   ⇒ 卡点在 boot.S / crt0 里。下一步改用单步：从 0x100000 起逐条 step，"
    puts "     记录 PC，挂在哪条就是哪条（每挂一次赔一次断电，所以只做一轮）。"
} else {
    set pc "?"
    catch {set pc [lindex [rrd pc] end]}
    puts "   stop OK  PC=$pc   (0x100948 = 已到达 main)"
    puts "   ⇒ 到此为止 boot.S 全过。下一步在 main 里继续布点/单步。"
}

puts ""
puts "LADDER_DONE"
catch {disconnect}
