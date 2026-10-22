# 从实现完成的 Vivado 工程导出 XSA —— 整个 Vitis 侧（平台 / BSP / 驱动）都建立在这个产物上。
#
# 用法：vivado -mode batch -source scripts/export_xsa.tcl
#      或在 Vivado 里 source 本文件（工程可以已经打开）
#
# 为什么单独一个脚本、不塞进 create_zynq_project.tcl：
#   那个脚本只**建工程**，不跑综合实现（实现要十几分钟）。而 XSA 要带比特流就必须先有
#   实现结果，所以这一步只能排在实现之后。塞进建工程脚本的话，它永远在实现之前跑，
#   只能导出一个没有比特流的 XSA。
#
# ── 这个脚本为什么必须存在（踩过的坑，别删）──────────────────────────────────
# XSA 曾经是**手工在 GUI 里导**的，没有任何东西保证它和 BD 同步。结果：BD 里已经改过的
# 配置没有进 XSA，仓库里的 XSA 还是更早那一版。
# 后果不是报错而是**静默缺件**：Vitis 照那份 XSA 生成的 BSP 里少了对应的驱动，
# `xparameters.h` 里也就没有那个 XPAR_*_DEVICE_ID，PS 侧的 C 在 Vitis 里连头文件
# 都找不到 —— 而这一切在主机侧编译检查里完全看不出来。
# 所以本脚本导完之后**自己校验一遍**，把"XSA 和 BD 不一致"当场喊出来。

set root [file normalize [file join [file dirname [info script]] ..]]
set proj_dir [file join $root vivado_zynq]
set proj_name rv32_zynq
set xsa [file join $proj_dir ps_pl_wrapper.xsa]

# ---- 工程 / 实现状态 ----
if {[llength [current_project -quiet]] == 0} {
    if {![file exists [file join $proj_dir ${proj_name}.xpr]]} {
        puts "==> ERROR: project not found: $proj_dir/${proj_name}.xpr"
        puts "==>        Run create_zynq_project.tcl first."
        exit 1
    }
    open_project [file join $proj_dir ${proj_name}.xpr]
}

# 判据是**比特流文件在不在**，不是 impl_1 的 PROGRESS。这一条踩过：
# PROGRESS 到 100% 只说明布线跑完了，比特流是**另一级**；上一次就因为这个去调
# write_hw_platform，报 "Unable to get BIT file from implementation run"。
proc bitfile_of {run} {
    set dir [get_property DIRECTORY [get_runs $run]]
    foreach f [glob -nocomplain [file join $dir *.bit]] { return $f }
    return ""
}

set want_impl 1
if {[info exists argv] && [lsearch -exact $argv "-no-impl"] >= 0} { set want_impl 0 }

# File existence does not imply freshness. Vivado tracks RTL/XDC changes on the runs.
update_compile_order -fileset sources_1
set stale_synth [get_property NEEDS_REFRESH [get_runs synth_1]]
set stale_impl [get_property NEEDS_REFRESH [get_runs impl_1]]
if {$stale_synth || $stale_impl} {
    if {!$want_impl} { error "Stale implementation: -no-impl cannot export an old bitstream" }
    if {$stale_synth} {
        reset_run synth_1
    } else {
        reset_run impl_1
    }
}

set bit [bitfile_of impl_1]
if {$bit ne ""} {
    puts "==> bitstream present: $bit"
} else {
    puts "==> impl_1 status: [get_property STATUS [get_runs impl_1]] (progress [get_property PROGRESS [get_runs impl_1]])"
    puts "==> no bitstream yet -- launching write_bitstream (and synthesis/implementation"
    puts "==>  first if they are not done; the whole chain is on the order of 10-20 minutes,"
    puts "==>  the bitstream step alone a few minutes. Ctrl-C is safe.)"
    if {!$want_impl} {
        puts "==> ERROR: -no-impl was given, so nothing was launched. Run:"
        puts "==>          launch_runs impl_1 -to_step write_bitstream; wait_on_run impl_1"
        exit 1
    }
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        launch_runs synth_1 -jobs 4
        wait_on_run synth_1
        if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }
    }
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    set bit [bitfile_of impl_1]
    if {$bit eq ""} {
        puts "==> ERROR: still no bitstream (status: [get_property STATUS [get_runs impl_1]])"
        puts "==>        Nothing exported. Look at the run log:"
        puts "==>          vivado_zynq/${proj_name}.runs/impl_1/runme.log"
        exit 1
    }
    puts "==> bitstream written: $bit"
}

# ---- 导出 ----
open_run impl_1
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} { error "No timing paths found" }
set wns [get_property SLACK $setup_path]
set whs [get_property SLACK $hold_path]
report_timing_summary -file [file join $proj_dir board_timing_summary.rpt]
report_utilization -file [file join $proj_dir board_utilization.rpt]
if {$wns < 0 || $whs < 0} { error "Timing failed: WNS=$wns WHS=$whs; XSA not exported" }
puts "==> Timing passed: WNS=$wns ns WHS=$whs ns"
puts "==> writing hardware platform: $xsa"
if {[catch {
    write_hw_platform -fixed -include_bit -force $xsa
} err]} {
    puts "==> ERROR: write_hw_platform failed: $err"
    exit 1
}
puts "==> wrote $xsa"

# ---- 校验交给 verify，不在这里做 ----
# XSA 是个 zip，检查它内部的 .hwh 需要读 zip。Tcl 侧只有 Vivado 私有的 zipfs，本脚本
# 在 tclsh 里没法自测；而 Python 的 zipfile 是标准库。所以「XSA 和 BD 说的一致吗」
# 这条检查放在 scripts/check_ps_apps.py 里（verify.ps1 第 14 项会跑它），
# 它同时还会比对 BD 分配的从端地址与各 C 源码里的 RV32_BASE。
#
# 导完立刻验一遍的话，跑：
#   powershell scripts/verify.ps1
puts "==> Now check the XSA against the BD (slave offset):"
puts "==>   powershell scripts/verify.ps1      (item 14 covers it)"

puts "==> Done. Next: update the platform so the BSP picks up the new hardware:"
puts "==>   xsct -eval {setws <workspace>; platform config -updatehw $xsa; platform generate}"
puts "==> or simply re-run: xsct scripts/create_ps_apps.tcl   (it calls platform generate)"
