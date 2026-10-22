# XSCT 2020.2, configured xc7z020clg400-1. -check validates paths without connecting.
# Each real launch resets the whole Zynq so CPU1 starts in the BootROM wait loop.
# 上板前先确认板子没被别的项目占（见 scripts/jtag_guard.tcl）
source [file join [file dirname [info script]] jtag_guard.tcl]

set root [file normalize [file join [file dirname [info script]] ..]]
set ws D:/Vitis
set app rv32_app
set check_only 0
set elf_override ""
set bit_override ""
set init_override ""
for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -ws { incr i; set ws [lindex $argv $i] }
        -app { incr i; set app [lindex $argv $i] }
        -elf { incr i; set elf_override [lindex $argv $i] }
        -bit { incr i; set bit_override [lindex $argv $i] }
        -init { incr i; set init_override [lindex $argv $i] }
        -check { set check_only 1 }
        default { error "Usage: run_board.tcl -app <name> ?-ws D:/Vitis? ?-elf <path.elf>? ?-bit <path.bit>? ?-init <ps7_init.tcl>? ?-check?" }
    }
}
if {[lsearch -exact {rv32_app dualcore_app fft_app pdm_app ui_app} $app] < 0} {
    error "Unknown app: $app"
}
set bit [file join $root vivado_zynq rv32_zynq.runs impl_1 ps_pl_wrapper.bit]
set init [file join $ws PS-PL hw ps7_init.tcl]
if {$bit_override ne ""} { set bit $bit_override }
if {$init_override ne ""} { set init $init_override }

# ELF 的选择：**以 Vitis 的为准**（$ws/$app/Debug/$app.elf，链在 DDR 0x100000）。
#
# 历史：DDR 参数曾经配错（4Gb 的板配成 2Gb，写丢约 9%），那时链到 DDR 的 app 一跑
# 就把 PS 互连同 DAP 一起锁死。当时的绕法是 app 重链到 OCM
# （scripts/build_a9_ocm.sh → build/a9_ocm/<app>_ocm.elf），本脚本一度优先用它。
# **DDR 已于 2026-10-04 修好**（实测 DDR 写 11/128 错 → 0/128，DDR 版 app PASS），
# 所以恢复成"以 Vitis 的为准"；OCM 版只在它缺失时兜底。
# 详见 docs/issues/067。
#
# 要强制指定用哪一份（比如复验 OCM 路线）：-elf <path>
set elf [file join $ws $app Debug ${app}.elf]
set ocm_elf [file join $root build a9_ocm ${app}_ocm.elf]
if {$elf_override ne ""} {
    puts "==> 用 -elf 指定的 ELF：$elf_override"
    set elf $elf_override
} elseif {![file isfile $elf] && [file isfile $ocm_elf]} {
    puts "==> Vitis 的 ELF 不在，回退到 OCM 版：$ocm_elf"
    set elf $ocm_elf
}
foreach path [list $bit $init $elf] {
    if {![file isfile $path]} { error "Build artifact missing: $path" }
    puts "==> $path"
}
if {$check_only} { puts "==> Paths OK. No hardware connection or programming attempted."; exit 0 }
connect
targets -set -filter {name =~ "APU"}
rst -system
after 1000
targets -set -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -filter {name =~ "*Cortex-A9*#0"}
source $init
ps7_init
ps7_post_config
rst -processor
dow $elf
con
puts "==> Running $app. Read PS UART0 at 115200 8N1."
disconnect
