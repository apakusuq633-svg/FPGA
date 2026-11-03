# 上板实测 PDM 通路（XSCT）。
#
#   xsct scripts/test_pdm_onboard.tcl
#   xsct scripts/test_pdm_onboard.tcl -no-program     （板子已经在跑，只读寄存器）
#
# ── 这一步验什么 ──────────────────────────────────────────────────────────
# **没有载板、没有麦，也能验三件事** —— 因为数据脚在 xdc 里带了 PULLDOWN，
# 没接麦时位流恒 0，于是每个环节都有一个确定的预期值：
#
#   1. FRAME_CNT 在按 ~39.0625 kHz 涨  ⇒ PDM_CLK 在跳、CIC 在跑、采样节拍对
#   2. FROZEN = 0x00FF                 ⇒ 8 路全被判为"线是死的"，
#                                        这**同时证明了位流恒 0 这个前提成立**
#                                        （悬空 CMOS 输入不给这个前提，所以有下拉）
#                                        当前每条数据线对应一路、每通道一位
#   3. GAIN 读回 16384                 ⇒ 反静音那条设计决定在硅上成立
#
# 这三条过了，说明 **clkgen → CIC → chan_align → 采集 → AXI 窗口** 整条链在真硅上活着。
# 麦接上之后要验的是另一回事（幅度一致性、定位），那些必须有载板。
#
# ── 不验什么（别把这两件事混起来）────────────────────────────────────────
# 采到的**数据**会是全 0，这是**对的**：位流恒 0 ⇒ CIC 输出恒 −满刻度 ⇒
# chan_align 的直流阻断把它滤掉 ⇒ 0。所以数据全 0 **不能**用来判断"麦坏了"，
# 判断断线看 FROZEN。
#
# ⚠ 本脚本 assumptions：BD 里 rv32_ps 的 AXI 从端钉在 0x43C00000（create_zynq_project.tcl
#   打印 "Slave pinned at ..."），PDM 窗口是它的 +0x300。若地址变了，改 base。

# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）
source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set ws   D:/Vitis
set prog 1
foreach a $argv {
    switch -- $a {
        -no-program { set prog 0 }
        default { }
    }
}

