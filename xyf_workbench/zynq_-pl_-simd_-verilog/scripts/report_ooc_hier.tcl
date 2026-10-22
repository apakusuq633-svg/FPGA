# 把整个 PL 设计的**分层资源**拆出来（谁的 LUT / BRAM / DSP 各占多少）。
#
#   vivado -mode batch -notrace -source scripts/report_ooc_hier.tcl
#
# 为什么要有这个脚本：顶层 `report_utilization` 只给总数，回答不了
# 「换 16 麦要加多少」这类问题 —— 那要知道 PDM 前端这一子树现在占了多少。
#
# 优先读 **impl_1（routed）**，没跑完才退到综合 run。
# 综合与实现后的 LUT 数只差 0.4%（149,009 → 148,380），两者都能用，
# 但实现后的数字就是最终数字，所以以它为准。
#
# 输出：build/util_hier.rpt（完整分层报告）+ 终端里按 LUT 排序的摘要。

set here [file dirname [info script]]
set root [file normalize [file join $here ..]]
set proj [file join $root vivado_zynq rv32_zynq.xpr]

if {![file exists $proj]} { puts "FAIL: 找不到 $proj"; exit 1 }
open_project $proj

# ── 选 run：impl_1 优先，没跑完退综合 ──────────────────────────────────
set run synth_1
foreach cand {impl_1 synth_1} {
    if {[llength [get_runs -quiet $cand]] == 0} { continue }
    if {[get_property PROGRESS [get_runs $cand]] eq "100%"} { set run $cand; break }
}
puts "==> 用 run: $run  ([get_property PROGRESS [get_runs $run]] / [get_property STATUS [get_runs $run]])"
open_run $run

set out [file join $root build util_hier.rpt]
report_utilization -hierarchical -hierarchical_depth 8 -file $out

# 从报告里把各层级的几列抓出来，按 LUT 排序 —— 报告很长，直接看数字更快。
puts ""
puts "==== 按 LUT 用量排序（只列用到 300 个以上的）===="
puts [format "  %8s %8s %6s %5s %6s  %s" LUT FF BRAM DSP LUTRAM module]
set fh [open $out r]; set txt [read $fh]; close $fh

set rows {}
foreach line [split $txt "\n"] {
    # 分层表形如:
    # | module_name | Slice LUTs | LUT as Logic | LUT as Memory | Slice Registers | Block RAM Tile | DSPs |
    # 列数随 Vivado 版本/选项变动，所以按名字定位列，不写死下标。
    if {![regexp {^\|\s*([^|]+?)\s*\|} $line -> name]} { continue }
    set nums [regexp -all -inline {\|\s*(\d+)\s*} $line]
    if {[llength $nums] < 5} { continue }
    set v {}
    foreach n $nums { regexp {\d+} $n -> d; lappend v $d }
    set luts [lindex $v 0]
    if {$luts < 300} { continue }
    lappend rows [list $luts $name $line]
}
foreach r [lsort -integer -decreasing -index 0 $rows] {
    lassign $r luts name line
    puts "  $line"
}
puts ""
puts "（完整分层报告：build/util_hier.rpt）"
puts "HIER_DONE"
close_project
