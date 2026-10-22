# 丢写是 DAP/JTAG 通路的，还是 DDR 的？—— 用 OCM 做对照一刀切开。
#
#   xsct scripts/probe_write_drop_ocm_vs_ddr.tcl
#
# ✅ **这就是定位根因的那个判据**（2026-10-04）：
#     修前  OCM 0/128   DDR **11/128**（坏法：只有低 16 位落盘，高 16 位是旧值）
#     修后  OCM 0/128   DDR **0/128**
#   ⇒ 根因是 DDR 颗粒型号配错（4Gb 的板配成 2Gb），修法与全过程见 docs/issues/067。
#   **以后任何"DDR 读写出问题"的怀疑，先用本脚本切一刀**：
#   OCM 干净、DDR 有错 ⇒ 查 ps7_config.tcl 的 DDR 参数，别去动 hw_server/JTAG。
#
# 怎么走到这一步的（前面几份探针的实测结论，别再重复）：
#
#   probe_ddr_integrity   T2 保持性**通过**（写进去 10 秒后还在）=> 刷新正常，不是衰减
#   probe_ddr_app_intact  dow 后 8194 字里 5824 字与文件不符（71%）  <-- **这份不可信**
#   probe_ddr_verify_control 同一块内存连读三遍，三遍互不相同     <-- 说明"比对"这种测法本身不干净
#   原始输出直读 32 字两遍：
#        PASS1  200004: 00004000     PASS2  200004: 40000001
#               200028: 3000000A            200028: 3000000A   <-- 两遍都错
#     而 0x3000000A 正是**上一轮**写在同一个地址的值 => **新写没落盘，旧值还在**
#
#   => 现象收窄成一句：**紧密循环里的 `mwr` 会丢写**（约百分之几），
#      不是「DDR 存不住」（T2 已排除），也不是「刷新没跑」。
#
# 还剩一个关键判别没做：丢写发生在哪一段？
#
#   W1  **DAP/JTAG 主机通路**丢（hw_server / AXI-AP 管道）。与 DDR 无关。
#       判据：**往 OCM（片上 SRAM，完全不碰 DDR）写，也同样丢**。
#   W2  **DDR 控制器**丢（时序/几何与板上颗粒不符）。OCM 应该干净。
#       判据：OCM 全对，DDR 丢。
#
#   ⇒ 这就是本脚本：同样的图案，分别打 OCM 和 DDR，各自逐字回读统计。
#      全程 A9 停止，零风险 —— **不执行任何 A9 代码**，所以不会再把板子卡死。
#
# OCM 地址选 0x00020000：Zynq 的 OCM 是 256 KB @ 0x00000000，低 128 KB 被
# BootROM 覆盖（只读），所以要写就写**上半区** 0x00020000..0x0003FFFF。
# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）。

