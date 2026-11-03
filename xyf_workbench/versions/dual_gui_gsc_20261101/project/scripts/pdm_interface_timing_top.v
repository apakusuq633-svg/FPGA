// Focused physical interface implementation, not a full SoC or board bitstream.
module pdm_interface_timing_top #(
  parameter HOLD_TICK=4, parameter CONSUME_TICK=12
)(
  input clk_i,rst_n_i,en_i,input [5:0] pdm_din_i,
  output pdm_clk_o,output sample_valid_o,output [23:0] signature_o
);
  wire [287:0] pcm;
  rv32_pdm_array_rx #(.HOLD_TICK(HOLD_TICK),.CONSUME_TICK(CONSUME_TICK)) u_rx(.clk_i(clk_i),.rst_n_i(rst_n_i),.en_i(en_i),
    .pdm_din_i(pdm_din_i),.pdm_clk_o(pdm_clk_o),.audio_vec_o(pcm),
    .sample_valid_o(sample_valid_o),.frame_cnt_o(),.frozen_o());
  assign signature_o=pcm[23:0]^pcm[47:24]^pcm[71:48]^pcm[95:72]^
    pcm[119:96]^pcm[143:120]^pcm[167:144]^pcm[191:168]^
    pcm[215:192]^pcm[239:216]^pcm[263:240]^pcm[287:264];
endmodule
