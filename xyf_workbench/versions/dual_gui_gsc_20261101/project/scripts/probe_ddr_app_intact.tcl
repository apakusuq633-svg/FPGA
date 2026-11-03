# dow 下去之后，**app 到底有没有完整落进 DDR**？
#
#   xsct scripts/probe_ddr_app_intact.tcl
#
# ✅ **已结案（2026-10-04）**：根因是 DDR 颗粒型号配错，已修（docs/issues/067）。
#
#   ⚠⚠ **本脚本历史上报过的"5824/8194 不符"和"5722/8194 不符"都是假的** ——
#   比对时一侧小写、另一侧大写，**凡值里含 A–F（十六进制字母）的都被判成不符**，
#   而打印出来的 want / got 看着一模一样。已修（两侧都 `string tolower`）。
#   这个 bug 在探针里犯过两次，桩测试抓不到（桩没有大小写语义）——
#   **检验办法是盯着打印出来的样本行看：want 和 got 不等才是真不符。**
#
#   另外：分块 `mrd`（一次读 32 字）本身也不稳（见 probe_ddr_verify_control.tcl 的结论），
#   所以下面用 CHUNK=32 读回来的结果**天然带噪声**。要下"坏了多少"这种结论，
#   请改用 probe_write_drop_ocm_vs_ddr.tcl 的逐字单读 + OCM 对照。
#
# 为什么问这个（probe_ddr_integrity.tcl 的实测结论）：
#
#   T1  单点写-立即读：4 个点里 1 个不符（0x1FF00000）
#   T2  保持性：**通过** —— 写进去的值 10 秒后还在
#       ⇒ **刷新在跑，衰减被排除**（这条很重要，否则会误判成 DDR 刷新问题）
#   T3  连续 256 字写完立刻回读：**17/256 不符（≈6.6%）**，且值是乱的
#       （0x00004000 / 0x2815DBDF / 0x2029FFFF ...）
#
#   ⇒ 约 7% 的**零散**损坏。如果 `dow` 下去的是这个样子，A9 取到的就是坏指令 ——
#     取指跑飞 -> 访问到不响应的地址 -> PS 互连连同 DAP 一起锁死。
#     这能一次性解释「BootROM 正常 / app 一跑就死 / 之后连 A9#1 都报 DAP 错」。
#
# ⚠ 但 T3 用的是 `mwr` **紧密循环**。还有一种可能：那是 DAP 写缓冲/合并的工具假象，
#   而 `dow` 走的是另一条路。**所以本脚本直接量 `dow` 的结果**，不绕弯。
#
# 做法：dow 之后把 DDR 读回来，逐字和 ELF 文件里的字节比。**A9 全程停止，零风险。**
# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl
set elf  D:/Vitis/rv32_app/Debug/rv32_app.elf

# ELF 的 LOAD 段：VirtAddr 0x00100000，文件偏移 0x010000，FileSiz 0x08008。
# （readelf -l 量出来的；.mmu_tbl 16KB 也在这一段里，所以整张页表都会被写下去。）
set LOAD_VADDR 0x00100000
set LOAD_OFF   0x010000
set LOAD_SIZE  0x08008
set CHUNK      32

proc fmt32 {v} { return [format "0x%08X" [expr {$v & 0xFFFFFFFF}]] }

# 一次读 n 个字。取回串里所有 8 位十六进制 token，取**最后** n 个 ——
# 这样无论 hw_server 在前面加不加 "地址:" 前缀都不受影响。
proc rdwords {addr n} {
    if {[catch {set s [mrd -force $addr $n]} e]} { return {} }
    set toks [regexp -all -inline {[0-9A-Fa-f]{8}} $s]
    if {[llength $toks] < $n} { return {} }
    return [lrange $toks end-[expr {$n - 1}] end]
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

# 两个核都停住 —— 否则 CPU1 的 BootROM 循环是这次测量的干扰项
catch {rst -processor -clear-registers}
catch {targets -set -filter {name =~ "*Cortex-A9*#1"}}
catch {rst -processor -clear-registers}
catch {targets -set -filter {name =~ "*Cortex-A9*#0"}}
after 300
puts "   (两个 A9 都已停止)"

puts ""
puts "########## dow ##########"
if {[catch {dow $elf} e]} { puts "   dow 失败: $e"; catch {disconnect}; exit 1 }
puts "   dow OK: $elf"

puts ""
puts "########## 把 ELF 文件读进来（只取 LOAD 段） ##########"
set f [open $elf rb]
seek $f $LOAD_OFF start
set data [read $f $LOAD_SIZE]
close $f
set nwords [expr {$LOAD_SIZE / 4}]
binary scan $data i* want
puts "   文件里 $nwords 个字（$LOAD_SIZE 字节）"

puts ""
puts "########## 从 DDR 读回来逐字比对 ##########"
set bad 0
set listed 0
for {set i 0} {$i < $nwords} {incr i $CHUNK} {
    set n $CHUNK
    if {$i + $n > $nwords} { set n [expr {$nwords - $i}] }
    set addr [fmt32 [expr {$LOAD_VADDR + $i * 4}]]
    set got [rdwords $addr $n]
    if {[llength $got] != $n} {
        puts "   $addr 读回失败（DAP 返回 None）"
        incr bad $n
        continue
    }
    for {set k 0} {$k < $n} {incr k} {
        set w [lindex $want [expr {$i + $k}]]
        set g [lindex $got $k]
        set w32 [expr {$w & 0xFFFFFFFF}]
        # 两侧都要归一化再比。⚠ 这条踩过：一侧 $g 小写、另一侧 [fmt32] 是大写，
        # 结果**凡值里含 A-F 的都被判成"不符"**，报出来的 want 和 got 看着一模一样。
        # 当时那个 "71% 坏" 就是这个 bug 造出来的假数字。
        set w_hex [string tolower [string range [fmt32 $w32] 2 end]]
        if {[string tolower $g] ne $w_hex} {
            incr bad
            if {$listed < 12} {
                puts "   [fmt32 [expr {$LOAD_VADDR + ($i + $k) * 4}]]  want [fmt32 $w32]  got 0x[string toupper $g]"
                incr listed
            }
        }
    }
}

puts ""
puts "   不一致：**$bad / $nwords** 个字"
if {$bad == 0} {
    puts "   \[ok\] dow 下去的 app 在 DDR 里**逐字完整**"
    puts "        ⇒ 「DDR 存不住 dow 的内容」被排除。T3 的 17/256 是 \`mwr\` 紧密循环的"
    puts "          工具假象（DAP 写缓冲/合并），不是板子的问题 —— 不要再顺着它查 DDR 颗粒。"
    puts "        ⇒ A9 跑飞的原因在别处，下一步才值得冒一次险去测「A9 从 DDR 取指」。"
} else {
    puts "   \[FAIL\] **dow 下去的内容本身就是坏的** —— 这就是 A9 跑不起来的根因："
    puts "          取到的指令是坏的 -> 执行到野生地址 -> PS 互连连同 DAP 锁死。"
    puts "          ⇒ 回到 board_io.md：DDR 那 77 条参数是 7010 例程的，"
    puts "            要拿 7020 的厂商例程重跑 scripts/gen_ps7_config.py。"
    puts "          ⇒ 在修好之前**不要**再跑 run_board.tcl，每次都会把板子卡到要断电。"
}
puts ""
puts "APP_INTACT_DONE"
catch {disconnect}
