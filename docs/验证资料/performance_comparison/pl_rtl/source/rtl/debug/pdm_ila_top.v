// Board diagnostic: instantiate the production receiver without PS/software gating.
module pdm_ila_top (
  input clk_50m,
  input rst_n,
  input [3:0] pdm_din_i,
  output pdm_clk_o
);
  wire clk40, locked;
  pdm_debug_clock u_clock (.clk_in1(clk_50m), .resetn(rst_n),
    .clk_out1(clk40), .locked(locked));
  reg [7:0] por = 0;
  always @(posedge clk40 or negedge locked)
    if (!locked) por <= 0;
    else if (!(&por)) por <= por + 1'b1;
  wire reset_ok = (&por) & locked;
  wire [191:0] pcm;
  wire valid;
  wire [31:0] frame;
  wire [7:0] frozen;
  // Diagnostic trial: late sample within each half-cycle (175 ns after edge).
  rv32_pdm_array_rx #(.N_CH(8), .MICS_PER_LINE(2),
    .HOLD_TICK(6), .CONSUME_TICK(14)) u_rx (
    .clk_i(clk40), .rst_n_i(reset_ok), .en_i(1'b1),
    .pdm_din_i(pdm_din_i), .pdm_clk_o(pdm_clk_o),
    .audio_vec_o(pcm), .sample_valid_o(valid),
    .frame_cnt_o(frame), .frozen_o(frozen));
  // Raw probe: [3:0] DIN, [7:4] held A, [11:8] B input FF,
  // [12] hold, [13] consume, [14] valid, [15] PDM CLK, [25:16] divider.
  wire [3:0] b_bits = {
    u_rx.g_line[3].g_phase_b.u_cic_b.bit_q,
    u_rx.g_line[2].g_phase_b.u_cic_b.bit_q,
    u_rx.g_line[1].g_phase_b.u_cic_b.bit_q,
    u_rx.g_line[0].g_phase_b.u_cic_b.bit_q};
  wire [25:0] raw = {u_rx.u_clkgen.div_q, pdm_clk_o, valid,
    u_rx.bit_en_w, u_rx.hold_en_w, b_bits, u_rx.phase_a_q, pdm_din_i};
  ila_pdm_raw u_ila_raw (.clk(clk40), .probe0(raw));
  ila_pdm_pcm u_ila_pcm (.clk(clk40), .probe0(pcm), .probe1(valid),
    .probe2(frame), .probe3(frozen));
endmodule
