# 对照实验：上一份测量（probe_ddr_app_intact.tcl）本身可信吗？
#
#   xsct scripts/probe_ddr_verify_control.tcl
#
# ✅ **已结案（2026-10-04）**，两个结论都还成立、且都有后续：
#   1. 三遍读数互不相同 ⇒ **分块 `mrd`（一次读 32 字）本身不稳**，
#      这条到现在仍然成立 —— 所以判据一律走**逐字单读**（见
#      `probe_write_drop_ocm_vs_ddr.tcl` 的 `rd1`）。
#   2. 当时"读1 vs ELF 差 168"里还混着一个**大小写 bug**（同一 bug 犯过两次，
#      见 docs/issues/067 §2 ③/③b）：一侧小写、另一侧大写，凡含 A–F 的值都被判不符。
#   根因最后是 **DDR 颗粒型号配错**（4Gb 的板配成 2Gb），已修，见 docs/issues/067。
#
# 上一份的结果：dow 之后 8194 个字里 **5824 个**和 ELF 文件对不上（71%）。
# 但那个结论有个**会让它整个作废**的可能：
#
#   * 单字读写（probe_ddr_integrity 的 T1/T2）**全是好的**：
#       写一个点 -> 立刻读回，4 个点里 3 个对，10 秒保持性也过。
#   * 只有**批量**才坏：T3 的 256 字紧密循环坏 17 个；dow 的 8 KB 坏 71%。
#
#   => 「单个写/读都对，一上批量就烂」有两种完全不同的病因，必须分开：
#
#      E1  **回读通路不稳定** —— DAP 的 `mrd` 批量读本身会串。
#          那 probe_ddr_app_intact 的\"71% 坏\"就是我自己的工具假象，
#          DDR 可能根本没问题 —— **照那个结论去改 DDR 参数就是改错方向**。
#      E2  **写入通路不稳定**（`dow` 的批量写 / `mwr` 的紧密写），
#          回读是准的，只是读到了真的坏数据。
#
#   分辨办法：**同一块内存连读三遍**。
#     三遍两两一致、但都和文件不符  -> E2（写坏），读数可信
#     三遍之间自己就不一致         -> E1（读坏），上一份测量作废
#
# 另外顺便确认两个 A9 都真的停住了（CPU1 若在跑 BootROM，是这次测量的干扰项）。
# A9 全程停止，零风险。上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
set elf  D:/Vitis/rv32_app/Debug/rv32_app.elf

set LOAD_VADDR 0x00100000
set LOAD_OFF   0x010000
set CHECK_SIZE 0x2000          ;# 只看头 8 KB —— 坏 71% 的话这个量足够了
set CHUNK      32

proc fmt32 {v} { return [format "0x%08X" [expr {$v & 0xFFFFFFFF}]] }

proc rdwords {addr n} {
    if {[catch {set s [mrd -force $addr $n]} e]} { return {} }
    set toks [regexp -all -inline {[0-9A-Fa-f]{8}} $s]
    if {[llength $toks] < $n} { return {} }
    return [lrange $toks end-[expr {$n - 1}] end]
}

# 把一个区间整段读回来，返回小写十六进制字串的列表
proc readblock {vaddr size} {
    global CHUNK
    set out {}
    set nw [expr {$size / 4}]
    for {set i 0} {$i < $nw} {incr i $CHUNK} {
        set n $CHUNK
        if {$i + $n > $nw} { set n [expr {$nw - $i}] }
        set g [rdwords [fmt32 [expr {$vaddr + $i * 4}]] $n]
        if {[llength $g] != $n} { return {} }
        foreach w $g { lappend out [string tolower $w] }
    }
    return $out
}

