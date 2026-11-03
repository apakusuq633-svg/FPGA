# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）
source [file join [file dirname [info script]] jtag_guard.tcl]

# 板子刚上电时 PS 核取不到（DAP: AHB AP transaction error）时先跑这个。
#
#   xsct scripts/probe_ps_recover.tcl
#
# 背景：scripts/run_board.tcl 的顺序是 `connect` → **选 APU** → `rst -system`，
# 也就是**先要 APU 才能复位**。实测板子复位/重新上电之后 APU 会短暂缺失
# （JTAG 链上只剩 DAP 与 xc7z020），于是卡在选 APU 那一步，复位反而没执行。
#
# 这里反过来：**先对整个系统做一次 reset**，再等 A9 起来，再列目标。
# 不改 run_board.tcl，因为那个顺序在 PS 已经跑起来时是对的。

puts "==> connect"
connect
puts "==> 复位前的目标："
foreach t [targets] { puts "    $t" }

puts ""
puts "==> 先选中 DAP，再 rst -system"
# ⚠ `rst -system` 也不是随便就能调的：没选中任何 target 时报
#   "Invalid target. Use \"targets\" command to select a target"。
#   所以顺序是**先 targets 选一个，再 rst**。
# ⚠ `targets <name>` 不行 —— 它要的是**数字 id**（列表里每项第一行的那个数）。
#   传名字会报 `no target with id: DAP`，看着像"没这个目标"，其实是参数形式错了。
if {[catch {targets 1} e]} { puts "    targets 1 失败: $e" } else { puts "    选中: 1" }
if {[catch {rst -system} e]} {
    puts "    rst -system 报错：$e"
} else {
    puts "    ok"
}
after 3000

puts ""
puts "==> 复位后的目标："
set n 0
foreach t [targets] { puts "    $t"; incr n }

set apu ""
foreach t [targets] { if {[string match "*Cortex-A9*" $t]} { set apu $t; break } }
if {$apu eq ""} {
    puts ""
    puts "PS_RECOVER_FAIL: A9 仍未出现 —— 这不是脚本能解决的，需要人动板子"
    puts "  可能原因（按概率）："
    puts "   1. 板子/核心板掉电或供电不足（量一下电源灯）"
    puts "   2. 启动模式跳线被拨到别的档，PS 停在 BootROM 之前"
    puts "   3. JTAG 排线松动（但 DAP 还在，所以可能性较低）"
    puts "   4. 需要一次真正的断电重上电（不是按复位键）"
} else {
    puts ""
    puts "PS_RECOVER_OK: 找到 $apu"
}
puts "PROBE_DONE"
disconnect
