`timescale 1ns/1ps
// Real DAS + real eight-lane SIMD FIR + real tap; no arithmetic stubs.
module tb_gsc12_frontend;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,valid=0,wr=0,rd=0,cw=0,dv=0;
 reg[4:0]addr=0;reg[31:0]wd=0,seq=0;reg[8:0]ci=0;reg[15:0]cd=0;
 reg[287:0]pcm=0;reg[383:0]delays=0;
 wire[31:0]regdata,version,effective,aseq,group_delay;
 wire[9:0]direction;wire ready,applied,transition,trusted,av,ar,ad;
 wire[15:0]das,fir;
 rv32_core #(.AUDIO_STREAM(1)) core(.clk_i(clk),.rst_n_i(rst),.halt_i(1'b1),.test_en_i(1'b0),
  .imem_ready_i(1'b0),.imem_rdata_i(32'h00000013),.dmem_ready_i(1'b1),.dmem_rdata_i(32'b0),
  .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
  .audio_valid_i(av),.audio_sample_i(das),.audio_ready_o(ar),.audio_done_o(ad),.audio_result_o(fir));
 rv32_das_stream #(.ACTIVE_CHANNELS(12)) beam(.clk_i(clk),.rst_n_i(rst),.pcm_i(pcm),.valid_i(valid),
  .steer_comp_i(384'b0),.steer_locked_i(1'b0),.steer_busy_i(1'b0),
  .cfg_wr_i(wr),.cfg_rd_i(rd),.cfg_addr_i(addr),.cfg_wdata_i(wd),.cfg_rdata_o(regdata),
  .fir_valid_o(av),.fir_sample_o(das),.fir_ready_i(ar),.fir_done_i(ad),.fir_result_i(fir),
  .link_enable_i(1'b1),.direction_fault_i(1'b0),.direction_valid_i(dv),.direction_comp_i(delays),
  .direction_version_i(32'd1),.direction_id_i(10'd7),.sample_seq_i(seq),.direction_ready_o(ready),
  .direction_applied_o(applied),.direction_version_o(version),.direction_id_o(direction),
  .effective_sample_seq_o(effective),.audio_sample_seq_o(aseq),.group_delay_q16_o(group_delay),
  .transitioning_o(transition),.direction_trusted_o(trusted));
 wire pv;wire[511:0]packet;wire[31:0]overflow,errors;
 wire[191:0]raw;
 genvar g;generate for(g=0;g<12;g=g+1)begin assign raw[g*16+:16]=pcm[g*24+8+:16];end endgenerate
 rv32_gsc_tap tap(.clk_i(clk),.rst_n_i(rst),.raw_valid_i(valid),.raw_pcm_i(raw),.raw_seq_i(seq),
  .beam_valid_i(ad),.beam_seq_i(aseq),.beam_i(das),.fir_i(fir),
  .direction_version_i(version),.effective_seq_i(effective),.window_id_i(32'd1),.group_delay_q16_i(group_delay),
  .recovery_epoch_i(32'd0),.direction_id_i(direction),.trusted_i(trusted),.transition_i(transition),
  .valid_o(pv),.ready_i(1'b1),.data_o(packet),.overflow_o(overflow),.alignment_errors_o(errors));
 reg[15:0]source[0:3071];reg[15:0]coeff[0:31];reg[31:0]delay_words[0:11];
 integer n,ch,k,fd,packets=0,cycles=0,accepted=0,latency=0,max_latency=0;
 always @(posedge clk)begin
  cycles<=cycles+1;
  if(valid)accepted<=cycles;
  if(ad)begin latency=cycles-accepted;if(latency>max_latency)max_latency=latency;
   if(latency>=1024)$fatal(1,"AUDIO_DEADLINE");end
  if(pv)begin $fdisplay(fd,"%0128h",packet);packets=packets+1;end
 end
 initial begin
  fd=$fopen("OUTPUT_FILE","w");if(!fd)$fatal(1,"OUTPUT_OPEN");
  $readmemh("VECTOR_DIR/pcm.hex",source);$readmemh("VECTOR_DIR/fir.hex",coeff);$readmemh("VECTOR_DIR/delay.hex",delay_words);
  repeat(8)@(negedge clk);rst=1;
  for(k=0;k<32;k=k+1)begin @(negedge clk);ci=k;cd=coeff[k];cw=1;end
  @(negedge clk);cw=0;addr=0;wd=9;wr=1;@(negedge clk);wr=0;
  for(ch=0;ch<12;ch=ch+1)delays[ch*32+:32]=delay_words[ch];
  wait(ready);@(negedge clk);dv=1;@(negedge clk);dv=0;repeat(4)@(negedge clk);
  for(n=0;n<256;n=n+1)begin
   seq=n;for(ch=0;ch<12;ch=ch+1)pcm[ch*24+:24]=$signed(source[n*12+ch])*256;
   valid=1;@(negedge clk);valid=0;repeat(900)@(negedge clk);
   addr=3;rd=1;@(negedge clk);rd=0;repeat(122)@(negedge clk);
  end
  repeat(4)@(negedge clk);$fclose(fd);
  if(packets!=256||overflow||errors)$fatal(1,"PACKET_LOSS count=%0d overflow=%0d errors=%0d",packets,overflow,errors);
  addr=4;#1;if(regdata!=0)$fatal(1,"DAS_LOSS");
  $display("GSC12_FRONTEND_RTL_PASS packets=%0d audio_max_cycles=%0d",packets,max_latency);$finish;
 end
 initial begin #30000000;$fatal(1,"TIMEOUT");end
endmodule
