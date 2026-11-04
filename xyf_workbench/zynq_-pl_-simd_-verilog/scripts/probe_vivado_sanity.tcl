# Vivado 环境体检 —— **4 行 blink**，空工程，纯 ASCII 路径，与仓库毫无关系。
#
#   vivado -mode batch -source scripts/probe_vivado_sanity.tcl
#
# 用途只有一个：回答「**这台机器上的 Vivado 到底能不能综合**」。
# docs/issues/039 记过一次稳定复现的原生崩溃（`TclStackFree: incorrect freePtr`
# + 退出码 0xC0000005），当时连 4 行 blink 都过不去，整个综合流程全被挡住。
#
# ⚠ **换任何环境设置（杀软/安装/驱动）之后，先用这个试，不要拿我们的工程试。**
#   拿真工程试的话，一旦通了分不清是"环境治好了"还是"这次恰好没触发"；
#   而 4 行 blink 没有第二个变量。
#
# 判据（issue 039 原文）：`synth_design` 能在 blink 上跑完 ⇒ 这一步通了。
#
# ⚠ 探测先于判断：本脚本会打印每一步的标记，**先看 S1/S2/S3 有没有走到**，
#   再看判决。崩在第几步本身就是信息。

set outdir [file join [file dirname [info script]] .. build vivado_sanity]
if {[info exists ::env(VIVADO_SANITY_OUT)]} { set outdir $::env(VIVADO_SANITY_OUT) }
set part   "xc7z020clg400-1"

puts "== 环境体检开始（part = $part）=="
puts "S0 vivado 版本 : [version -short]"

if {[catch {
    file mkdir $outdir
    create_project -force sanity $outdir -part $part
} e]} {
    puts "S1 create_project = **FAIL** : $e"
    exit 1
}
puts "S1 create_project = OK"

# 4 行 blink：一个时钟、一个计数器、一个 LED。没有任何 IP、没有 BD。
set fp [open "$outdir/blink.v" w]
puts $fp "module blink(input clk, input rst_n, output reg led);"
puts $fp "  reg \[23:0\] cnt;"
puts $fp "  always @(posedge clk) if (!rst_n) begin cnt <= 0; led <= 0; end"
puts $fp "    else begin cnt <= cnt + 1'b1; if (cnt == 24'hFFFFFF) led <= ~led; end"
puts $fp "endmodule"
close $fp
puts "S2 已写出 4 行 blink"

# ---- 关键一步：综合 ----
if {[catch {
    read_verilog "$outdir/blink.v"
    synth_design -top blink -part $part
} e]} {
    puts "S3 synth_design = **FAIL** : $e"
    puts ""
    puts "FAIL: 4 行 blink 都综合不了 ⇒ 这是环境问题，不是我们的设计。"
    puts "      见 docs/issues/039（杀软注入 / Vivado 安装）。"
    puts "      重试无用，先修环境。"
    exit 1
}
puts "S3 synth_design = OK"

# 综合完还要能善终 —— 039 就是崩在"所有模块综合完之后"的 Tcl 阶段
if {[catch {puts "S4 模块数 = [llength [get_cells -hier]]"} e]} {
    puts "S4 get_cells = **FAIL** : $e"
    exit 1
}

puts ""
puts "PASS: blink 综合完成且 Tcl 层没崩 ⇒ 综合流程可用"
puts "      下一步可以跑 scripts/create_zynq_project.tcl 或裸 PL 流程了"
close_project
