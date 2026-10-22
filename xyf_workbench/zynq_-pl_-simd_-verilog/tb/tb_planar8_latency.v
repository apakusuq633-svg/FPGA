`timescale 1ns/1ps
module tb_planar8_latency;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,valid=0,cw=0,wr=0,rd=0,drain=0;
 reg [191:0] pcm=0;
 reg [31:0] sample_id=0,data=0;
 reg [6:0] addr=0;
 reg [8:0] ci=0;reg [15:0] cd=0;
 wire [3:0] fault;
 reg [31:0] host=0;
 rv32_soc dut(.clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),
  .fromhost_i(host),.retire_fault_o(fault),.ps_req_i(1'b0),.ps_write_i(1'b0),
  .ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),.tacho_i(1'b0),.pdm_din_i(4'b0),
  .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
  .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd),.pdm_cfg_addr_i(addr),.pdm_cfg_wdata_i(data),
  .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
  .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
  .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
 // Independent front end runs with production startup/settling parameters.
 wire rx_valid;
 rv32_pdm_array_rx rx(.clk_i(clk),.rst_n_i(rst),.en_i(rst),.pdm_din_i(4'b0101),.sample_valid_o(rx_valid));
 reg [15:0] input_pcm[0:32767];
 string fw,pcm_file,dump;
 integer i,n,ch,k,frames=0,previous_frame=0,phase=0,previous_phase=0;
 longint tick=0,first_input=0,last_input=0,last_result=0,phase_begin=0;
 longint audio_begin=0,audio_emit=0,fft_begin=0,srp_begin=0,rx_first=0;
 integer audio_count=0,overlap=0,production=0,windows=3;
 integer test_case=0;reg raw_done=0;
 integer forward_runs=0,inverse_runs=0,cross_runs=0,phat_runs=0,srp_runs=0;
 reg geo_start=0;wire geo_done;
 longint geo_begin=0;
 longint overlap_previous=0;
 longint transfer_cycles[0:28];
 rv32_steer #(.N_GRID(1024),.N_MIC(8)) geo(.clk_i(clk),.rst_n_i(rst),.en_i(1'b1),
  .start_i(geo_start),.target_i(10'd800),.done_o(geo_done),.lut_we_i(1'b0),
  .lut_addr_i(15'b0),.lut_data_i(14'b0),.comp_idx_i(4'b0));
 always @(negedge clk)if(drain)begin addr=35;rd=dut.u_beam.count!=0;end
 initial begin
  wait(rst);repeat(10)@(negedge clk);geo_start=1;
  @(negedge clk);geo_start=0;
 end
 always @(negedge clk)if(production && test_case==3 && dut.loc_done)begin
  for(integer g=0;g<1024;g=g+1)dut.u_srp.u_scan.p_mem[g]=g==800?100000:0;
 end
 initial begin
  wait(production && test_case==4 && frames==1);
  @(negedge clk);host=32'hc1000001;
  wait(dut.u_dtcm.memory['ha69]==1);
  if(dut.u_dtcm.memory['ha6c]!=8 || dut.u_dtcm.memory['ha6d]!=1024)$fatal(1,"raw capture metadata mismatch");
  @(negedge clk);host=32'hc2000001;
  wait(dut.u_dtcm.memory['ha69]==2);
  @(negedge clk);host=0;raw_done=1;$display("RAW_RESUME_RELEASED");
 end
 task cfg(input [6:0] a,input [31:0] v);
  @(negedge clk);addr=a;data=v;wr=1;@(negedge clk);wr=0;
 endtask
 initial begin
  if(!$value$plusargs("FW=%s",fw))$fatal(1,"missing FW");
  overlap=$test$plusargs("OVERLAP");
  production=$test$plusargs("PRODUCTION");
  if(!$value$plusargs("WINDOWS=%d",windows))windows=3;
  if(!$value$plusargs("CASE=%d",test_case))test_case=0;
  if(!$value$plusargs("DUMP=%s",dump))dump="";
  if(!$value$plusargs("PCM=%s",pcm_file))pcm_file="build/planar8_latency/pcm.hex";
  #1;
  $readmemh({fw,"/itcm.hex"},dut.u_itcm.memory);
  $readmemh({fw,"/dtcm.hex"},dut.u_dtcm.memory);
  $readmemh("build/das8/srp_lut.hex",dut.u_srp.u_scan.lut_mem);
  $readmemh("build/das8/steer_lut.hex",dut.u_steer.u_geo.lut_mem);
  $readmemh("build/das8/steer_lut.hex",geo.lut_mem);
  $readmemh(pcm_file,input_pcm);
  force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=sample_id;
  repeat(4)@(negedge clk);rst=1;
  for(k=0;k<32;k=k+1)begin @(negedge clk);cw=1;ci=k;cd=k==0?32767:0;end
  @(negedge clk);cw=0;cfg(32,5);
  wait(dut.u_pdm_cap.capture_q || dut.localizer_enable);
  drain=1;
  for(n=0;n<50000;n=n+1)begin
   @(negedge clk);
   for(ch=0;ch<8;ch=ch+1)pcm[ch*24+:24]={input_pcm[(n%4096)*8+ch],8'b0};
   if(test_case==1)pcm=0;
   if(test_case==2)for(ch=0;ch<8;ch=ch+1)pcm[ch*24+:24]=24'h7fff00;
   sample_id=n;valid=1;
   @(negedge clk);valid=0;
   repeat(1022)@(negedge clk);
  end
  $fatal(1,"window timeout");
 end
 always @(posedge clk)begin
  tick=tick+1;
  if(rst)begin
   if(valid)begin
    if(audio_count==0)first_input=tick;
    last_input=tick;audio_begin=tick;
   end
   if(dut.beam_fir_valid)begin audio_emit=tick;end
   if(dut.u_beam.push)begin
    audio_count=audio_count+1;
    if(audio_count<5)$display("AUDIO sample=%0d input_to_emit=%0d input_to_fifo=%0d fir_service=%0d",audio_count,audio_emit-audio_begin,tick-audio_begin,tick-audio_emit);
   end
   if(rx_valid && rx_first==0)begin rx_first=tick;$display("RX_FIRST cycle=%0d since_reset=%0d",tick,tick-4);end
   if(geo_start)geo_begin=tick;
   if(geo_done && geo_begin!=0)begin $display("STEER_GEOMETRY cycles=%0d",tick-geo_begin);geo_begin=0;end
   if(overlap && dut.localizer_enable)transfer_cycles[dut.g_localizer.u_transfer.state]=transfer_cycles[dut.g_localizer.u_transfer.state]+1;
   if(overlap && dut.loc_done)begin
    $display("OVERLAP_RESULT tick=%0d first_input=%0d first_sample=%0d interval=%0d compute=%0d latency=%0d",tick,first_input,dut.loc_first,overlap_previous?tick-overlap_previous:0,dut.loc_compute_cycles,dut.loc_latency);
    for(i=0;i<29;i=i+1)begin $display("TRANSFER_PHASE state=%0d cycles=%0d",i,transfer_cycles[i]);transfer_cycles[i]=0;end
    overlap_previous=tick;
   end
   if(dut.retire_valid_o && dut.retire_instr_o[6:0]==7'h0b)begin
    if(dut.retire_instr_o[14:12]==7 && dut.retire_instr_o[31:25]==7'h50)forward_runs=forward_runs+1;
    if(dut.retire_instr_o[14:12]==7 && dut.retire_instr_o[31:25]==7'h70)inverse_runs=inverse_runs+1;
    if(dut.retire_instr_o[14:12]==6)cross_runs=cross_runs+1;
    if(dut.retire_instr_o[14:12]==5)phat_runs=phat_runs+1;
   end
   if(dut.retire_valid_o && dut.retire_instr_o[6:0]==7'h2b && dut.retire_instr_o[14:12]==0)srp_runs=srp_runs+1;
   if(dut.u_core.u_fft_bfly.run_start)fft_begin=tick;
   if(dut.u_core.u_fft_bfly.done_o && fft_begin!=0)begin
    $display("FFT_ENGINE inverse=%0d cycles=%0d",dut.u_core.u_fft_bfly.inv_q,tick-fft_begin);fft_begin=0;
   end
   if(dut.u_srp.u_scan.busy_o && srp_begin==0)srp_begin=tick;
   if(!dut.u_srp.u_scan.busy_o && srp_begin!=0)begin $display("SRP_ENGINE cycles=%0d",tick-srp_begin);srp_begin=0;end
   phase=dut.u_dtcm.memory['hafc];
   if(phase!=previous_phase)begin
    if(previous_phase!=0)$display("PHASE id=%0d begin=%0d end=%0d cycles=%0d",previous_phase,phase_begin,tick,tick-phase_begin);
    previous_phase=phase;phase_begin=tick;
   end
   if(dut.u_dtcm.memory['ha01]!=previous_frame)begin
    previous_frame=dut.u_dtcm.memory['ha01];frames=frames+1;
    if(overlap)$display("OVERLAP_FRAME index=%0d tick=%0d interval=%0d compute=%0d latency=%0d first_sample=%0d raw_drop=%0d window_drop=%0d audio_drop=%0d",frames,tick,last_result?tick-last_result:0,dut.loc_compute_cycles,dut.loc_latency,dut.loc_first,dut.loc_raw_drop,dut.loc_window_drop,dut.u_beam.drop_q);
    else $display("FRAME index=%0d tick=%0d first_input=%0d interval=%0d compute=%0d total=%0d first_sample=%0d reason=%0d capture_drop=%0d audio_drop=%0d audio_max=%0d",frames,tick,first_input,last_result?tick-last_result:0,dut.u_dtcm.memory['ha04],dut.u_dtcm.memory['ha05],dut.u_dtcm.memory['ha5d],dut.u_dtcm.memory['ha61],dut.u_pdm_cap.dropped_q,dut.u_beam.drop_q,dut.u_beam.max_ticks);
    last_result=tick;
    if(dump!="" && frames<=3)begin
     $writememh($sformatf("%s/scores_%0d.hex",dump,frames),dut.u_srp.u_scan.p_mem);
     $writememh($sformatf("%s/statistics_%0d.hex",dump,frames),dut.g_localizer.u_transfer.statistics);
    end
    if(production)begin
     for(i=0;i<1024;i=i+1)
      if(dut.g_live16_scratch.u_ram.memory['h2800+i]!==dut.u_srp.u_scan.p_mem[i])$fatal(1,"score readback mismatch grid=%0d got=%h expected=%h",i,dut.g_live16_scratch.u_ram.memory['h2800+i],dut.u_srp.u_scan.p_mem[i]);
     for(i=0;i<40;i=i+1)
      if(dut.u_dtcm.memory['ha08+i]!==dut.g_localizer.u_transfer.statistics[i])$fatal(1,"statistics readback mismatch word=%0d",i);
     if(dut.u_dtcm.memory['ha5b] && dut.u_dtcm.memory['ha61])$fatal(1,"rejected direction was accepted");
     if(dut.loc_raw_drop || dut.loc_window_drop)$fatal(1,"continuous window loss");
     if(test_case!=4 && dut.u_dtcm.memory['ha5d]!=(frames-1)*512)$fatal(1,"512-hop sequence mismatch");
     if((test_case==1 || test_case==2) && (dut.u_dtcm.memory['ha5b] || dut.beam_locked))$fatal(1,"invalid input steered audio");
     if(test_case==1 && !(dut.u_dtcm.memory['ha61]&1))$fatal(1,"silence not rejected");
     if(test_case==2 && !(dut.u_dtcm.memory['ha61]&2))$fatal(1,"clipping not rejected");
     if(test_case==3 && frames>=2 && (dut.u_dtcm.memory['ha61]!=0 || dut.u_dtcm.memory['ha02]!=800))$fatal(1,"valid score map rejected");
     $display("PRODUCTION_POST compute=%0d post=%0d custom_fft=%0d custom_ifft=%0d custom_cross=%0d custom_phat=%0d custom_srp=%0d",dut.u_dtcm.memory['hae8],dut.u_dtcm.memory['hae9],forward_runs,inverse_runs,cross_runs,phat_runs,srp_runs);
    end
    if(dut.u_dtcm.memory['ha81]==32'h43595031)begin
     for(i=0;i<8;i=i+1)$display("CHANNEL ch=%0d capture=%0d prepare=%0d push=%0d run=%0d pop=%0d",i,dut.u_dtcm.memory['ha86+i*5],dut.u_dtcm.memory['ha87+i*5],dut.u_dtcm.memory['ha88+i*5],dut.u_dtcm.memory['ha89+i*5],dut.u_dtcm.memory['ha8a+i*5]);
    end
    if(frames==windows)begin
     if(dut.u_beam.error_q || dut.u_beam.drop_q)$fatal(1,"audio service failure");
     if(production && test_case==3 && !dut.beam_locked)$fatal(1,"valid direction never locked");
     if(production && test_case==4 && !raw_done)$fatal(1,"raw capture did not resume");
     if(production && (forward_runs!=8*windows || inverse_runs!=28*windows || cross_runs!=28*windows || phat_runs!=28*windows || srp_runs!=windows))$fatal(1,"custom instruction counts mismatch");
     $display("PLANAR8_LATENCY_PASS frames=%0d audio_samples=%0d",frames,audio_count);$finish;
    end
   end
   if((dut.retire_valid_o && fault) || dut.u_dtcm.memory['ha03])$fatal(1,"core/firmware fault=%0d error=%0d pc=%h",fault,dut.u_dtcm.memory['ha03],dut.u_core.idex_pc);
  end
 end
 initial begin #1500000000;$fatal(1,"simulation timeout");end
endmodule
