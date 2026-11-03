# Zynq 全流程：建工程 → 综合 → 实现 → 位流 → 报告。**产品配置（40 MHz）**。
#
#   vivado -mode batch -notrace -source scripts/run_zynq_flow.tcl
#
# 或者走带重试的驱动脚本：  & scripts\run_zynq_flow.ps1
#
# ⚠ 为什么这个脚本以前不存在：**本仓库从来没有过真实的时序/资源数字**。
#   docs/issues/039 记过一次稳定的原生崩溃（`TclStackFree: incorrect freePtr`
#   + 0xC0000005），连 4 行 blink 都综合不了，整条综合流程全被挡住。
#   2026-10-01 用户卸掉联想自带的火绒杀软之后，`scripts/probe_vivado_sanity.tcl`
#   实测 4 行 blink 干净跑完 —— 039 解除，这个脚本才有意义。
#
# ⚠ 先跑探针再跑这个：  vivado -mode batch -source scripts/probe_vivado_sanity.tcl
#   如果探针不过，跑这个只会白等半小时，而且报出来的现象还是"环境坏了"。
#
# 每跑一段都打印一个标记（SYNTH_/IMPL_/BIT_/REPORT_），**判据是这些标记，
# 不是退出码** —— Vivado 即使 Tcl 半路失败也常退 0。

set here [file normalize [file dirname [info script]]]
set root [file normalize [file join $here ..]]
set output_dir [file join $root build das8]
if {[info exists ::env(ZYNQ_OUTPUT_DIR)]} { set output_dir [file normalize $::env(ZYNQ_OUTPUT_DIR)] }
file mkdir $output_dir

set proj_dir  [file join $root build das8_zynq]
if {[info exists ::env(ZYNQ_PROJ_DIR)]} {
    set proj_dir [file normalize $::env(ZYNQ_PROJ_DIR)]
}
set proj_name rv32_zynq
set proj_file [file join $proj_dir $proj_name.xpr]
set top       ps_pl_wrapper