source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set bit  [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init D:/Vitis/PS-PL/hw/ps7_init.tcl

set OCM_BASE 0x00020000
set DDR_BASE 0x00200000
set N        128

proc fmt32 {v} { return [format "0x%08X" [expr {$v & 0xFFFFFFFF}]] }

# 单字读。用 mrd -force 读 1 个字 —— 前面实测：**单字读是稳的**（8 字连读两遍完全一致），
# 批量读才串。所以验证一律走单字读，慢但可信。
proc rd1 {vaddr} {
    if {[catch {set s [mrd -force $vaddr 1]} e]} { return "ERR" }
    if {![regexp {([0-9A-Fa-f]{8})[ \t\r\n]*$} [string trim $s] -> h]} { return "?" }
    return [string tolower $h]
}

proc wr1 {vaddr hexval} { catch {mwr $vaddr $hexval} }

# 返回「不符字数」；mode=plain 直接写；mode=retry 写-读-不符就重写，最多 5 次
proc droptest {label base n mode} {
    set vals {}
    for {set i 0} {$i < $n} {incr i} { lappend vals [fmt32 [expr {0xA5A50000 + $i}]] }
    if {$mode eq "plain"} {
        for {set i 0} {$i < $n} {incr i} {
            wr1 [fmt32 [expr {$base + $i*4}]] [lindex $vals $i]
        }
    } else {
        for {set i 0} {$i < $n} {incr i} {
            set a [fmt32 [expr {$base + $i*4}]]
            set want [string range [lindex $vals $i] 2 end]
            for {set t 0} {$t < 5} {incr t} {
                wr1 $a [lindex $vals $i]
                if {[rd1 $a] eq [string tolower $want]} { break }
            }
        }
    }
    set bad 0
    for {set i 0} {$i < $n} {incr i} {
        set a [fmt32 [expr {$base + $i*4}]]
        set want [string tolower [string range [lindex $vals $i] 2 end]]
        set got [rd1 $a]
        if {$got ne $want} {
            incr bad
            if {$bad <= 5} { puts "      $a  want $want got $got" }
        }
    }
    puts "   $label ($mode): 不符 **$bad / $n**"
    return $bad
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
puts "   (两个 A9 都已停止，全程不执行 A9 代码)"

puts ""
puts "########## OCM 可写性自检（0x00020000 是不是真 SRAM） ##########"
wr1 0x00020000 0x11223344
set probe [rd1 0x00020000]
puts "   写 0x11223344 -> 读 $probe"
if {$probe ne "11223344"} {
    puts "   **这块地址不可写（可能是 BootROM 只读区）—— 换 0x00030000 再试**"
    wr1 0x00030000 0x11223344
    set probe [rd1 0x00030000]
    puts "   写 0x00030000 -> 读 $probe"
    if {$probe eq "11223344"} { set OCM_BASE 0x00030000 }
}

puts ""
puts "########## 对照实验 ##########"
set ocmPlain [droptest "OCM 直接写"  $OCM_BASE $N plain]
set ddrPlain [droptest "DDR 直接写"  $DDR_BASE $N plain]
set ocmRetry [droptest "OCM 写-验-重试" $OCM_BASE $N retry]
set ddrRetry [droptest "DDR 写-验-重试" $DDR_BASE $N retry]

puts ""
puts "########## 判定 ##########"
if {$ocmPlain == 0 && $ddrPlain == 0} {
    puts "   ⇒ **两列都是 0：DDR 写已经没有丢写** —— 这一项通过。"
    puts "      如果刚换过 ps7_init.tcl（DDR 参数修过），这就是修好的判据。"
    puts "      下一步拿 DDR 版 ELF 真跑一次（run_board.tcl -elf <vitis的.elf>）确认端到端。"
} elseif {$ocmPlain > 0} {
    puts "   ⇒ **W1：丢写发生在 DAP/JTAG 主机通路**（OCM 这种片上 SRAM 也丢）"
    puts "      OCM 丢 $ocmPlain/$N，DDR 丢 $ddrPlain/$N —— 两者同一量级。"
    puts "      ⇒ **不要去改 ps7_config.tcl 的 DDR 参数**，那修不了这个。"
    puts "      ⇒ 先把主机侧弄干净：降 JTAG 频率（先 \`jtag targets\` 选链，"
    puts "        再 \`jtag frequency 1000000\`）、换 USB 口/线、或重启 hw_server。"
    puts "      ⇒ 在那之前，probe_ddr_app_intact 报的「71% 坏」是工具假象，无效。"
} else {
    puts "   ⇒ **W2：只有 DDR 丢，OCM 干净** => DDR 控制器/时序与板上颗粒不符"
    puts "      ⇒ 回到 board_io.md：拿 7020 的厂商例程重跑 scripts/gen_ps7_config.py"
}
# 只在**确实还有丢写**时才谈重试；DDR 干净的时候说这些会把读者带偏（看着像还有问题）
if {$ddrPlain > 0 && $ddrRetry == 0} {
    puts "   \[可用手段\] 「写-读-不符就重写」能把 DDR 写到全对（重试后 $ddrRetry/$N）。"
    puts "      ⇒ 即使丢写还在，也可以用它把 ELF 可靠地灌进 DDR，先把 A9 这条路径试出来。"
} elseif {$ddrPlain > 0} {
    puts "   注意：重试后仍剩 $ddrRetry/$N —— 单字读的噪声也会挡住收敛，别只靠重试。"
}
puts ""
puts "DROP_PROBE_DONE"
catch {disconnect}
