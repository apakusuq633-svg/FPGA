// 16 通道 PDM 麦阵列前端（**两麦共线**）—— rv32_pdm_array_rx 的薄封装。
//
// 固定 N_CH = 16、MICS_PER_LINE = 2 ⇒ **8 根数据线**（+1 根时钟 = 9 根信号脚）。
// 这是出货拓扑：每根线上挂两个麦，一个 LR=GND、一个 LR=VDD，
// 分别占低半周期与高半周期（IM73D122V01 datasheet §3.5 Table 8）。
//
// 通道映射：通道 2k = 线 k 的相位 A（LR=GND），通道 2k+1 = 线 k 的相位 B（LR=VDD）。
//
// ⚠ 本文件以前是「16 通道 / 16 根 DIN / 17 根信号脚」那版。那条路已经**作废**：
//   它要多占 J3 的 5–14（原 LCD/触摸段），载板从没按它排过线；而共线把 16 麦
//   压回 9 根，正好是 J3 上已经上板验过的那批脚。要 16 根 DIN 的配置仍然写得出来
//   （直接例化 rv32_pdm_array_rx 并给 MICS_PER_LINE=1），只是没有对应的硬件。
//
// ⚠ 与 8ch 版一样：**这里不许加任何逻辑**，只做参数绑定和端口透传。
module rv32_pdm_array_rx_16ch #(
  parameter integer OUT_W        = 24,
  parameter integer ORDER        = 3,
  parameter integer DECIM        = 64,
  parameter integer ACC_W        = 24,
  parameter integer HOLD_TICK    = 4,
  parameter integer CONSUME_TICK = 12,
  parameter integer LOSS_FRAMES  = 4096
) (
  input                 clk_i,
  input                 rst_n_i,
  input                 en_i,
  input  [7:0]          pdm_din_i,
  output                pdm_clk_o,
  output [16*OUT_W-1:0] audio_vec_o,
  output                sample_valid_o,
  output [31:0]         frame_cnt_o,
  output [15:0]         frozen_o
);

  rv32_pdm_array_rx #(
    .N_CH          (16),
    .MICS_PER_LINE (2),
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
