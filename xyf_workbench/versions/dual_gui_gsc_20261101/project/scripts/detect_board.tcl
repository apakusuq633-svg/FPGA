# 只探测：JTAG 上有没有板子、是什么器件。**不下载、不复位、不改任何东西。**
#
#   xsct scripts/detect_board.tcl
#
# 为什么单独一个脚本：换核心板（7010 → 7020）之后第一件该确认的事就是
# 「工具看到的器件与工程里写的 part 是不是同一个」。对不上时，
# 后面所有"位流下不去""跑起来没反应"都会变成难查的问题。
#
# ⚠ 本脚本**只 connect 然后读**。它不会 program、不会 rst。
#   要真的下载并跑，用 scripts/run_board.tcl 或 scripts/test_pdm_onboard.tcl。

puts "==> 连接 hw_server"
if {[catch {connect} e]} {
    puts "FAIL: 连不上 hw_server / 没有板子: $e"
    puts "      查：JTAG 线插好没有、板子上电没有、驱动装没装"
    exit 1
}
puts "==> 连上了"

puts ""
puts "==== JTAG 链上的器件 ===="
set n 0
foreach t [targets] {
    puts "  $t"
    incr n
}
if {$n == 0} {
    puts "  ** 一个器件都没有 —— 线或电的问题 **"
    disconnect
    exit 1
}

puts ""
puts "==== 是不是 7020？ ===="
set found ""
foreach t [targets] {
    set name [string tolower $t]
    if {[string match "*xc7z0*" $name]} { set found $t }
}
if {$found eq ""} {
    puts "  ** 没在链上找到 xc7z0xx 器件 **"
    puts "     （纯 PL 那条路下位流不需要这个；但 PS 侧一定要它）"
} else {
    puts "  器件 target: $found"
    set name [string tolower $found]
    if {[string match "*xc7z020*" $name]} {
        puts "  OK: 是 7020 —— 与工程里 set part \"xc7z020clg400-1\" 一致"
    } elseif {[string match "*xc7z010*" $name]} {
        puts "  ** 警告：链上是 7010，而工程已经改成 7020 **"
        puts "     Bitstream 的器件型号对不上会拒绝下载（或用 -force 下进去然后不工作）。"
    } else {
        puts "  ⚠ 认不出型号，自己看一眼上面那行"
    }
}

puts ""
puts "==== 板上是否已在跑位流 ===="
if {[catch {targets -set -filter {name =~ "*Cortex-A9*#0"}} e]} {
    puts "  PS 核取不到（可能没跑过 ps7_init）：$e"
} else {
    if {[catch {set pc [mrd -force 0x00000000]} e2]} {
        puts "  读内存失败：$e2"
    } else {
        puts "  能读到 PS 地址空间（0x00000000 = $pc）⇒ PS 侧活着"
    }
}

disconnect
puts ""
puts "DETECT_DONE"