proc cmp2 {A B label} {
    if {[llength $A] != [llength $B]} { puts "   $label: 长度不同"; return -1 }
    set d 0
    foreach a $A b $B { if {$a ne $b} { incr d } }
    puts "   $label: $d / [llength $A] 处不同"
    return $d
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

puts ""
puts "########## 步骤 0  确认两个 A9 都停住了 ##########"
foreach core {0 1} {
    catch {targets -set -filter [list name =~ "*Cortex-A9*#$core"]}
    after 100
    if {[catch {set p [rrd pc]} e]} {
        puts "   CPU$core: 读 PC 失败（还在跑？）: $e"
    } else {
        puts "   CPU$core: PC=[lindex $p end]  （停住了）"
    }
}
catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}

puts ""
puts "########## 步骤 1  dow ##########"
if {[catch {dow $elf} e]} { puts "   dow 失败: $e"; catch {disconnect}; exit 1 }
puts "   dow OK"

set f [open $elf rb]; seek $f $LOAD_OFF start
set data [read $f $CHECK_SIZE]; close $f
binary scan $data i* wantraw
set want {}
foreach w $wantraw { lappend want [string tolower [string range [fmt32 $w] 2 end]] }

puts ""
puts "########## 步骤 2  同一块内存连读三遍（0x00100000, $CHECK_SIZE 字节） ##########"
set R1 [readblock $LOAD_VADDR $CHECK_SIZE]
set R2 [readblock $LOAD_VADDR $CHECK_SIZE]
set R3 [readblock $LOAD_VADDR $CHECK_SIZE]
if {[llength $R1] == 0 || [llength $R2] == 0 || [llength $R3] == 0} {
    puts "   **有读回失败，DAP 读取通路本身有问题**"
    catch {disconnect}; exit 1
}
set d12 [cmp2 $R1 $R2 "读1 vs 读2"]
set d13 [cmp2 $R1 $R3 "读1 vs 读3"]
set d23 [cmp2 $R2 $R3 "读2 vs 读3"]
set df  [cmp2 $R1 $want "读1 vs ELF文件"]

puts ""
puts "########## 步骤 3  写入通路：mwr 逐字写 + 立即回读（0x00200000，256 字） ##########"
set base 0x00200000
set nw 256
set werr 0
for {set i 0} {$i < $nw} {incr i} {
    set v [fmt32 [expr {0x30000000 + $i}]]
    set a [fmt32 [expr {$base + $i * 4}]]
    catch {mwr $a $v}
    set g [rdwords $a 1]
    if {[llength $g] != 1 || [string tolower [lindex $g 0]] ne [string range $v 2 end]} {
        incr werr
        if {$werr <= 5} { puts "   $a 写 $v 立刻读回 [lindex $g 0]" }
    }
}
puts "   写后立即回读不符：$werr / $nw"

puts ""
puts "########## 判定 ##########"
if {$d12 > 0 || $d13 > 0 || $d23 > 0} {
    puts "   ⇒ **E1：回读通路不稳定**（同一块内存三遍读数自己就不一致）"
    puts "      probe_ddr_app_intact.tcl 报的 $df 处不符**不能采信** —— 那是测量噪声。"
    puts "      先解决 DAP 读取的稳定性（降 JTAG 频率 / 改 hw_server），再谈 DDR 对不对。"
    puts "      **不要**据此去改 ps7_config.tcl。"
} elseif {$df > 0} {
    puts "   ⇒ **E2：写入通路坏，回读是准的**"
    puts "      三遍读数完全一致（$d12/$d13/$d23 全 0），但和 ELF 文件差 $df 处 =>"
    puts "      DDR 里**真的**是坏数据。A9 取到坏指令 -> 执行到野生地址 -> 互连+DAP 锁死。"
    puts "      「写后立即回读不符 $werr/$nw」这一项把范围指到**批量写**上。"
    puts "      ⇒ 根因方向：DDR 写时序/几何与板上颗粒不符（7010 参数跑在 7020 板上）。"
} else {
    puts "   ⇒ 三遍一致、且和文件全对 —— 这次 dow 是好的，上一份的坏是间歇性的。"
    puts "      间歇性 => 更可能是**写缓冲/时序余量**问题，而不是地址映射错。"
}
puts ""
puts "VERIFY_CONTROL_DONE"
catch {disconnect}
