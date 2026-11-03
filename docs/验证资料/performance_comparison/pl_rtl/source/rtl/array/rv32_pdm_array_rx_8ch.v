// 8 通道 PDM 麦阵列前端 —— rv32_pdm_array_rx 的**薄封装**。
//
// 固定 N_CH = 8、MICS_PER_LINE = 1 ⇒ **8 根数据线，每线一个麦**（LR 接 GND）。
// 这是 8 麦配置：8 根 DIN 就是 L-04 里的偶数槽位（槽位 0,2,…,14）。
// 它没有被 rv32_soc.v 采用（那边走 16 麦共线），保留是为了 8 麦的接法与几何
// 仍然可复现 —— 共线拓扑把奇数槽位的麦补挂到同一条线上就变成 16 麦。
//
// 为什么要封装：SoC 例化点的端口列表是死的，`rv32_pdm_array_rx #(.N_CH(8))`
// 只是参数覆盖，读的人要回去数才知道用的是几通道。封装之后「8 还是 16」
// 在例化那一行就看得见。
//
// ⚠ **这里不许加任何逻辑。** 所有实质内容都在 rv32_pdm_array_rx.v 里，
//   这个文件只做参数绑定和端口透传。一旦在这里加东西，8ch 和 16ch 就有了
//   两份会慢慢漂开的实现 —— 那正是本仓库 CLAUDE.md §1 反对的「两套口径」。
module rv32_pdm_array_rx_8ch #(
  parameter integer OUT_W        = 24,
  parameter integer ORDER        = 3,
  parameter integer DECIM        = 64,
  parameter integer ACC_W        = 24,
  parameter integer HOLD_TICK    = 4,
  parameter integer CONSUME_TICK = 12,
  parameter integer LOSS_FRAMES  = 4096
) (
  input                clk_i,
  input                rst_n_i,
  input                en_i,
  input  [7:0]         pdm_din_i,
  output               pdm_clk_o,
  output [8*OUT_W-1:0] audio_vec_o,
  output               sample_valid_o,
  output [31:0]        frame_cnt_o,
  output [7:0]         frozen_o
);

  rv32_pdm_array_rx #(
    .N_CH          (8),
    .MICS_PER_LINE (1),
    .OUT_W         (OUT_W),
    .ORDER         (ORDER),
    .DECIM         (DECIM),
    .ACC_W         (ACC_W),
    .HOLD_TICK     (HOLD_TICK),
    .CONSUME_TICK  (CONSUME_TICK),
    .LOSS_FRAMES   (LOSS_FRAMES)
  ) u_core (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .en_i           (en_i),
    .pdm_din_i      (pdm_din_i),
    .pdm_clk_o      (pdm_clk_o),
    .audio_vec_o    (audio_vec_o),
    .sample_valid_o (sample_valid_o),
    .frame_cnt_o    (frame_cnt_o),
    .frozen_o       (frozen_o)
  );

endmodule
