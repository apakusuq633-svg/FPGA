# 给综合用的 ROM 传**绝对路径**。
#
# 分工：create_vivado_project.tcl（裸 PL）与 create_zynq_project.tcl（Zynq）都
# source 这一份，保证两边口径一致 —— 不再各写一遍。
#
# 为什么非要绝对路径：Vivado 综合时的工作目录是 run 目录
#   （<proj>/<proj>.runs/synth_1/），RTL 里写的相对路径在那里找不到，
#   结果是 CRITICAL WARNING [Synth 8-4445] + **静默留一张空 ROM**。
# 两个后果都特别难发现：
#   * 旋转因子全 0（build/fft_tw.hex）⇒ 乘 0 让乘法器被优化掉，
#     **资源数反而好看**，而且 TB 全绿
# TB 发现不了：iverilog 从仓库根跑，相对路径是对的。
#
# 对应的 `ifdef 在 rtl/acoustic/rv32_fft_bfly.v，没定义时退回相对路径 ——
# 所以 TB 一行都不用改。
#
# 用法：先 set root，再 source 本文件。

if {![info exists root]} {
    error "rom_preload.tcl needs \$root set before sourcing"
}

# file join 在 Windows 上可能给反斜杠，而 Verilog 里 \ 是转义符 —— 一律正斜杠。
proc _fwd {p} { string map {\\ /} $p }

set tw_hex  [_fwd [file join $root build fft_tw.hex]]
set hann_hex [_fwd [file join $root rtl rom pdm_hann_q14.hex]]

foreach f [list $tw_hex] {
    if {![file exists $f]} {
        puts "==> \[WARN\] ROM image missing: $f"
        puts "==>        generate it before synthesizing, or the ROM will be empty"
    }
}

if {![file exists $hann_hex]} {error "Localizer Hann ROM missing: $hann_hex"}
set_property verilog_define [list "FFT_TW_FILE=\"$tw_hex\"" "PDM_HANN_FILE=\"$hann_hex\""] [current_fileset]
puts "==> ROM preload defines: [get_property verilog_define [current_fileset]]"
