# PDM 前端 8ch vs 16ch 的**孤立综合（OOC）资源对比**。
#
#   vivado -mode batch -notrace -source scripts/report_pdm_16ch_ooc.tcl
#
# 为什么要有这个脚本：顶层 `report_ooc_hier.tcl` 只给得出**现状（8 麦）**的
# 分模块数字，回答不了「换 16 麦要加多少」。改 rv32_soc.v 的 N_CH 再跑整条
# 实现要二十多分钟，而且会把仓库的现状配置改掉。这里换个做法：
# 把 PDM 前端这 5 个 RTL 单独拎出来，**同一条综合命令跑 N_CH=8 和 N_CH=16 两遍**，
# 差出来的就是纯粹的通道数增量。
#
# ⚠ 它给的是**孤立综合**的绝对数，与顶层内联后的数字会有出入（跨边界优化、
#   常量传播）。所以：
#   · 绝对值看 `build/util_hier.rpt`（那是 routed 实测）
#   · **增量看这里**（同一条件下两遍对比，系统偏差互相抵消）
#
# 与 scripts/report_ooc_hier.tcl 的分工：那个读工程里已有的 run，回答"现状是谁吃掉的"；
# 这个临时搭一个 OOC 顶层，回答"通道数翻倍要加多少"。

set here [file dirname [info script]]
set root [file normalize [file join $here ..]]
set rdir [file join $root rtl array]
set bdir [file join $root build]

# ── 临时 OOC 顶层：把三块串起来（与 rv32_soc.v 里的接法一致）────────────
set topfile [file join $bdir pdm_ooc_top.v]
set fh [open $topfile w]
puts $fh {module pdm_ooc_top #(parameter integer N_CH = 8, parameter integer MICS_PER_LINE = 1) (
  input                       clk_i,
  input                       rst_n_i,
  input                       en_i,
  input  [N_CH/MICS_PER_LINE-1:0] pdm_din_i,
  output                      pdm_clk_o,
  output [N_CH*24-1:0]        audio_o,
  output                      valid_o,
  input                       cap_wr_i,
  input                       cap_rd_i,
  input  [6:0]                cap_addr_i,
  input  [31:0]               cap_wdata_i,
  output [31:0]               cap_rdata_o
);
  wire [N_CH*24-1:0] raw, aligned;
  wire v_raw, v_al, cap_en;
  wire [31:0] frame_cnt;
  wire [N_CH-1:0] frozen;
  wire [N_CH*16-1:0] gain;

  rv32_pdm_array_rx #(.N_CH(N_CH), .MICS_PER_LINE(MICS_PER_LINE), .OUT_W(24), .ORDER(3),
                      .DECIM(64), .ACC_W(24), .HOLD_TICK(4), .CONSUME_TICK(12),
                      .LOSS_FRAMES(4096)) u_rx (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(en_i),
    .pdm_din_i(pdm_din_i), .pdm_clk_o(pdm_clk_o),
    .audio_vec_o(raw), .sample_valid_o(v_raw),
    .frame_cnt_o(frame_cnt), .frozen_o(frozen));

  rv32_chan_align #(.N_CH(N_CH), .IN_W(24), .OUT_W(24), .DC_K(9)) u_align (
    .clk_i(clk_i), .rst_n_i(rst_n_i), .en_i(cap_en),
    .audio_vec_i(raw), .valid_i(v_raw), .gain_q_i(gain),
    .audio_vec_o(aligned), .valid_o(v_al));

  rv32_pdm_capture #(.N_CH(N_CH), .IN_W(24), .FRAME_AW(9)) u_cap (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .audio_vec_i(aligned), .valid_i(v_al), .frame_cnt_i(frame_cnt),
    .frozen_i(frozen), .cfg_wr_i(cap_wr_i), .cfg_rd_i(cap_rd_i),
    .cfg_addr_i(cap_addr_i), .cfg_wdata_i(cap_wdata_i),
    .cfg_rdata_o(cap_rdata_o), .en_o(cap_en), .gain_o(gain));

  assign audio_o = aligned;
  assign valid_o = v_al;
endmodule}
close $fh

# ── 三遍综合 ──────────────────────────────────────────────────────────
# 第三组 `16 2` 才是 rv32_soc.v 里真正例化的**出货拓扑**（16 麦共线 = 8 根 DIN）。
# 前两组是"每线一个麦"的对照 —— 旧版只跑 {8 16}，测的是 16 根**独立线**，
# 拿它当共线的增量只是**代理**，不是实测。现在第三组把 8 个保持寄存器与
# 2:1 输入选择也一并算进去。
set results {}
foreach cfg {{8 1} {16 1} {16 2}} {
    lassign $cfg n mpl
    puts "=========== N_CH = $n  MICS_PER_LINE = $mpl ==========="
    read_verilog \
        [file join $rdir rv32_pdm_clkgen.v] \
        [file join $rdir rv32_pdm_cic.v] \
        [file join $rdir rv32_pdm_array_rx.v] \
        [file join $rdir rv32_chan_align.v] \
        [file join $rdir rv32_pdm_capture.v] \
        $topfile
    synth_design -top pdm_ooc_top -part xc7z020clg400-1 -mode out_of_context \
                 -generic N_CH=$n -generic MICS_PER_LINE=$mpl -flatten_hierarchy rebuilt

    set rpt [file join $bdir util_pdm_${n}ch_m${mpl}_ooc.rpt]
    report_utilization -file $rpt

    set luts 0; set ffs 0; set bram 0; set dsp 0
    foreach line [split [report_utilization -return_string] "\n"] {
        if {[regexp {^\|\s*Slice LUTs\*?\s*\|\s*(\d+)} $line -> v]} { set luts $v }
        if {[regexp {^\|\s*Slice Registers\s*\|\s*(\d+)} $line -> v]} { set ffs  $v }
        if {[regexp {^\|\s*Block RAM Tile\s*\|\s*(\d+)} $line -> v]} { set bram $v }
        if {[regexp {^\|\s*DSPs\s*\|\s*(\d+)} $line -> v]} { set dsp  $v }
    }
    puts [format "  N_CH=%d MICS_PER_LINE=%d : LUT %d  FF %d  BRAM_tile %d  DSP %d" \
          $n $mpl $luts $ffs $bram $dsp]
    lappend results [list $n $mpl $luts $ffs $bram $dsp]

    # 换参数要重新读源，否则第二次还是上次的网表
    remove_files [get_files -quiet]
    close_design
}

puts ""
puts "=========== PDM 前端 OOC 对比 ==========="
puts [format "  %-6s %-14s %8s %8s %10s %6s" N_CH MICS_PER_LINE LUT FF BRAM DSP]
foreach r $results {
    lassign $r n mpl luts ffs bram dsp
    puts [format "  %-6d %-14d %8d %8d %10d %6d" $n $mpl $luts $ffs $bram $dsp]
}
# 增量一律相对**现状基线**（第一组 8/1）算 —— 验收要看的是"比现在多了多少"。
lassign [lindex $results 0] _ _ l0 f0 b0 d0
foreach r [lrange $results 1 end] {
    lassign $r n mpl luts ffs bram dsp
    puts [format "  %-6s %-14s %8d %8d %10d %6d" \
          "delta" "$n/$mpl" [expr {$luts-$l0}] [expr {$ffs-$f0}] \
          [expr {$bram-$b0}] [expr {$dsp-$d0}]]
}
puts "PDM_OOC_DONE"