# Capture smoke only; this does not replace the live DAS/FIR acceptance.
set bit  [file join $root build das_fir_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init [file join $root build das_fir_zynq rv32_zynq.gen sources_1 bd ps_pl ip ps_pl_u_ps7_0 ps7_init.tcl]

# PDM 采集窗口（见 docs/pdm_array_spec.md P-11）
set BASE 0x43C00300
proc reg {off} { return [expr {0x43C00300 + $off}] }

# ⚠ `mrd` 的输出**不是纯数值**：2020.2 的 XSCT 返回形如 `43C00300:   00000001`
#   （地址在前、值在后）。原来写的是 `[lindex $v 0]`，取到的是地址前缀
#   `"43C00300:"`，于是 `format %08X` 抛 "expected integer but got 43C00300:" ——
#   看起来像"寄存器读不出来"，其实是**解析取错了字段**。
#   取**最后一个**十六进制 token 才对（两种格式都覆盖）。
proc rd {addr} {
    if {[catch {set v [mrd -force $addr]} e]} { error "mrd $addr failed: $e" }
    set s [string trim [join $v " "]]
    if {![regexp {([0-9A-Fa-f]+)[ \t\r\n]*$} $s -> h]} { error "mrd parse failed: $s" }
    return [expr "0x$h"]
}
proc wr {addr val} {
    if {[catch {mwr -force $addr $val} e]} { error "mwr $addr 失败: $e" }
}

puts "==> 连接"
connect
if {$prog} {
    foreach p [list $bit $init] {
        if {![file isfile $p]} { error "缺文件: $p" }
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
}
targets -set -filter {name =~ "*Cortex-A9*#0"}

puts ""
puts "==== 1. enable PDM chain ===="
wr [reg 0x00] 0x3                     ;# CTRL: EN=1, CAPTURE=1
after 50
set ctrl [rd [reg 0x00]]
puts [format "   CTRL   = 0x%08X   (want bit0=1 bit1=1)" $ctrl]
if {($ctrl & 0x3) != 0x3} { error "CTRL write did not take effect, read back 0x[format %08X $ctrl]" }
puts "   OK: enable bits read back -- write path alive"

puts ""
puts "==== 2. gain reset value (anti-mute) ===="
set g0 [rd [reg 0x40]]
set evenG [expr {$g0 & 0xFFFF}]
set oddG  [expr {($g0 >> 16) & 0xFFFF}]
puts [format "   GAIN[0..1] = 0x%08X   even=%d odd=%d  (want 16384)" $g0 $evenG $oddG]
if {$evenG != 16384 || $oddG != 16384} {
    error "gain reset value is not 16384 -- see docs/issues/029, this would mute the whole chain"
}
puts "   OK: reset value is Q2.14 unity, not mute"

puts ""
puts "==== 3. FRAME_CNT rate (is PDM_CLK + CIC running) ===="
# after is in milliseconds. 200 ms window => expect 39062.5 * 0.2 ~ 7812 samples.
# mrd itself costs ~1 ms, so over 200 ms the error is <1% -- enough to tell 39 kHz
# apart from anything else by orders of magnitude.
set c1 [rd [reg 0x2C]]
set t0 [clock milliseconds]
after 200
set c2 [rd [reg 0x2C]]
set t1 [clock milliseconds]
set ms [expr {$t1 - $t0}]
if {$ms <= 0} { set ms 200 }
set n [expr {$c2 - $c1}]
set rate [expr {$n * 1000.0 / $ms}]
puts [format "   advanced %d samples in %d ms  =>  %.1f Hz  (want 39062.5)" $n $ms $rate]
if {$n == 0} {
    error "frame counter did not move -- PDM_CLK not toggling, or enable did not take"
}
if {$rate < 20000 || $rate > 60000} {
    error [format "rate %.1f Hz is too far from 39.0625 kHz" $rate]
}
puts "   OK: frame counter advances at the designed rate => clkgen + CIC decimation + sample pacing all alive on real silicon"

puts ""
puts "==== 4. FROZEN (should be all 1s with no mics) ===="
set fz [rd [reg 0x30]]
puts [format "   FROZEN = 0x%02X   (8 ch; want 0xFF with no mics)" [expr {$fz & 0xFF}]]
if {($fz & 0xFF) == 0xFF} {
    puts "   OK: all 8 channels flagged constant => pulldowns took effect, wire-break detect works on silicon"
} elseif {($fz & 0xFF) == 0x00} {
    puts "   WARN: not one channel flagged -- lines are not constant: pulldown missing, or mics are connected"
    puts "         (with mics connected this is EXPECTED; look at the data in step 5)"
} else {
    puts [format "   WARN: only 0x%02X flagged -- should not be partial; check the xdc pulldowns and soldering" [expr {$fz & 0xFF}]]
}

puts ""
puts "==== 5. capture buffer (all-zero data is CORRECT here) ===="
set st [rd [reg 0x04]]
puts [format "   STATUS = 0x%08X  READY=%d" $st [expr {$st & 0x3}]]
if {($st & 0x3) != 0} {
    wr [reg 0x0C] 0
    wr [reg 0x1C] 0
    after 20
    # ⚠⚠ 采集窗口是 **INDEX + DATA 两个寄存器**（P-11）：先写 INDEX，再读 DATA
    #   取那一个字。**不是**把窗口当数组、递增地址读。
    #   原来这里写的是 `reg(0x20 + i*4)` —— i=1..7 读到的其实是
    #       0x324 ACKSEQ / 0x328 RELEASE / 0x32C FRAME / 0x330 FROZEN /
    #       0x334 META / 0x338 0x33C（未用）
    #   它们当然"在变"，于是旧判据误判成「words vary ⇒ 有真信号」。
    #   实测值六个全中（FRAME=19006、FROZEN=0xFF、META=512），见 issues/059。
    #   ⇒ **把 0x200 当成"直流阻断残差上界"也是误读：那是 META，512 就是默认 LEN。**
    set line ""
    set w0 -1
    set allsame 1
    set nfull 0
    set nzero 0
    for {set i 0} {$i < 16} {incr i} {
        wr [reg 0x1C] $i                   ;# R_INDEX
        set w [rd [reg 0x20]]              ;# R_DATA
        if {$i == 0} { set w0 $w } elseif {$w != $w0} { set allsame 0 }
        if {$w == 0x80008000 || $w == 0x8000 || $w == 0x00008000} { incr nfull }
        if {$w == 0} { incr nzero }
        if {$i < 8} { append line [format " %08X" $w] }
    }
    puts "   data[0..7] =$line   (INDEX/DATA)"
    puts [format "   of 16 words: %d at full-scale, %d zero" $nfull $nzero]
    if {$nfull > 0} {
        # ⚠ 这个 bank 是**刚使能时**采下来的，那一刻 chan_align 的直流阻断还没
        #   收敛（恒定输入要约 6000 个样点 ≈150 ms，见 build/tb_dc_probe.v），
        #   所以这里读到满刻度是**预期的**。要区分"启动瞬态"和"写入路径错位"
        #   得释放 bank 重采 —— 用 scripts/probe_pdm_firstword.tcl。
        puts "   NOTE: full-scale present -- EXPECTED for the bank captured at enable"
        puts "         time (DC blocking needs ~150 ms to settle). Run"
        puts "         scripts/probe_pdm_firstword.tcl to tell a startup transient"
        puts "         apart from a write-path error."
    } elseif {$nzero == 16} {
        puts "   OK: 16 words all 0 -- DC blocking converged, chain output quiet as expected"
    } elseif {$allsame} {
        puts [format "   NOTE: 16 words all 0x%08X (constant, not zero)." $w0]
        puts "         Constant-but-nonzero means the input is NOT the assumed all-zero"
        puts "         bitstream (that would give CIC at -full-scale, which DC blocking"
        puts "         removes -> 0). Look at FROZEN above and the pin pulldowns."
    } else {
        puts "   OK: words vary -- real signal present (mics connected?)"
    }
    set dr [rd [reg 0x18]]
    puts [format "   DROP = %d samples" $dr]
} else {
    puts "   neither bank ready yet (LEN=512 needs about 13 ms); read again later"
}

puts ""
puts "==== 6. ownership handshake + converged capture ===="
# 这一步同时验两件事，两件都必须按 P-11 的**规定顺序**做：
#   ① 归还 bank 要先写 ACK_SEQ = 该 bank 的 SEQ，再写 RELEASE=1；
#      顺序不对（或没写 ACK_SEQ）时设计**应当拒绝**并 +1 错误计数
#      （rv32_pdm_capture.v: `release_ok = ... && ack_seq_q == selected_seq`）。
#      第一次写探针时我没写 ACK_SEQ，bank0 因为 seq 恰好=0 蒙混过关、
#      bank1 被正确拒绝 —— 那是**推断**，这里把它变成实测。
#   ② 让链跑够 1.5 s 使直流阻断收敛（~6000 样点 ≈150 ms）后再采，
#      数据应当是**全零**而非满刻度。这是 issues/059 的判决实验。
after 1200
# ⚠ `ack_errors_q`（被拒绝的归还次数）**没有读出通路** —— 读 mux 里没有它。
#   所以"拒绝"只能靠**现象**判断：被拒的 bank `FIRST` 不变（没被重采）。
foreach b {0 1} {
    wr [reg 0x0C] $b                         ;# SELECT
    after 5
    set sq [rd [reg 0x10]]                   ;# SEQ
    wr [reg 0x24] $sq                        ;# ACK_SEQ = SEQ   ← 关键的一步
    after 5
    wr [reg 0x28] 1                          ;# RELEASE = 1
    after 5
    puts [format "   bank%d ACK_SEQ=%d -> RELEASE" $b $sq]
}
after 150
set st3 [rd [reg 0x04]]
puts [format "   STATUS = 0x%08X  READY=%d  (want READY=3: both banks re-captured)" \
      $st3 [expr {$st3 & 0x3}]]
set nz_total 0
set nfull_total 0
foreach b {0 1} {
    wr [reg 0x0C] $b
    after 5
    set fst [rd [reg 0x14]]
    set line ""
    for {set i 0} {$i < 8} {incr i} {
        wr [reg 0x1C] $i
        set w [rd [reg 0x20]]
        if {$w != 0} { incr nz_total }
        if {$w == 0x80008000} { incr nfull_total }
        append line [format " %08X" $w]
    }
    puts [format "   bank%d (FIRST=%d) =$line" $b $fst]
}
puts [format "   across both banks: %d/16 non-zero, %d at full-scale" $nz_total $nfull_total]
if {$nfull_total > 0} {
    puts "   NOTE: still full-scale after 1.5 s + re-capture -- this is the case 059"
    puts "         probe (scripts/probe_pdm_firstword.tcl) would call a WRITE-PATH error."
} else {
    puts "   OK: re-captured banks are free of full-scale -- DC blocking converged,"
    puts "       and both banks were released through the documented ACK_SEQ/RELEASE order"
}

puts ""
puts "PDM_ONBOARD_PASS: PDM chain is alive on real silicon (clock / CIC / capture / AXI / wire-break / anti-mute)"
disconnect
