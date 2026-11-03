# 一键建立 Vivado 工程。所有路径由脚本自身位置推导，工程拷到任何目录/电脑都不用改。
#
# 用法（二选一）：
#   * Vivado 菜单 Tools -> Run Tcl Script...，选本文件；
#   * 或在 Tcl Console 里：source {<本文件路径>}
#
# 注意：会在 <工程根>/vivado 下重建工程，该目录已存在时会被覆盖。
#
# 约定：**要打印出来的字符串一律写 ASCII**。Tcl 在这台机器上按 cp936 读源码，
# 字符串里的中文会被解成乱码，报错信息完全没法读。注释用中文没问题。

# ---- 工程根 = 本脚本所在目录的上一级 ----
set root [file normalize [file join [file dirname [info script]] ..]]

# ---- 顶层选择 ----
# 两个候选都由 scripts/gen_synth_top.tcl 生成，都给 ITCM 预装了程序。装程序这一步不能省：
# ITCM 内容为空时取指数据是未知量，综合把整个核当 don't care 删掉，同一份 RTL 实测
# 98 个触发器（空壳）对 4330 个（完整）。
#   rv32_board_top  第一版的交付物：上板跑流水灯。引脚见 constrs/rv32_board_top.xdc，
#                   ITCM 装的是 sw/led_demo.hex
#   rv32_synth_top  时序评估用：无引脚、保留 retire_* 输出，ITCM 装 tb_rv32_soc.v 里的自检程序
# 顶层名必须和 constrs/ 下的 xdc 同名 —— 下面按文件名找约束，名字对不上只会得到警告，
# 然后不加任何约束就跑综合。
set part       "xc7z020clg400-1"
set top_module "rv32_board_top"

set proj_dir  [file join $root vivado]
set proj_name rv32_pipeline

# ---- 从 scripts/filelist.f 读清单，保持单一来源 ----
# rtl 之外的行（tb/）归到仿真集，其余进综合集。
set rtl_files {}
set tb_files  {}
set fp [open [file join $root scripts filelist.f] r]
foreach line [split [read $fp] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    if {[string match "tb/*" $line]} {
        lappend tb_files [file join $root $line]
    } else {
        lappend rtl_files [file join $root $line]
    }
}
close $fp

# ---- 建工程 ----
create_project $proj_name $proj_dir -part $part -force

add_files -norecurse $rtl_files

# ---- 生成顶层：ITCM 装程序 ----
# 只加选中的那个。两个都加的话会有两个顶层模块抢 top，Vivado 直接报错。
source [file join $root scripts gen_synth_top.tcl]
switch -- $top_module {
    rv32_board_top {
        add_files -norecurse [gen_board_top $root $proj_dir]
    }
    rv32_synth_top {
        add_files -norecurse [gen_synth_top $root $proj_dir]
    }
    default {
        error "top_module must be rv32_board_top or rv32_synth_top, got: $top_module"
    }
}
set_property top $top_module [current_fileset]

# 关键一步：rv32_defines.vh 不进 fileset（它是 include 文件，不是编译单元），
# 只把 rtl 目录塞进 include 搜索路径，11 处 `include 才能解析。
set_property include_dirs [list [file join $root rtl]] [current_fileset]

# ROM 预装的绝对路径（相对路径在 run 目录下找不到，见 rom_preload.tcl 头部）
source [file join $root scripts rom_preload.tcl]

# ---- 约束：一个顶层一个 xdc，文件名与顶层同名 ----
# 时钟约束两个顶层都要（少了它时序报告全是 unconstrained），引脚只在板级那份里写。
set xdc_file [file join $root constrs $top_module.xdc]
if {[file exists $xdc_file]} {
    add_files -fileset constrs_1 -norecurse $xdc_file
} else {
    puts "==> WARNING: no $xdc_file; synthesizing without constraints"
}

# ---- 仿真集（只做综合可整段删掉）----
add_files -fileset sim_1 -norecurse $tb_files
set_property top tb_rv32_soc [get_filesets sim_1]
set_property include_dirs [list [file join $root rtl]] [get_filesets sim_1]

# ---- 实现策略 ----
# 默认 strategy 下 50 MHz 差 0.294ns（加了 SIMD-MAC 阵列之后；把阵列整个不例化也还差
# 0.117ns —— 不是阵列单方面的锅）。同一份网表只换 strategy 实测四条：
#   ExplorePostRoutePhysOpt +0.030 | 默认 -0.294 | Explore -0.439 | RefinePlacement -0.765
# 只有这一条收敛，和 Zynq 那条一样是量出来的、不是按名字挑的。
#
# ⚠ 扫 strategy 之前必须 reset_run synth_1：impl 不重新综合就沿用上一份 DCP，而 run
# 目录是文件系统耦合的。这里踩过一次 —— 量出来的数根本不是本设计的。
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

# ---- 综合策略 ----
# 2026-09 复测：只钉实现策略**不够**，这份 RTL 上 50 MHz 是 -0.158ns。加上下面这条
# 综合策略之后 +0.024ns（MET），关键路径的逻辑级数从 27 降到 19 —— 是**逻辑做浅了**，
# 不是重新摆放撞运气（对比：phys_opt 调 AggressiveExplore 只重摆放，实测反而 -0.482）。
#
# 为什么这个杠杆在裸 PL 这边有效、在 Zynq 那边无效：Zynq 的核是 BD 里的模块引用、
# 走 OOC 独立综合，关键路径根本不在 synth_1 里，换它没用；这边是**平铺综合**，
# 整条关键路径就在 synth_1 里。
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "==> Project created at $proj_dir"
puts "==> include_dirs = [get_property include_dirs [current_fileset]]"