# ── 1. 建工程（复用既有的建工程脚本，它自己会打印一堆自检）────────────────
if {[info exists ::env(ZYNQ_RESUME_IMPL)] && $::env(ZYNQ_RESUME_IMPL) eq "1"} {
    open_project $proj_file
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Resume requires completed synthesis"}
    reset_run impl_1
    puts "RESUME_IMPL_FROM_SYNTH"
} else {
puts "==> \[flow\] 建工程"
if {[catch {source [file join $here create_zynq_project.tcl]} e]} {
    puts "FLOW_FAIL: create_zynq_project.tcl 失败: $e"
    exit 1
}
puts "==> \[flow\] project = $proj_file"

# create_zynq_project 结束时工程是开着的；万一没开就自己开
if {[llength [current_project -quiet]] == 0} {
    if {[catch {open_project $proj_file} e]} {
        puts "FLOW_FAIL: 打不开 $proj_file : $e"
        exit 1
    }
}

# ── 1b. 核的 OOC 综合指令（2026-10-03 加，2026-10-05 修）──────────────────
# 关键路径在核里（`u_ex_mem_reg` → M 扩展乘法器 → `u_ex_mem_reg`），而核走
# **BD 模块引用的 OOC 独立综合**，那一路的 `synth_design` 命令**默认没有任何
# -directive**。换一种综合指令就是换一套 netlist 实现，物理优化才有东西可摆。
#
# ⚠ 三个坑，都实测踩过：
#   1. `set_property strategy ...` **不生效** —— 那种 run 有自己的命令模板，
#      runme.log 里那行命令照旧没有 -directive。
#   2. 能生效的是**步骤参数**：`STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE`。
#   3. **设的时机** —— `create_zynq_project.tcl` 里设不了；2026-10-05 实测连
#      放在这里也设不了：那个 OOC 子 run 要到 `launch_runs synth_1` 那一刻才被
#      Vivado **连带 create**（见 `build/zynq_flow.log` 那行
#      `Launched ps_pl_u_ps7_0_synth_1, ps_pl_u_rv32_ps_0_synth_1, ...`）。
#      原来这里只 WARN 一句就往下走 ⇒ **带着默认口径白跑 40 分钟**，
#      出来的 WNS 与台账 §2 的产品口径对不上还看不出来。见 docs/issues/075。
#
# 所以改成：**先想办法把 run 建出来；建不出来就立即退出**，宁可几分钟失败，
# 不要 40 分钟后拿到一组口径不对的数。判据仍是 runme.log 里那行
# `Command: synth_design` **有没有带上 -directive**（第 2 步后会自己查一次）。
#
# 正解（2026-10-05 实测）：**`launch_runs synth_1 -scripts_only`** —— 它只创建 run +
#   生成脚本、**不跑综合**，而 OOC 子 run 正是在 launch 这一步被造出来的；造完就能设参数。
# ⚠ 两条走不通的路，别再试（都实测过）：
#   · `create_ip_run [get_ips]` → 每个都报 `[Vivado 12-3424] IPI cores may not be directly
#     generated or have a netlist directly created from it ... only through their block diagram`
#     —— BD 里的核不许单独建 run；
#   · `generate_target all <bd>` → 命令跑完了，`get_runs` 依旧为空。
# ⚠ 第 2 步里那句 `reset_run synth_1` **不会**清掉这里设的 directive（实测），顺序无碍。
set core_run ps_pl_u_rv32_ps_0_synth_1
set core_ooc [get_runs -quiet $core_run]
if {$core_ooc eq ""} {
    puts "==> \[flow\] $core_run 不存在，用 launch_runs synth_1 -scripts_only 建出来"
    if {[catch {launch_runs synth_1 -scripts_only} e]} {
        puts "FLOW_FAIL: launch_runs synth_1 -scripts_only 报错: $e"
        exit 1
    }
    set core_ooc [get_runs -quiet $core_run]
}
if {$core_ooc eq ""} {
    puts "FLOW_FAIL: 建不出 $core_run ⇒ 产品 directive 无处可设。"
    puts "           **拒绝带着默认口径跑完整流程**（那样出来的时序不能进台账）。"
    puts "           见 docs/issues/075。"
    exit 1
}
if {[catch {
    set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized $core_ooc
} e]} {
    puts "FLOW_FAIL: core OOC directive 设不上: $e"
    exit 1
}
puts "==> \[flow\] core OOC directive = [get_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE $core_ooc]"

# ⚠ 光 set_property **不会**改已经生成好的脚本 —— 上面 `-scripts_only` 那一步用的是
#   **当时的**参数。必须 reset 子 run 让脚本重建（实测：reset 会把 run 目录里的
#   ps_pl_u_rv32_ps_0.tcl 删掉，launch 时按当前属性重新写）。
#   不 reset 的后果实测过（2026-10-05）：set_property 返回成功、get_property 也读得到
#   PerformanceOptimized，但 runme.log 里那行 synth_design **照样没有 -directive** ——
#   这正是"看着设上了、其实没生效"的形态，比报错更难发现。
if {[catch {reset_run $core_ooc} e]} {
    puts "FLOW_FAIL: reset 子 run 失败: $e"
    exit 1
}

# ── 2. 综合 ───────────────────────────────────────────────────────────────
puts "==> \[flow\] 综合 synth_1"
if {[catch {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
} e]} {
    puts "FLOW_FAIL: launch_runs synth_1 抛异常: $e"
    exit 1
}
# 039 的指纹：批处理不报 ERROR，只有这句 + runme.log 里的 TclStackFree
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "FLOW_FAIL: synth_1 没到 100%（progress = [get_property PROGRESS [get_runs synth_1]]）"
    puts "           **去看 runme.log 末尾有没有 TclStackFree** —— 那就是 issues/039 复发"
    exit 1
}
puts "SYNTH_OK"

