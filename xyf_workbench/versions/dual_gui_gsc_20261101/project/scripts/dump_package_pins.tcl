# 把某个器件的**全部**封装脚与它们的 IO 站点倒出来，给 Python 侧建反查表。
#
#   vivado -mode batch -notrace -source scripts/dump_package_pins.tcl
#   vivado -mode batch -notrace -source scripts/dump_package_pins.tcl -tclargs xc7z020clg400-1
#
# 输出：build/package_pins.txt，每行 `封装脚 站点名`
#
# 用途：原理图那边只能给出**网络名**（B34_L11_P / B13_L20_N），要从网络名拿到
# 封装脚，通常得靠原理图的另一处标注。而站点名里就带着 bank 的 L 号与 P/N
# （IO_L11P_T1_SRCC_34），所以只要把「站点 → 封装脚」整张表倒出来，
# 就能用网络名直接反查 —— **不用再依赖原理图的排布**（Bank34/35 那页的网络名
# 在图上出现两次，按坐标配会歧义；Bank13 那页则是竖排）。
#
# ⚠ 只查器件数据，不跑 synth_design —— issues/039 那个原生崩溃在综合阶段，
#   这一步不受影响（039 已修，但这条依然成立：本脚本很轻）。

set here [file dirname [info script]]
set root [file normalize [file join $here ..]]
set out  [file join $root build package_pins.txt]

set part "xc7z020clg400-1"
if {[llength $argv] >= 2 && [lindex $argv 0] eq "-tclargs"} {
    set part [lindex $argv 1]
}

puts "==> part = $part"
create_project -in_memory -part $part -force
link_design -part $part

set fp [open $out w]
puts $fp "# 封装脚 站点名    (part = $part)"
set n 0
foreach pp [get_package_pins] {
    set pf [get_property PIN_FUNC $pp -quiet]
    # PIN_FUNC 形如 IO_L20N_T3_34；电源/地脚给的是 VCCO_34 / GND 之类，也一并留着
    if {$pf ne ""} {
        puts $fp "[get_property NAME $pp] $pf"
        incr n
    }
}
close $fp
puts "==> 写了 $n 条到 $out"
close_project
