# 056 用 `get_timing_paths -max_paths 100000` 凑 TNS ⇒ 报告段卡死

**症状** `scripts/run_zynq_flow.tcl` 跑到报告段**不动了**。位流早已落盘
（`BIT_OK`、4.0 MB 的 `.bit`），`build/timing_zynq.rpt` 也写完了，
然后进程挂十几分钟没输出，最后只能强杀。

**误判** 第一反应是"Vivado 在算 `report_utilization`，这设计大，慢是正常的" ——
差点就等下去了。差一点把它当成"环境又坏了"（像 039 那样）或者"设计太大"。

**根因** 卡住的是这一行：

```tcl
set tns [get_property SLACK [get_timing_paths -delay_type max -max_paths 100000 -nworst 100000]]
```

`get_timing_paths` 是**逐条枚举**的，不是读一个已算好的汇总值。
本设计 **57,025 个端点、其中 9,762 个失效**，要十万条路径就是把每一条都
从头算一遍 —— 不是"慢一点"，是**几十分钟量级**。

**指纹** **日志停在某个 `report_*` 之后的安静期，而且进程还活着** ⇒
先去看那一段 Tcl 有没有"把枚举量开到很大"的调用。
和 055 是同一类：**脚本层的问题伪装成设计/环境问题**。

**修法** TNS 不重新枚举，直接从**刚写出的报告**里读（同一时刻、同一份数据，
而且那才是权威口径）：

```tcl
set fh [open [file join $root build timing_zynq.rpt] r]
set rpt [read $fh]
close $fh
if {[regexp {\|\s*\n\s*WNS\(ns\)[^\n]*\n\s*-+[^\n]*\n\s*(-?[0-9.]+)\s+(-?[0-9.]+)} $rpt -> _w _t]} {
    set tns $_t
}
```

**复现** 跑 `scripts/run_zynq_flow.tcl`，看它在 `==== 时序 ====` 之后停住。