# ⚠ set_property 返回成功 **不等于** 生效 —— 步骤参数要等 run 真正执行才会写进
#   命令模板。这里自己查一次，把上面第 1b 段那句"判据"从注释变成检查。
#   （2026-10-05 加：正是缺这一步，才让"默认口径跑完 40 分钟"没被当场发现。）
set core_rlog [file join [get_property DIRECTORY [get_runs $core_run]] runme.log]
if {![file isfile $core_rlog]} {
    puts "FLOW_FAIL: 找不到核的 runme.log: $core_rlog"
    exit 1
}
set fh_core [open $core_rlog r]
set core_txt [read $fh_core]
close $fh_core
if {[regexp {Command:\s*synth_design[^\n]*-directive\s+(\S+)} $core_txt -> core_dir]} {
    puts "==> \[flow\] 核 OOC 确实带上了 -directive $core_dir"
} else {
    puts "FLOW_FAIL: 核的 runme.log 里 `Command: synth_design` **没有 -directive**"
    puts "           ⇒ 产品口径没生效，这次出来的时序不能进台账。见 docs/issues/075。"
    exit 1
}

# ⚠ 出报告**不在这个脚本里做**，交给 scripts/report_zynq_results.tcl。
#   两个理由：
#   1. 那个脚本只读已跑完的结果，几秒出数；改完东西只想看数字时用它，
#      不用把十几分钟的综合实现再跑一遍。
#   2. 这里曾经写过一版资源报告，用了 `get_utilization` —— **Vivado 没有这个命令**，
#      而它排在综合之后、报告之前，于是整趟跑完位流却卡在读报告上，
#      位流白出了。报告逻辑只留一处，就不会再有第二份写错的副本。
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "FLOW_FAIL: synth_1 没到 100%"
    exit 1
}

}
# ── 3. 实现 ───────────────────────────────────────────────────────────────
puts "==> \[flow\] 实现 impl_1"
if {[info exists ::env(LOCALIZER_FLOORPLAN)] && $::env(LOCALIZER_FLOORPLAN) eq "1"} {
    set_property STEPS.OPT_DESIGN.TCL.POST [file join $here apply_localizer_floorplan.tcl] [get_runs impl_1]
}
if {[catch {
    # 只跑到布线：位流在第 5 步从**补过 phys_opt 的那一版**出。
    launch_runs impl_1 -to_step route_design -jobs 4
    wait_on_run impl_1
} e]} {
    puts "FLOW_FAIL: launch_runs impl_1 抛异常: $e"
    exit 1
}
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "FLOW_FAIL: impl_1 没到 100%（progress = [get_property PROGRESS [get_runs impl_1]]）"
    exit 1
}
puts "IMPL_OK"

# ── 4. 布线后补一遍 phys_opt + route（2026-10-02 加，依据 docs/issues/057）──
# 为什么**必须写进流程**而不是事后手动跑：手动跑出来的成果只在内存里，
# 位流是从**没优化过的那份**实现出的 —— 那等于自欺欺人。
# 实测（默认策略）：WNS −1.506 → −0.616，失效端点 294 → 163，TNS −181 → −35。
# 再迭代两遍就收敛（−0.616 / −0.604），所以跑一遍就够。
# ⚠ 这一段在 open_run impl_1 **之后**、出位流**之前** —— 位流必须从这一版出。
puts "==> \[flow\] 布线后补 phys_opt"
if {[catch {
    open_run impl_1
    phys_opt_design
    route_design
} e]} {
    puts "FLOW_FAIL: 布线后 phys_opt/route 抛异常: $e"
    exit 1
}
puts "PHYSOPT_OK"
if {[info exists ::env(LOCALIZER_FLOORPLAN)]} {
    source [file join $here report_localizer_physical.tcl]
}
set setup_slack [get_property SLACK [get_timing_paths -delay_type max]]
set hold_slack [get_property SLACK [get_timing_paths -delay_type min]]
if {$setup_slack eq "" || $hold_slack eq "" || $setup_slack < 0 || $hold_slack < 0} {
    report_timing_summary -delay_type min_max -file [file join $output_dir timing_zynq.rpt]
    puts "FLOW_FAIL: timing setup=$setup_slack hold=$hold_slack"
    exit 1
}

