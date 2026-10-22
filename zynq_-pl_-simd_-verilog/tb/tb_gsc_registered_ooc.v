// Synthesis context only: same-clock registered source and registered sink.
// Not a behavioral acceptance bench, and not a PS/DMA implementation.
module tb_gsc_registered_ooc(input clk_i,rst_n_i,output reg[31:0]checksum_o);
 reg[511:0]source_q;reg[41:0]tick;
 wire[511:0]packet;wire valid;wire[31:0]overflow,errors;
 wire[31:0]seq=tick[41:10];
 rv32_gsc_tap u_tap(.clk_i(clk_i),.rst_n_i(rst_n_i),.raw_valid_i(tick[9:0]==0),
  .raw_pcm_i(source_q[191:0]),.raw_seq_i(seq),.beam_valid_i(tick[9:0]==197),.beam_seq_i(seq),
  .beam_i(source_q[207:192]),.fir_i(source_q[223:208]),.direction_version_i(source_q[255:224]),
  .effective_seq_i(source_q[287:256]),.window_id_i(source_q[319:288]),.group_delay_q16_i(source_q[351:320]),
  .recovery_epoch_i(source_q[383:352]),.direction_id_i(source_q[393:384]),.trusted_i(source_q[394]),.transition_i(source_q[395]),
  .valid_o(valid),.ready_i(source_q[511]),.data_o(packet),.overflow_o(overflow),.alignment_errors_o(errors));
 integer k;reg[31:0]mix;
 always @*begin mix=0;for(k=0;k<16;k=k+1)mix=mix^packet[k*32+:32];end
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin tick<=0;source_q<=512'h123456789abcdef;checksum_o<=0;end
  else begin
   tick<=tick+1'b1;source_q<={source_q[510:0],source_q[511]^source_q[509]^source_q[506]^source_q[503]};
   if(valid&&source_q[511])checksum_o<={checksum_o[30:0],checksum_o[31]}^mix^overflow^errors;
  end
 end
endmodule
