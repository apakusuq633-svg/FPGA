`timescale 1ns/1ps
// Differential simulation only: bind the current receiver to the original
// reference's 768 kHz clock generator, DECIM=16 and PCM16. This deliberately
// isolates the receiver from the differing production clock configuration.
module rv32_pdm_clkgen #(parameter HOLD_TICK=4,CONSUME_TICK=12)(
  input clk_i,rst_n_i,en_i,
  output pdm_clk_o,hold_en_o,bit_en_o,decim_en_o
);
  pdm_clkgen original(.clk_i(clk_i),.rst_n_i(rst_n_i),.en_i(en_i),
    .pdm_clk_o(pdm_clk_o),.hold_en_o(hold_en_o),.bit_en_o(bit_en_o),.decim_en_o(decim_en_o));
endmodule

module tb_pdm_reference_compare;
  reg clk=0,rst=0,en=0;
  always #12.5 clk=~clk;
  tri [3:0] data;
  wire ref_clk,current_clk,ref_valid,current_valid;
  wire [127:0] ref_pcm,current_pcm;
  integer comparisons=0;
  pdm_array_rx reference(.clk_i(clk),.rst_n_i(rst),.en_i(en),.pdm_din_i(data),
    .pdm_clk_o(ref_clk),.audio_vec_o(ref_pcm),.sample_valid_o(ref_valid),.frame_cnt_o(),.frozen_o());
  rv32_pdm_array_rx #(.N_CH(8),.MICS_PER_LINE(2),.OUT_W(16),.ORDER(3),.DECIM(16),.ACC_W(24)) current_rx(
    .clk_i(clk),.rst_n_i(rst),.en_i(en),.pdm_din_i(data),.pdm_clk_o(current_clk),
    .audio_vec_o(current_pcm),.sample_valid_o(current_valid),.frame_cnt_o(),.frozen_o());
  genvar k;
  generate for(k=0;k<4;k=k+1) begin:line
    wire a,b;
    pulldown pd(data[k]);
    pdm_shared_mic_model #(.SEED(32'had2186f1+k*107)) ma(
      .clk(ref_clk),.rst(rst),.en(en),.lr(1'b0),.absent(1'b0),
      .dd(32'd40),.dv(32'd116),.hz(32'd30),.pattern(3'd0),.data(a),.source_bit());
    pdm_shared_mic_model #(.SEED(32'h59e713ab+k*311)) mb(
      .clk(ref_clk),.rst(rst),.en(en),.lr(1'b1),.absent(1'b0),
      .dd(32'd40),.dv(32'd116),.hz(32'd30),.pattern(3'd0),.data(b),.source_bit());
    assign data[k]=a;
    assign data[k]=b;
  end endgenerate
  always @(negedge clk) if(rst && en) begin
    if(ref_clk!==current_clk)$fatal(1,"CLOCK_CONFIGURATION_MISMATCH");
    if(current_valid) begin
      if(!ref_valid)$fatal(1,"VALID_PHASE_MISMATCH");
      if(ref_pcm!==current_pcm)$fatal(1,"PCM_MISMATCH ref=%h current=%h",ref_pcm,current_pcm);
      comparisons=comparisons+8;
    end
  end
  initial begin
    repeat(8)@(negedge clk);
    #1;rst=1;en=1;
    repeat(2200000)@(negedge clk);
    if(comparisons<1000)$fatal(1,"VACUOUS_COMPARISON");
    $display("REFERENCE_MATCHED_CLOCK_PASS channels=8 PCM16=1 pdm_hz=768000 comparisons=%0d production_clock_replaced_for_simulation=1",comparisons);
    $finish;
  end
endmodule