# ── 5. 位流（从上面那一版内存里的实现直接出）────────────────────────────
puts "==> \[flow\] 出位流"
if {[catch {
    write_bitstream -force [file join $proj_dir rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
} e]} {
    puts "FLOW_FAIL: write_bitstream 抛异常: $e"
    exit 1
}
puts "BIT_OK"

# ── 6. 报告：时序 + 资源 + **引脚落点** ───────────────────────────────────
puts "==> \[flow\] ==== 时序 ===="
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $output_dir timing_zynq.rpt]
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
# ⚠ 不要用 `get_timing_paths -max_paths 100000` 去凑 TNS。它是**逐条枚举**的：
#   本设计 57,025 个端点、9,762 个失效，这一行会把整个流程**卡死在报告段**
#   （实测 2026-10-02：位流早就出来了，报告段挂了十几分钟不动，只能强杀）。
#   TNS 从刚写出的报告里读 —— 那是同时刻、同一份数据，且是权威口径。
set tns "?"
set fh [open [file join $output_dir timing_zynq.rpt] r]
set rpt [read $fh]
close $fh
# Design Timing Summary 表：表头下一行是 ------，再下一行才是数字
if {[regexp {\|\s*\n\s*WNS\(ns\)[^\n]*\n\s*-+[^\n]*\n\s*(-?[0-9.]+)\s+(-?[0-9.]+)} $rpt -> _w _t]} {
    set tns $_t
}
puts "      WNS = $wns ns     WHS = $whs ns"
puts "      （WNS ≥ 0 才算时序收敛）"
puts "REPORT_TIMING_OK"

puts "==> \[flow\] ==== 资源 ===="
report_utilization -file [file join $output_dir util_zynq.rpt]
puts "REPORT_UTIL_OK"

# ⚠ 这一段是 issues/039 里写明"必须等 039 修好才能做"的那一步：
#   综合/实现之后用 report_io 读出**实际落到的 IO 站点**，与 docs/board_io.md 的表逐脚对。
puts "==> \[flow\] ==== 引脚落点（与 docs/board_io.md 表对照）===="
report_io -file [file join $output_dir io_zynq.rpt]
foreach p {tacho_i pdm_clk_o} {
    set pin [get_ports -quiet $p]
    if {$pin ne ""} {
        set site [get_property SITE [get_ports $p] -quiet]
        set pkg  [get_property PACKAGE_PIN [get_ports $p] -quiet]
        puts [format "      %-16s %-8s %s" $p $pkg $site]
    }
}
# pdm_din_i 是 8 位总线，逐位列出来 —— 位选写错（[8:1] vs [7:0]）只会静默少约束几位
foreach prt [lsort [get_ports -quiet {pdm_din_i[*]}]] {
    puts [format "      %-16s %-8s %s" [get_property NAME $prt] \
              [get_property PACKAGE_PIN $prt -quiet] [get_property SITE $prt -quiet]]
}
puts "REPORT_IO_OK"
write_checkpoint -force [file join $output_dir das_fir_routed.dcp]
write_hw_platform -fixed -include_bit -force -file [file join $output_dir das_fir.xsa]

puts ""
puts "FLOW_PASS: 综合/实现/位流/报告全部完成"
puts "           timing [file join $output_dir timing_zynq.rpt]"
puts "           utilization [file join $output_dir util_zynq.rpt]"
puts "           IO [file join $output_dir io_zynq.rpt]"
puts "           位流     [get_property DIRECTORY [get_runs impl_1]]/../impl_1/${top}.bit"
