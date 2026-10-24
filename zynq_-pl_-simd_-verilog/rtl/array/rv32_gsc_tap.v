// Future PS-GSC boundary. Complete synchronous PCM is retained, with a bounded
// independent packet queue. Sink backpressure never reaches PCM or localization.
module rv32_gsc_tap # (parameter DEPTH=4, parameter ACTIVE_CHANNELS=12)(
 input clk_i,rst_n_i,raw_valid_i,input[191:0]raw_pcm_i,input[31:0]raw_seq_i,
 input beam_valid_i,input[31:0]beam_seq_i,input[15:0]beam_i,fir_i,
 input[31:0]direction_version_i,effective_seq_i,window_id_i,group_delay_q16_i,recovery_epoch_i,
 input[9:0]direction_id_i,input trusted_i,transition_i,
 output valid_o,input ready_i,output[511:0]data_o,
 output[63:0]timestamp_o,
 output reg[31:0]overflow_o,alignment_errors_o
);
 localparam AW=$clog2(DEPTH);
 reg[511:0]mem[0:DEPTH-1];reg[AW-1:0]wp,rp;reg[AW:0]count;
 reg[63:0]time_mem[0:DEPTH-1];reg[63:0]cycle_q,raw_time_q;
 reg[191:0]raw_hold;reg[31:0]raw_seq;reg pending;
 wire pop=valid_o&&ready_i;
 wire aligned=beam_valid_i&&pending&&beam_seq_i==raw_seq;
 wire push=aligned&&(count<DEPTH||pop);
 assign valid_o=count!=0;assign data_o=mem[rp];
 assign timestamp_o=time_mem[rp];
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin cycle_q<=0;raw_time_q<=0;end
  else begin cycle_q<=cycle_q+1'b1;if(raw_valid_i)raw_time_q<=cycle_q;end
 end
 always @(posedge clk_i)begin
  if(push)time_mem[wp]<=raw_time_q;
  if(push)mem[wp]<={overflow_o,recovery_epoch_i,
   (ACTIVE_CHANNELS==9?{32'h000a0009,16'b0,raw_hold[143:0]}:raw_hold),{fir_i,beam_i},
   {14'b0,direction_id_i,6'b0,transition_i,trusted_i},group_delay_q16_i,
   window_id_i,effective_seq_i,direction_version_i,beam_seq_i,
   (ACTIVE_CHANNELS==9?32'h47534302:32'h47534301)};
 end
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin wp<=0;rp<=0;count<=0;raw_hold<=0;raw_seq<=0;pending<=0;overflow_o<=0;alignment_errors_o<=0;end
  else begin
   if(raw_valid_i)begin
    raw_hold<=raw_pcm_i;raw_seq<=raw_seq_i;pending<=1;
    if(pending&&!beam_valid_i)alignment_errors_o<=alignment_errors_o+1;
   end else if(beam_valid_i)pending<=0;
   if(beam_valid_i&&!aligned)alignment_errors_o<=alignment_errors_o+1;
   if(aligned&&!push)overflow_o<=overflow_o+1;
   if(push)wp<=wp+1'b1;if(pop)rp<=rp+1'b1;
   case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
  end
 end
endmodule
