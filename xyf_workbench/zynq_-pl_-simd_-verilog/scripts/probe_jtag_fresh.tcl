# 用一个**新的 hw_server**（换端口）去连板子，绕开 3121 上那个卡死的僵尸。
#
#   xsct scripts/probe_jtag_fresh.tcl
#
# 背景：卡死的 hw_server 杀不掉（`taskkill` 报 "no running instance"，
# `HasExited` 却是 True），但 3121 端口和 FTDI 句柄都被它占着。
# 新的 xsct 默认会**复用** 3121 上那个，于是跟着一起挂。
# 换端口 ⇒ 新起一个 hw_server ⇒ 它自己去开 FTDI。
#   能连上 ⇒ 僵尸只是占着旧服务，不影响设备 ⇒ 问题解决
#   连不上 ⇒ 设备句柄真被占死了 ⇒ 得拔插那根 USB（JTAG-HS1）

puts "==> 尝试用端口 3122（新起一个 hw_server）"
if {[catch {connect -host localhost -port 3122} e]} {
    puts "连接失败: $e"
    puts ""
    puts "FRESH_JTAG_FAIL: 换端口也连不上 —— 大概率是 FTDI 句柄被那个卡死的进程占死了。"
    puts "  请拔掉、再插回那个 USB（就是识别为 'USB Serial Converter' / JTAG-HS1 的那个），"
    puts "  然后重跑本脚本。板子本身不用断电。"
    exit 1
}
puts "==> 连上了（新 hw_server）"

if {[catch {set t [targets]} e]} {
    puts "targets 失败: $e"
    puts "FRESH_JTAG_FAIL: 连上了但扫不到目标 —— JTAG 链路仍不可用。"
    exit 1
}
puts "==> JTAG 链上的器件："
foreach x $t { puts "    $x" }
puts ""
puts "FRESH_JTAG_OK: 换端口能连上，说明设备没被占死。"
disconnect
