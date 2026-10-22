# 综合（或实现）完成后 source 本文件，打印本设计关心的资源项。
# 用法：Vivado 菜单 Tools -> Run Tcl Script...，或 Tcl Console 里 source {<本文件路径>}。
#
# launch_runs 是异步的：综合还在跑就先等它跑完再打开结果，不会再报 no open design。

proc no_design {} { expr {[llength [current_design -quiet]] == 0} }

if {[no_design]} {
    # 有跑完的实现结果就优先用它，实现后的数字才是最终数字。
    set run synth_1
    if {[llength [get_runs -quiet impl_1]]} {
        if {[get_property PROGRESS [get_runs impl_1]] eq "100%"} { set run impl_1 }
    }

    # 只在真的在跑的时候才等，没启动的 run 等下去会挂死。
    set status [get_property STATUS [get_runs $run]]
    if {[string match "*Running*" $status] || [string match "*Queued*" $status]} {
        puts "==> $run is running, waiting for it to finish..."
        wait_on_run $run
    }

    set status [get_property STATUS [get_runs $run]]
    if {[get_property PROGRESS [get_runs $run]] ne "100%" || [string match "*Error*" $status]} {
        puts "==> $run is not complete (status: $status)"
        puts "==> launch it first, or check vivado/rv32_pipeline.runs/$run/runme.log"
        return
    }
    open_run $run
}

puts "==> [current_design]"

# 利用率主表里挑出关心的几行，比在 GUI 里翻 Hierarchy 快。
# 行名后面可能带星号（Slice LUTs* 表示含 LUTRAM），星号要允许。
foreach line [split [report_utilization -return_string] "\n"] {
    if {[regexp {^\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs|DSP48E1|LUT as Distributed RAM|Bonded IOB)\*?\s*\|} $line]} {
        puts $line
    }
}

# latch 和 BRAM 直接数实例，判断"同步读是否推成 BRAM"看这个最直接。
puts [format "  Latch cells     %d" [llength [get_cells -hier -quiet -filter {REF_NAME =~ "LD*"}]]]
puts [format "  RAMB cells      %d" [llength [get_cells -hier -quiet -filter {REF_NAME =~ "RAMB*"}]]]
# M 扩展的乘法器：rv32_mul_unit 里只写了一个 `*`，整设计再没有第二处乘法。
# 所以这个数就是那一个 32x32 的实际代价，预期 3~4（DSP48E1 是 25x18，要拆）。
# 它不该随 M 指令条数增长 —— 若看到 8 以上，说明有人又写了第二个 `*` 而不是复用。
puts [format "  DSP48 cells     %d" [llength [get_cells -hier -quiet -filter {REF_NAME =~ "DSP48*"}]]]
