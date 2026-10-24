`timescale 1ns/1ps
module tb_circular9_units;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,valid=0,wr=0;reg[6:0]addr=0;reg[31:0]data=0,id=0;
 reg[239:0]pcm=0;wire[31:0]rdata;wire[159:0]gain;
 rv32_pdm_capture #(.N_CH(10),.ACTIVE_MASK(10'h1ff),.FRAME_AW(4)) cap(
  .clk_i(clk),.rst_n_i(rst),.audio_vec_i(pcm),.valid_i(valid),.frame_cnt_i(id),.frozen_i(10'h200),
  .cfg_wr_i(wr),.cfg_rd_i(1'b1),.cfg_addr_i(addr),.cfg_wdata_i(data),.cfg_rdata_o(rdata),.gain_o(gain));
 wire[31:0]raw_drop,window_drop;
 rv32_overlap_localizer #(.CHANNELS(9),.CAPTURE_SLOTS(10),.CPU_SCHEDULED(1)) loc(
  .clk_i(clk),.rst_n_i(rst),.enable_i(rst),.rearm_i(1'b0),.valid_i(valid),.pcm_i(pcm),.sample_id_i(id),
  .raw_drop_o(raw_drop),.window_drop_o(window_drop),.fft_done_i(1'b0),.fft_result_i(32'b0),
  .srp_done_i(1'b0),.srp_busy_i(1'b0),.srp_score_i(32'b0),.fft_ready_i(1'b0),
  .ac_ready_i(1'b0),.ac_done_i(1'b0),.ac_result_i(32'b0),.statistics_index_i(6'b0));
 reg[4:0]din=5'b01001;reg[31:0]rng=32'h10729;
 wire[239:0]rx_masked,rx_full;wire rv,rv_full;wire[9:0]frozen;
 rv32_pdm_array_rx #(.N_CH(10),.ACTIVE_MASK(10'h1ff),.MIC_STARTUP_CYCLES(0),.CIC_SETTLE_FRAMES(0)) rx(
  .clk_i(clk),.rst_n_i(rst),.en_i(rst),.pdm_din_i(din),.audio_vec_o(rx_masked),.sample_valid_o(rv),.frozen_o(frozen));
 rv32_pdm_array_rx #(.N_CH(10),.MIC_STARTUP_CYCLES(0),.CIC_SETTLE_FRAMES(0)) reference_rx(
  .clk_i(clk),.rst_n_i(rst),.en_i(rst),.pdm_din_i(din),.audio_vec_o(rx_full),.sample_valid_o(rv_full));
 integer rx_count=0;
 always @(negedge clk)if(rst)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};din=rng[4:0];
  if(rv!==rv_full)$fatal(1,"masked receiver changed valid cadence");
  if(rv)begin
   if(rx_masked[215:0]!==rx_full[215:0]||rx_masked[239:216]!==0||frozen[9])$fatal(1,"PDM mask corrupted channel/empty slot");
   rx_count=rx_count+1;
  end
 end
 reg bwr=0,brd=0,bvalid=0;reg[4:0]ba=0;reg[31:0]bd=0;
 reg[215:0]bpcm=0;wire bv;wire[15:0]bs;reg bdone=0;
 rv32_das_stream #(.ACTIVE_CHANNELS(9)) beam(
  .clk_i(clk),.rst_n_i(rst),.pcm_i(bpcm),.valid_i(bvalid),.steer_comp_i(288'b0),.steer_locked_i(1'b0),.steer_busy_i(1'b0),
  .cfg_wr_i(bwr),.cfg_rd_i(brd),.cfg_addr_i(ba),.cfg_wdata_i(bd),.fir_valid_o(bv),.fir_sample_o(bs),
  .fir_ready_i(1'b1),.fir_done_i(bdone),.fir_result_i(bs),.link_enable_i(1'b0),.direction_fault_i(1'b0),
  .direction_valid_i(1'b0),.direction_comp_i(288'b0),.direction_version_i(32'b0),.direction_id_i(10'b0),.sample_seq_i(id));
 always @(posedge clk)bdone<=bv;
 task write_cap(input[6:0]a,input[31:0]d);
  @(negedge clk);addr=a;data=d;wr=1;@(negedge clk);wr=0;
 endtask
 integer n,ch,w,bank,signed_value,expected;
 reg[31:0]word_expected;
 initial begin
  repeat(4)@(negedge clk);rst=1;
  write_cap(20,32'hffff4000);
  if(gain[159:144]!==0||gain[143:128]!==16'h4000)$fatal(1,"empty slot acquired gain");
  write_cap(0,3);
  for(n=0;n<32;n=n+1)begin
   @(negedge clk);
   for(ch=0;ch<10;ch=ch+1)pcm[ch*24+:24]=(n*16+ch)<<8;
   pcm[239:216]=24'h7fff00;id=100+n;valid=1;
   @(negedge clk);valid=0;repeat(10)@(negedge clk);
  end
  if(cap.ready_q!==3||cap.dropped_q||raw_drop||window_drop)$fatal(1,"capture publication/drop");
  if($size(loc.raw_mem)!=10240||$size(loc.spectrum)!=1872||$size(loc.statistics)!=45)$fatal(1,"9/10 dimensions");
  for(n=0;n<32;n=n+1)for(w=0;w<5;w=w+1)begin
   word_expected=w==4 ? n*16+8 : ((n*16+2*w+1)<<16)|(n*16+2*w);
   if(cap.memory[n*5+w]!==word_expected||loc.raw_mem[n*5+w]!==word_expected)$fatal(1,"5-word packing at %0d/%0d",n,w);
  end
  // Verify the public synchronous read port, bank boundary and ACK ownership.
  for(bank=0;bank<2;bank=bank+1)begin
   write_cap(3,bank);
   for(w=0;w<80;w=w+1)begin
    write_cap(7,w);repeat(3)@(negedge clk);addr=8;#1;
    if(rdata!==cap.memory[bank*80+w])$fatal(1,"bank read mismatch");
   end
   write_cap(9,bank+99);write_cap(10,1);
   if(!cap.ready_q[bank])$fatal(1,"wrong owner released bank");
   write_cap(9,bank);write_cap(10,1);
   if(cap.ready_q[bank])$fatal(1,"owner ACK failed");
  end
  @(negedge clk);addr=12;#1;if(rdata!==0)$fatal(1,"empty slot freeze leaked");
  @(negedge clk);ba=0;bd=1;bwr=1;@(negedge clk);bwr=0;
  for(n=0;n<96;n=n+1)begin
   @(negedge clk);
   signed_value=n<24?900:n<48?-900:n<72?32767:-32768;
   bpcm=0;
   if(n<48)begin bpcm[192+:24]=signed_value*256;expected=signed_value/9;end
   else begin for(ch=0;ch<9;ch=ch+1)bpcm[ch*24+:24]=signed_value*256;expected=signed_value;end
   bvalid=1;@(negedge clk);bvalid=0;
   wait(bv);#1;
   if(n>2&&$signed(bs)!==expected)$fatal(1,"9-way average sample=%0d got=%0d wanted=%0d",n,$signed(bs),expected);
   repeat(4)@(negedge clk);ba=3;brd=1;@(negedge clk);brd=0;
   repeat(1024)@(negedge clk);
  end
  if(beam.drop_q||beam.error_q||rx_count<90)$fatal(1,"stream failed");
  $display("CIRCULAR9_UNITS_PASS rx=%0d bank_words=160 empty_slot=masked center_gain=1/9",rx_count);$finish;
 end
 initial begin #5000000;$fatal(1,"timeout");end
endmodule
