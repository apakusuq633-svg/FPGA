# DDR 到底能不能存住数据？—— probe_a9_boot_ladder.tcl 第 1 步 FAIL 之后的拆解。
#
#   xsct scripts/probe_ddr_integrity.tcl
#
# ✅ **已结案（2026-10-04）**：本脚本的 T2（保持性）**通过**，正确排除了"刷新没跑/衰减"；
#    T1/T3 的失败是**写丢**（DDR 颗粒型号配错，见 docs/issues/067），不是存不住。
#    ⚠ 注意 T3 是"写 256 字再整块回读"，批量写本身会丢 —— 它的 FAIL 计数**不能**
#    当作"坏了多少张"，那只是丢写 + 读数不稳的叠加。判据请用
#    `scripts/probe_write_drop_ocm_vs_ddr.tcl`（有 OCM 对照，且逐字单读）。
#
# 上一轮（ladder）拿到的两个矛盾信号：
#
#   第 1 步  DAP 直读直写 DDR：511 个采样点里多个回读不符 -> 看着像 DDR 坏
#            ⚠ 但失败点**分散**（0x00700000 / 0x01800000 / 0x02500000 / 0x03100000 ...），
#              不是「行地址位没被驱动」那种**周期性**别名 —— 两种病因要分开。
#   第 4 步  完整 dow + main 断点：stop 报 `Already stopped`（**良性**，见 065 §6）
#            -> 反而像命中断点了，也就是 boot.S 走过去了
#
# 所以第 1 步的 FAIL 有**两个混淆因素**没排除：
#
#   混淆 A  **衰减**。写 511 个点再读 511 个点要好几秒。若 DDR 刷新没跑，
#          几十毫秒就开始丢 —— 那不论 DDR 好坏，这个测法都会 FAIL。
#          => 本脚本改成「**写一个、立刻读一个**」，把时间窗压到毫秒级。
#   混淆 B  **写没落盘**。DAP 写是 posted 的，可能需要一个读回/屏障才真正提交。
#          => 本脚本对同一个点写-读-再写-再读，看是不是稳定。
#
# 三个子测试，全在 A9 停止的状态下做，**零风险**：
#   T1  单点写-立即读（4 个地址，跨度覆盖整个 512 MB）
#   T2  保持性：写一个点，之后 1/3/6/10 s 各读一次 —— 衰减就直接暴露
#   T3  小块：连续 256 个字写完立刻回读（这一个能同时暴露别名和丢写）
#
# 只有 T1..T3 都过了，才值得再冒一次险去测「A9 能不能从 DDR 取指」。
# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl

proc fmt32 {v} { return [format "0x%08X" $v] }

proc rd32 {a} {
    if {[catch {set v [mrd -force $a]} e]} { return "ERR" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { return "?" }
    return [format "0x%08X" [expr "0x$h"]]
}

proc banner {t} { puts ""; puts "########## $t ##########" }

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
catch {rst -processor -clear-registers}
after 300
puts "   (A9 已停止，下面全程不执行任何 A9 代码)"

# ------------------------------------------------------------------ T1
banner "T1  单点写-立即读（毫秒级时间窗）"
set t1bad 0
# 每个地址一个固定但互不相同的花样：不用 rand()，免得 Tcl 把 int/float 混起来。
set pats {0x5A000001 0x5A000002 0x5A000003 0x5A000004}
set idx 0
foreach a {0x00100000 0x01000000 0x10000000 0x1FF00000} {
    set vs [fmt32 [lindex $pats $idx]]
    incr idx
    catch {mwr $a $vs}
    set r1 [rd32 $a]
    catch {mwr $a $vs}
    set r2 [rd32 $a]
    set ok [expr {($r1 eq $vs) && ($r2 eq $vs)}]
    if {!$ok} { incr t1bad }
    puts "   $a  写 $vs -> 读 $r1 / $r2   [expr {$ok ? {OK} : {MISMATCH}}]"
}
if {$t1bad == 0} {
    puts "   \[ok\] 写进去立刻读得回来，且重复写稳定"
    puts "        ⇒ 混淆 B（写没落盘）排除；ladder 第 1 步的 FAIL 不是「写不进去」"
} else {
    puts "   \[FAIL\] $t1bad/4 个点在毫秒级时间窗内就对不上"
}

# ------------------------------------------------------------------ T2
banner "T2  保持性（衰减）—— 写一个点，之后隔几秒读一次"
catch {mwr 0x00100000 0xA5A5A5A5}
puts "   写入 0x00100000 = 0xA5A5A5A5"
set t2bad 0
foreach d {1 3 6 10} {
    after [expr {$d * 1000}]
    set got [rd32 0x00100000]
    set ok [expr {$got eq "0xA5A5A5A5"}]
    if {!$ok} { incr t2bad }
    puts "   +${d}s  -> $got   [expr {$ok ? {OK} : {MISMATCH}}]"
}
if {$t2bad == 0} {
    puts "   \[ok\] 10 秒后数据还在 ⇒ **刷新在跑**，混淆 A（衰减）排除"
} else {
    puts "   \[FAIL\] 数据会自己变 ⇒ **DDR 刷新没在跑**（或该区根本没解码到真实颗粒）"
    puts "        这足以解释 A9 一执行 DDR 里的代码就跑到异常向量：取回的指令是坏的"
}

# ------------------------------------------------------------------ T3
banner "T3  连续 256 个字：写完立刻回读（同时能抓别名和丢写）"
set base 0x00200000
set n 256
for {set i 0} {$i < $n} {incr i} {
    set v [fmt32 [expr {0x10000000 + $i}]]
    catch {mwr [fmt32 [expr {$base + $i * 4}]] $v}
}
set t3bad 0
for {set i 0} {$i < $n} {incr i} {
    set a [fmt32 [expr {$base + $i * 4}]]
    set want [fmt32 [expr {0x10000000 + $i}]]
    set got [rd32 $a]
    if {$got ne $want} {
        incr t3bad
        if {$t3bad <= 6} { puts "   $a  want $want got $got" }
    }
}
puts "   不一致字数：$t3bad / $n"
if {$t3bad == 0} {
    puts "   \[ok\] 256 字全对，且值=索引 ⇒ 这一块既没别名也没丢写"
} else {
    puts "   \[FAIL\] $t3bad/$n 不符"
}

banner "结论"
puts "   T1 过 / T2 挂  ⇒ DDR 刷新问题（衰减）—— 这是 A9 跑不起来的根因"
puts "   T1 挂          ⇒ DAP 写-读通道本身有问题，先别怀疑 DDR 颗粒"
puts "   T1 T2 都过、T3 挂 ⇒ 寻址/别名问题（回到 7010 vs 7020 的 DDR 参数）"
puts "   三个都过       ⇒ DDR 直通没问题；A9 的问题在 SCU/L2/PL310 这条取指路径上，"
puts "                     下一步才值得冒一次险去测「A9 从 DDR 取指」"
puts ""
puts "DDR_PROBE_DONE"
catch {disconnect}
