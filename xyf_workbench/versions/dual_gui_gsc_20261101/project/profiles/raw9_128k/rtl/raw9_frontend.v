// No spatial processing. Original common CIC ORDER=3/ACC24 reused unchanged.
// 10 capture slots, CH9 disabled; signed24 -> signed16 by fixed truncation.
// Same framing as existing transport, but direction fields remain zero.
module raw9_frontend(input clk_i,rst_n_i,en_i,input [4:0]pdm_din_i,
 output pdm_clk_o,output stream_valid_o,output [511:0]stream_data_o,
 output [63:0]stream_timestamp_o,output [8:0]frozen_o);
 wire [239:0]pcm;wire valid;wire[31:0]seq;wire[9:0]frozen;
 reg[63:0]cycles;reg[511:0]data_q;reg[63:0]time_q;reg valid_q;
 raw9_rx #(.N_CH(10),.ACTIVE_MASK(10'h1ff),.MICS_PER_LINE(2),
 .OUT_W(24),.ORDER(3),.DECIM(16),.ACC_W(24)) rx(
 .clk_i(clk_i),.rst_n_i(rst_n_i),.en_i(en_i),.pdm_din_i(pdm_din_i),
 .pdm_clk_o(pdm_clk_o),.audio_vec_o(pcm),.sample_valid_o(valid),
 .frame_cnt_o(seq),.frozen_o(frozen));
 integer k;
 always @(posedge clk_i or negedge rst_n_i)begin
 if(!rst_n_i)begin cycles<=0;data_q<=0;time_q<=0;valid_q<=0;end
 else begin
 cycles<=cycles+1'b1;valid_q<=valid;
 if(valid)begin
 data_q<=0;data_q[31:0]<=32'h47534302;data_q[63:32]<=seq;
 for(k=0;k<9;k=k+1)data_q[256+16*k+:16]<=pcm[24*k+8+:16];
 data_q[447:416]<=32'h000a0009;time_q<=cycles;
 end end end
 assign stream_valid_o=valid_q;assign stream_data_o=data_q;
 assign stream_timestamp_o=time_q;assign frozen_o=frozen[8:0];
endmodule
