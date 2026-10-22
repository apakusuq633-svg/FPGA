# 从**已有的** Zynq 实现结果里出报告：时序 / 资源 / 引脚落点。不跑综合、不改设计。
#
#   vivado -mode batch -notrace -source scripts/report_zynq_results.tcl
#
# 与 run_zynq_flow.tcl 的分工：那个从建工程一路跑到位流（十几到几十分钟）；
# 这个只读已经跑完的结果，几秒钟出数。**改完东西只想看数字时用这个。**
#
# ⚠ 引脚的**实际落点**（report_io）是 issues/039 里写明"必须等 039 修好才能做"的
#   那一步 —— 它把 constraints 里写的 PACKAGE_PIN 与综合后真正分配到的 IO 站点
#   对照出来。xdc 里的引脚值是从原理图 PDF 抽的，这是唯一能在**工具侧**验证它的地方
#   （另一条路是上板量，见 docs/board_io.md §6）。

set here [file dirname [info script]]
set root [file normalize [file join $here ..]]
set proj_dir  [file join $root vivado_zynq]
set proj_name rv32_zynq
set proj_file [file join $proj_dir $proj_name.xpr]
set top       ps_pl_wrapper

if {![file exists $proj_file]} {
    puts "FAIL: 找不到 $proj_file —— 先跑 scripts/run_zynq_flow.tcl"
    exit 1
}
open_project $proj_file

set impl_status [get_property STATUS [get_runs impl_1]]
set impl_prog   [get_property PROGRESS [get_runs impl_1]]
puts "==> impl_1: $impl_status (progress $impl_prog)"
if {$impl_prog ne "100%"} {
    puts "FAIL: 实现没跑完，没有可信的数字"
    exit 1
}

open_run impl_1

# ── 时序 ──────────────────────────────────────────────────────────────────
puts ""
puts "======== 时序（产品口径 40 MHz）========"
set wns_p [get_timing_paths -delay_type max -max_paths 1]
set whs_p [get_timing_paths -delay_type min -max_paths 1]
if {[llength $wns_p] == 0} { puts "FAIL: 取不到建立路径"; exit 1 }
set wns [get_property SLACK $wns_p]
set whs [get_property SLACK $whs_p]
puts [format "  WNS = %+.3f ns   (setup,   ≥ 0 才算收敛)" $wns]
puts [format "  WHS = %+.3f ns   (hold,    ≥ 0 才算收敛)" $whs]

# 违例端点：从"有没有违例"这个最粗的判据拿。**不去正则解析 report_timing_summary
# 的那张表** —— 列数随版本/选项变，解析出来的数字看不出是错的，不如直接从
# check_timing 和路径数拿。
set nfailing [llength [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 100000 -quiet]]
puts "  建立违例路径数 = $nfailing"
report_timing_summary -file [file join $root build timing_zynq.rpt]
puts "  → 完整报告 build/timing_zynq.rpt"
if {$wns < 0 || $whs < 0} {
    puts "  **时序未收敛** —— 看上面那份报告里最差的那条路径"
}

# ── 资源 ──────────────────────────────────────────────────────────────────
puts ""
puts "======== 资源 ========"
set util [report_utilization -return_string -no_primitives]
foreach key {CLB_LUTS "CLB Registers" "Block RAM Tile" DSPs "Slice LUTs" "Slice Registers"} {
    foreach line [split $util "\n"] {
        if {[string first "| $key" $line] >= 0 || [string first "|  $key" $line] >= 0} {
            set parts [split [string trim $line] "|"]
            puts "  [string trim [lindex $parts 1]]"
            break
        }
    }
}
report_utilization -file [file join $root build util_zynq.rpt]
puts "  → 完整报告 build/util_zynq.rpt"

# 分层报告：**顶层数是 0**（逻辑全在 BD 的 OOC 模块里），
# 所以真正要看的是 `ps_pl_u_rv32_ps_0` 那个 run 的 util rpt，
# 以及这份分层表 —— 不按层级拆开，一个 280% 的数字只能干看着。
report_utilization -hierarchical -hierarchical_depth 3 \
    -file [file join $root build util_hier_zynq.rpt]
puts "  → 分层报告 build/util_hier_zynq.rpt"

# BD 里几个 OOC 模块各自的资源（顶层看不到它们）
foreach r {ps_pl_u_rv32_ps_0_synth_1 ps_pl_u_ps7_0_synth_1} {
    set d [get_property DIRECTORY [get_runs $r] -quiet]
    if {$d ne ""} {
        foreach f [glob -nocomplain [file join $d *utilization*rpt]] {
            set fh [open $f r]; set txt [read $fh]; close $fh
            puts "  --- [file tail $f] ---"
            foreach line [split $txt "\n"] {
                if {[regexp {^\|\s*(Slice LUTs\*?|Slice Registers|Block RAM Tile|DSPs)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|} \
                         $line -> name used fixed avail pct]} {
                    puts [format "      %-18s used %-10s / %-10s  %s%%" \
                              [string trim $name] [string trim $used] \
                              [string trim $avail] [string trim $pct]]
                }
            }
        }
    }
}

# ── 引脚落点：约束里写的 vs 工具实际分到的 ────────────────────────────────
puts ""
puts "======== 引脚落点 ========"
report_io -file [file join $root build io_zynq.rpt]
set pads {tacho_i pdm_clk_o}
puts [format "  %-16s %-8s %s" 端口 PACKAGE SITE]
foreach p $pads {
    if {[llength [get_ports -quiet $p]] == 0} {
        puts [format "  %-16s ** BD 里没有这个端口**" $p]
        continue
    }
    set pkg  [get_property PACKAGE_PIN [get_ports $p]]
    set site [get_property SITE [get_ports $p]]
    puts [format "  %-16s %-8s %s" $p $pkg $site]
}
# 总线上每一位单独列 —— 位选写错（[8:1] vs [7:0]）只会静默少约束几位
if {[llength [get_ports -quiet {pdm_din_i[*]}]] > 0} {
    foreach prt [lsort [get_ports {pdm_din_i[*]}]] {
        puts [format "  %-16s %-8s %s" [get_property NAME $prt] \
                  [get_property PACKAGE_PIN $prt] [get_property SITE $prt]]
    }
} else {
    puts "  pdm_din_i[*] ** 一个都没约束上** —— 查 create_zynq_project.tcl 里有没有 create_bd_port"
}
puts "  → 完整报告 build/io_zynq.rpt"

puts ""
puts "REPORT_PASS: 时序/资源/引脚报告已出"
