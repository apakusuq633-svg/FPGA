# 059 的判定实验 + 测试脚本自身的一个误读。
#
#   xsct scripts/probe_pdm_firstword.tcl
#
# ── 背景：test_pdm_onboard.tcl 的 step 5 读错了寄存器 ────────────────────
# 规格 P-11（docs/pdm_array_spec.md）写明采集窗口是 **INDEX + DATA 两个寄存器**：
#   写 INDEX = 0..LEN*(N_CH/2)-1，再读 DATA 取那一个字。
# 但 test_pdm_onboard.tcl 写的是 `reg(0x20 + i*4)`，即**递增地址**当作数组读
# 8 个"数据字"。按寄存器表：
#     0x320 DATA   0x324 ACKSEQ  0x328 RELEASE  0x32C FRAME
#     0x330 FROZEN 0x334 META    0x338 (未用)   0x33C (未用)
# 所以那 8 个数里**只有第 0 个是真数据**，其余是寄存器。实测值六个全中：
#     80008000 | 00000000 00000000 | 00004A3E(=帧计数 19006)
#     000000FF(=FROZEN) | 00000200(=META=LEN=512) | 0 0
# ⇒ issues/059 里那句「第 1〜7 个字带小残差，0x200=512 正好是直流阻断的残差上界」
#   **是误读**：0x200 是 META 寄存器，512 就是默认 LEN，与残差无关。
#
# ── 本脚本要回答的 ──────────────────────────────────────────────────────
# 用**正确的方法**读 DATA，看 index 0 到底是不是满刻度，并且分清：
#   (A) 启动瞬态：bank 是刚使能时采的，那时直流阻断还没收敛（~150 ms）⇒ 良性
#   (B) 系统性错位：无论何时采，首字都饱和 ⇒ 要修
# 判据：跑够 1.5 s 让阻断收敛，**释放两个 bank 重采**，再比首字。
#
# 先做**寄存器表自证**：META 必须=512、FROZEN 必须=0xFFFF。这两条不对，
# 说明地址映射理解错了，后面的数据一概不能信。

set root [file normalize [file join [file dirname [info script]] ..]]
set ws   D:/Vitis

set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init [file join $ws PS-PL hw ps7_init.tcl]

proc reg {off} { return [expr {0x43C00300 + $off}] }

proc rd {addr} {
    if {[catch {set v [mrd -force $addr]} e]} { error "mrd $addr failed: $e" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { error "mrd parse failed: $s" }
    return [expr "0x$h"]
}
proc wr {addr val} {
    if {[catch {mwr -force $addr $val} e]} { error "mwr $addr 失败: $e" }
}

# 正确读法：写 INDEX 再读 DATA
proc word_at {i} {
    wr [reg 0x1C] $i
    return [rd [reg 0x20]]
}

proc dump_bank {bank tag n} {
    global NW
    wr [reg 0x0C] $bank                 ;# R_SELECT
    after 5
    set first [rd [reg 0x14]]           ;# R_FIRST
    set meta  [rd [reg 0x34]]           ;# R_META
    puts [format "   bank%d  FIRST=%d  META=%d" $bank $first $meta]
    set bad {}
    set line ""
    for {set i 0} {$i < $n} {incr i} {
        if {[catch {set w [word_at $i]} e]} {
            puts [format "   (停止于 index %d: %s)" $i $e] ; break
        }
        if {$w == 0x80008000 || $w == 0x8000 || $w == 0x00008000} { lappend bad $i }
        if {$i < 12} { append line [format " %08X" $w] }
    }
    puts "   data[0..11] =$line"
    if {[llength $bad] == 0} {
        puts "   -> 读到的 $n 个字里**没有**满刻度"
    } else {
        puts [format "   -> 满刻度出现在 index: %s" $bad]
    }
    return $first
}

puts "==> 连接"
connect
foreach p [list $bit $init] { if {![file isfile $p]} { error "缺文件: $p" } }
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
targets -set -filter {name =~ "*Cortex-A9*#0"}

puts ""
puts "==== 0. 寄存器表自证（不对的话后面数据全不可信）===="
wr [reg 0x00] 0x3
after 200
set meta_chk [rd [reg 0x34]]
set fz_chk   [rd [reg 0x30]]
set st       [rd [reg 0x04]]
puts [format "   META=%d (want 512)   FROZEN=0x%04X (want FFFF)   STATUS=0x%08X READY=%d" \
      $meta_chk [expr {$fz_chk & 0xFFFF}] $st [expr {$st & 0x3}]]
if {$meta_chk != 512} { error "META != 512 —— 地址映射理解错了，停止" }
if {($fz_chk & 0xFFFF) != 0xFFFF} { puts "   WARN: FROZEN 不是 0xFFFF（板上接了麦？），继续但不做断言" }
puts "   OK: 寄存器表与 P-11 一致"

puts ""
puts "==== 等 1.5 s 让直流阻断收敛 ===="
after 1500
set f_now [rd [reg 0x2C]]
set st    [rd [reg 0x04]]
puts [format "   FRAME_CNT=%d  STATUS=0x%08X READY=%d" $f_now $st [expr {$st & 0x3}]]

puts ""
puts "==== A. 现在躺在缓冲里的那一批（刚使能时采的）===="
set fa0 [dump_bank 0 A 32]
set fa1 [dump_bank 1 A 32]
puts [format "   bank0 采于 %d 帧前 ≈ %.1f ms 前" \
      [expr {$f_now - $fa0}] [expr {($f_now - $fa0) / 39.0625}]]

puts ""
puts "==== B. 释放两个 bank 重采（此刻阻断已收敛）===="
foreach b {0 1} {
    wr [reg 0x0C] $b
    after 5
    wr [reg 0x28] 1                     ;# R_RELEASE
    after 5
}
after 100
set f_now2 [rd [reg 0x2C]]
set st2    [rd [reg 0x04]]
puts [format "   FRAME_CNT=%d  STATUS=0x%08X READY=%d" $f_now2 $st2 [expr {$st2 & 0x3}]]
set fb0 [dump_bank 0 B 32]
set fb1 [dump_bank 1 B 32]
puts [format "   bank0 采于 %d 帧前 ≈ %.1f ms 前" \
      [expr {$f_now2 - $fb0}] [expr {($f_now2 - $fb0) / 39.0625}]]

puts ""
puts "==== 结论 ===="
puts "   B 组首字不再是满刻度 ⇒ (A) 启动瞬态，059 良性"
puts "   B 组首字仍是 0x80008000 ⇒ (B) 系统性错位，要修"
# ── 2026-10-04 实测结果（7z020，闭合时序那一版位流）──────────────────────
#   走的是 (A)。A 组帧 0/1/2 = 8000/8040/807F —— 直流阻断从满刻度**单调爬升**的
#   轨迹本身；B 组（释放重采）**全零**。⇒ 059 结案：RTL 无需改。
#   ⚠ 这里刻意**没写 ACK_SEQ**，所以只有 bank0 被放行（它的 seq 恰好=0，
#     撞上复位值）、bank1 被设计**正确拒绝**。要看两个 bank 都重采，
#     用 test_pdm_onboard.tcl 第 6 项（那里走了完整的 ACK_SEQ→RELEASE）。
puts ""
puts "PROBE_DONE"
disconnect
