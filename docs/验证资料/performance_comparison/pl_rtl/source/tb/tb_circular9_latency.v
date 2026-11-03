`timescale 1ns/1ps
module tb_circular9_latency;
 localparam PCM_TICKS=256,HOP=512;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,valid=0,cw=0,wr=0,rd=0,drain=0;
 reg [239:0] pcm=0;
 reg [31:0] sample_id=0,data=0;
 reg [6:0] addr=0;
 reg [8:0] ci=0;reg [15:0] cd=0;
 wire [3:0] fault;
 reg [31:0] host=0;
 reg [4:0] pdm_data=0;wire pdm_clock;
 reg [8:0] pdm_vectors[0:65535];integer pdm_index=0,pdm_mode=0;
 wire [31:0] cfg_rdata;
 string pdm_file;
 always @(negedge pdm_clock)if(pdm_mode)begin
  pdm_index=(pdm_index+1)%65536;
  for(integer line=0;line<5;line++)pdm_data[line]=pdm_vectors[pdm_index][2*line];
 end
 always @(posedge pdm_clock)if(pdm_mode)begin
  for(integer line=0;line<4;line++)pdm_data[line]=pdm_vectors[pdm_index][2*line+1];
  pdm_data[4]=1; // deliberately dirty unused phase; physical slot9 stays zero.
 end
 rv32_soc #(.DAS_ACTIVE_CHANNELS(9)) dut(.clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),
  .fromhost_i(host),.retire_fault_o(fault),.gsc_ready_i(1'b1),.ps_req_i(1'b0),.ps_write_i(1'b0),
  .ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),.tacho_i(1'b0),.pdm_din_i(pdm_data),.pdm_clk_o(pdm_clock),
  .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
  .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd),.pdm_cfg_addr_i(addr),.pdm_cfg_wdata_i(data),
  .pdm_cfg_rdata_o(cfg_rdata),
  .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
  .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
  .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
 // Independent front end runs with production startup/settling parameters.
 wire rx_valid;
 rv32_pdm_array_rx #(.DECIM(16)) rx(.clk_i(clk),.rst_n_i(rst),.en_i(rst),.pdm_din_i(4'b0101),.sample_valid_o(rx_valid));
 reg [15:0] input_pcm[0:36863];
 string fw,pcm_file,dump,gsc_dump;
 string fine_delay_file;
 reg [31:0] fine_delay[0:17];
 integer fine_mode=0,fine_committed=0,fine_packets=0,fine_second=0,fine_packets2=0;
 integer fine_restore_requested=0,fine_restored_packets=0;
 reg [31:0] fine_expected_group=0,fine_expected_group2=0;
 integer confirmed=0,gsc_fd=0,gsc_packets=0;
 integer i,n,ch,k,frames=0,previous_frame=0,phase=0,previous_phase=0;
 longint tick=0,first_input=0,last_input=0,last_result=0,phase_begin=0;
 longint first_input_id=0;
 longint audio_begin=0,audio_emit=0,fft_begin=0,srp_begin=0,rx_first=0;
 integer audio_count=0,overlap=0,production=0,windows=3;
 integer test_case=0;reg raw_done=0;reg manual_selected=0;
 integer forward_runs=0,inverse_runs=0,cross_runs=0,phat_runs=0,srp_runs=0;
 reg geo_start=0;wire geo_done;
 longint geo_begin=0;
 longint overlap_previous=0;
 longint transfer_cycles[0:31];
 rv32_steer #(.N_GRID(1024),.N_MIC(9)) geo(.clk_i(clk),.rst_n_i(rst),.en_i(1'b1),
  .start_i(geo_start),.target_i(10'd800),.done_o(geo_done),.lut_we_i(1'b0),
  .lut_addr_i(15'b0),.lut_data_i(14'b0),.comp_idx_i(4'b0));
 always @(negedge clk)if(drain)begin addr=35;rd=dut.u_beam.count!=0;end
 initial begin
  wait(rst);repeat(10)@(negedge clk);geo_start=1;
  @(negedge clk);geo_start=0;
 end
 always @(negedge clk)if(production && (test_case==3 || test_case==5) && dut.loc_done)begin
  for(integer g=0;g<1024;g=g+1)dut.u_srp.u_scan.p_mem[g]=g==800?100000:0;
 end
 initial begin
  wait(production && test_case==5);
  @(negedge clk);host=32'hd3000001;
  wait(frames==3);@(negedge clk);host=32'hd1000320;
  wait(frames==6);@(negedge clk);host=32'hd3000002;
 end
 initial begin
  wait(production && test_case==4 && frames==1);
  @(negedge clk);host=32'hc1000001;
  wait(dut.u_dtcm.memory['ha69]==1);
  if(dut.u_dtcm.memory['ha6c]!=10 || dut.u_dtcm.memory['ha6d]!=1024)$fatal(1,"raw capture metadata mismatch");
  @(negedge clk);host=32'hc2000001;
  wait(dut.u_dtcm.memory['ha69]==2);
  @(negedge clk);host=0;raw_done=1;$display("RAW_RESUME_RELEASED");
 end
 task cfg(input [6:0] a,input [31:0] v);
  @(negedge clk);addr=a;data=v;wr=1;@(negedge clk);wr=0;
 endtask
 task fine_indexed(input [31:0] index,input [31:0] value);
  cfg(61,index);cfg(62,value);
 endtask
 task fine_expect(input [31:0] index,input [31:0] value);
  cfg(61,index);@(negedge clk);addr=62;rd=1;
  #1;if(cfg_rdata!==value)$fatal(1,"fine readback index=%0d got=%h expected=%h",index,cfg_rdata,value);
  @(negedge clk);rd=0;
 endtask
 initial begin
  wait(fine_mode&&production&&confirmed&&test_case==3&&frames==3);
  // Pause only the shared cfg-port drain, then perform the actual PS indexed
  // shadow protocol. Raw capture, custom instructions and audio keep running.
  @(negedge clk);drain=0;rd=0;
  cfg(60,32'h42454731);
  fine_indexed(1,800);fine_indexed(2,1);
  fine_indexed(3,dut.recovery_epoch);fine_indexed(4,dut.acquisition_clock);
  for(integer fc=0;fc<9;fc=fc+1)fine_indexed(8+fc,fine_delay[fc]);
  cfg(60,32'h434f4d31);
  fine_expect(20,800);fine_expect(21,32'h80000001);
  fine_expect(22,dut.recovery_epoch);fine_expect(25,3);
  for(integer fc=0;fc<9;fc=fc+1)fine_expect(32+fc,fine_delay[fc]);
  host=32'hd1000320;fine_committed=1;drain=1;
  $display("FINE_SHADOW_COMMITTED version=2147483649 grid=800 epoch=%0d group_delay=%0d",dut.recovery_epoch,fine_expected_group);
  wait(frames==8);@(negedge clk);drain=0;rd=0;
  cfg(60,32'h42454731);
  fine_indexed(1,800);fine_indexed(2,2);
  fine_indexed(3,dut.recovery_epoch);fine_indexed(4,dut.acquisition_clock);
  for(integer fc=0;fc<9;fc=fc+1)fine_indexed(8+fc,fine_delay[9+fc]);
  cfg(60,32'h434f4d31);
  fine_expect(21,32'h80000002);fine_expect(25,3);
  for(integer fc=0;fc<9;fc=fc+1)fine_expect(32+fc,fine_delay[9+fc]);
  fine_second=1;drain=1;
  $display("FINE_SECOND_COMMITTED version=2147483650 grid=800");
  wait(frames==14);@(negedge clk);drain=0;rd=0;
  cfg(60,32'h4f464631);fine_expect(25,0);
  host=32'hd1000320;fine_restore_requested=1;drain=1;
  $display("FINE_OFF_RESTORE_COARSE requested_grid=800");
 end
 initial begin
  if(!$value$plusargs("FW=%s",fw))$fatal(1,"missing FW");
  overlap=$test$plusargs("OVERLAP");
  production=$test$plusargs("PRODUCTION");
  confirmed=$test$plusargs("CONFIRMED_TEST_ONLY");
  fine_mode=$test$plusargs("FINE_TEST");
  if(fine_mode)begin
   if(!$value$plusargs("FINE_DELAYS=%s",fine_delay_file))$fatal(1,"missing fine delays");
   $readmemh(fine_delay_file,fine_delay);
   for(integer fc=0;fc<9;fc=fc+1)if(fine_delay[fc]>fine_expected_group)fine_expected_group=fine_delay[fc];
   for(integer fc=9;fc<18;fc=fc+1)if(fine_delay[fc]>fine_expected_group2)fine_expected_group2=fine_delay[fc];
   fine_expected_group=fine_expected_group+65536;
   fine_expected_group2=fine_expected_group2+65536;
  end
  pdm_mode=$value$plusargs("PDM=%s",pdm_file);
  if(pdm_mode)$readmemh(pdm_file,pdm_vectors);
  if($value$plusargs("GSC_DUMP=%s",gsc_dump))begin gsc_fd=$fopen(gsc_dump,"w");if(!gsc_fd)$fatal(1,"GSC output open");end
  if(!$value$plusargs("WINDOWS=%d",windows))windows=3;
  if(!$value$plusargs("CASE=%d",test_case))test_case=0;
  if(!$value$plusargs("DUMP=%s",dump))dump="";
  if(!$value$plusargs("PCM=%s",pcm_file))pcm_file="build/circular9_latency/pcm.hex";
  #1;
  $readmemh({fw,"/itcm.hex"},dut.u_itcm.memory);
  $readmemh({fw,"/dtcm.hex"},dut.u_dtcm.memory);
  $readmemh("build/circular9/srp_lut.hex",dut.u_srp.u_scan.lut_mem);
  for(integer group=0;group<9;group++)for(integer gcell=0;gcell<1024;gcell++)begin
   dut.u_srp.u_scan.g_parallel4.g_lane[0].lut_bank[group*1024+gcell]=dut.u_srp.u_scan.lut_mem[(group*4+0)*1024+gcell];
   dut.u_srp.u_scan.g_parallel4.g_lane[1].lut_bank[group*1024+gcell]=dut.u_srp.u_scan.lut_mem[(group*4+1)*1024+gcell];
   dut.u_srp.u_scan.g_parallel4.g_lane[2].lut_bank[group*1024+gcell]=dut.u_srp.u_scan.lut_mem[(group*4+2)*1024+gcell];
   dut.u_srp.u_scan.g_parallel4.g_lane[3].lut_bank[group*1024+gcell]=dut.u_srp.u_scan.lut_mem[(group*4+3)*1024+gcell];
  end
  $readmemh("build/circular9/steer_lut.hex",dut.u_steer.u_geo.lut_mem);
  $readmemh("build/circular9/steer_lut.hex",geo.lut_mem);
  $readmemh(pcm_file,input_pcm);
  if(!pdm_mode)begin
   force dut.pdm_aligned_unmasked=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=sample_id;
  end
  repeat(4)@(negedge clk);rst=1;
  for(k=0;k<32;k=k+1)begin @(negedge clk);cw=1;ci=k;cd=k==0?32767:0;end
  @(negedge clk);cw=0;cfg(32,confirmed?29:5);
  wait(dut.u_pdm_cap.capture_q || dut.localizer_enable);
  drain=1;
  for(n=0;n<50000;n=n+1)begin
   @(negedge clk);
   for(ch=0;ch<9;ch=ch+1)pcm[ch*24+:24]={input_pcm[(n%4096)*9+ch],8'b0};
   if(test_case==1)pcm=0;
   if(test_case==2)for(ch=0;ch<9;ch=ch+1)pcm[ch*24+:24]=24'h7fff00;
   pcm[239:216]=24'h7fff00;sample_id=n;valid=1;
   @(negedge clk);valid=0;
   repeat(PCM_TICKS-2)@(negedge clk);
  end
  $fatal(1,"window timeout");
 end
 always @(posedge clk)begin
  tick=tick+1;
  if(rst)begin
   if(gsc_fd&&dut.gsc_valid_o)begin
    $fdisplay(gsc_fd,"%0128h",dut.gsc_data_o);gsc_packets=gsc_packets+1;
    if(fine_mode&&dut.gsc_data_o[95:64]==32'h80000001&&dut.gsc_data_o[193:192]==2'b01)begin
     fine_packets=fine_packets+1;
     if(dut.gsc_data_o[191:160]!==fine_expected_group||dut.gsc_data_o[209:200]!==10'd800)
      $fatal(1,"fine version must carry actual fine group delay/grid");
    end
    if(fine_mode&&dut.gsc_data_o[95:64]==32'h80000002&&dut.gsc_data_o[193:192]==2'b01)begin
     fine_packets2=fine_packets2+1;
     if(dut.gsc_data_o[191:160]!==fine_expected_group2||dut.gsc_data_o[209:200]!==10'd800)
      $fatal(1,"second fine token must carry its own delay vector metadata");
    end
    if(fine_mode&&fine_restore_requested&&!dut.gsc_data_o[95]&&dut.gsc_data_o[193:192]==2'b01)
     fine_restored_packets=fine_restored_packets+1;
   end
   if(pdm_mode?dut.pdm_valid_aligned:valid)begin
    if(audio_count==0)begin first_input=tick;first_input_id=pdm_mode?dut.pdm_frame_cnt:sample_id;end
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
   if(dut.localizer_enable)transfer_cycles[dut.g_localizer.u_transfer.state]=transfer_cycles[dut.g_localizer.u_transfer.state]+1;
   if(dut.loc_done)begin
    $display("OVERLAP_RESULT tick=%0d first_input=%0d first_sample=%0d interval=%0d compute=%0d latency=%0d",tick,first_input,dut.loc_first,overlap_previous?tick-overlap_previous:0,dut.loc_compute_cycles,dut.loc_latency);
    for(i=0;i<32;i=i+1)begin $display("TRANSFER_PHASE state=%0d cycles=%0d",i,transfer_cycles[i]);transfer_cycles[i]=0;end
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
   if(!dut.u_srp.u_scan.busy_o && srp_begin!=0)begin
    $display("SRP_ENGINE cycles=%0d",tick-srp_begin);srp_begin=0;
    $display("SRP_DONE_BOUNDARY first_sample=%0d tick=%0d raw_ready_to_scores=%0d aligned_last_pcm_to_scores=%0d",
      dut.g_localizer.u_transfer.source_first+dut.g_localizer.u_transfer.active_first,tick,
      dut.g_localizer.u_transfer.tick-dut.g_localizer.u_transfer.active_ready_tick,
      tick-first_input-(dut.g_localizer.u_transfer.source_first+dut.g_localizer.u_transfer.active_first-first_input_id+1023)*PCM_TICKS);
   end
   phase=dut.u_dtcm.memory['hafc];
   if(phase!=previous_phase)begin
    if(previous_phase!=0)$display("PHASE id=%0d begin=%0d end=%0d cycles=%0d",previous_phase,phase_begin,tick,tick-phase_begin);
    previous_phase=phase;phase_begin=tick;
   end
   if(dut.u_dtcm.memory['ha01]!=previous_frame&&!dut.u_dtcm.memory['ha5a][0])begin
    previous_frame=dut.u_dtcm.memory['ha01];frames=frames+1;
    if(overlap)$display("OVERLAP_FRAME index=%0d tick=%0d interval=%0d compute=%0d latency=%0d first_sample=%0d raw_drop=%0d window_drop=%0d audio_drop=%0d",frames,tick,last_result?tick-last_result:0,dut.loc_compute_cycles,dut.loc_latency,dut.loc_first,dut.loc_raw_drop,dut.loc_window_drop,dut.u_beam.drop_q);
    else $display("FRAME index=%0d tick=%0d first_input=%0d interval=%0d compute=%0d total=%0d first_sample=%0d reason=%0d capture_drop=%0d audio_drop=%0d audio_max=%0d",frames,tick,first_input,last_result?tick-last_result:0,dut.u_dtcm.memory['ha04],dut.u_dtcm.memory['ha05],dut.u_dtcm.memory['ha5d],dut.u_dtcm.memory['ha61],dut.u_pdm_cap.dropped_q,dut.u_beam.drop_q,dut.u_beam.max_ticks);
    last_result=tick;
    if(dump!="")begin
     $writememh($sformatf("%s/scores_%0d.hex",dump,frames),dut.u_srp.u_scan.p_mem);
     $writememh($sformatf("%s/statistics_%0d.hex",dump,frames),dut.g_localizer.u_transfer.statistics);
     if(frames==1)begin
      $writememh({dump,"/raw_ring.hex"},dut.g_localizer.u_transfer.raw_mem);
      $writememh({dump,"/spectrum.hex"},dut.g_localizer.u_transfer.spectrum);
      $writememh({dump,"/scratch.hex"},dut.g_live16_scratch.u_ram.memory);
      $writememh({dump,"/correlation_bank0.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[0].r_bank);
      $writememh({dump,"/correlation_bank1.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[1].r_bank);
      $writememh({dump,"/correlation_bank2.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[2].r_bank);
      $writememh({dump,"/correlation_bank3.hex"},dut.u_srp.u_scan.g_parallel4.g_lane[3].r_bank);
     end
    end
    if(production)begin
     if(dut.pdm_aligned[239:216]!==0)$fatal(1,"empty slot escaped mask");
     if(dut.u_dtcm.memory['ha05]>=HOP*PCM_TICKS)$fatal(1,"3.2768 ms hop service budget missed");
     if(test_case!=4)begin
      $display("WINDOW_LATENCY frame=%0d first_pcm_to_rv32=%0d acquisition_span=%0d post_acquisition=%0d",frames,
       tick-first_input-(dut.u_dtcm.memory['ha5d]-first_input_id)*PCM_TICKS,1023*PCM_TICKS,dut.u_dtcm.memory['ha05]);
      if(tick-first_input-(dut.u_dtcm.memory['ha5d]-first_input_id)*PCM_TICKS>=400000)$fatal(1,"10 ms PCM-to-publication deadline missed");
     end
     for(i=0;i<1024;i=i+1)
      if(dut.u_dtcm.memory[(dut.u_dtcm.memory['haeb]>>2)+i]!==dut.u_srp.u_scan.p_mem[i])$fatal(1,"score readback mismatch grid=%0d",i);
     for(i=0;i<45;i=i+1)
      if(dut.u_dtcm.memory['ha08+i]!==dut.g_localizer.u_transfer.statistics[i])$fatal(1,"statistics readback mismatch word=%0d",i);
     if(dut.u_dtcm.memory['ha5b] && dut.u_dtcm.memory['ha61])$fatal(1,"rejected direction was accepted");
     if(dut.loc_raw_drop || dut.loc_window_drop)$fatal(1,"continuous window loss");
     if(test_case!=4 && dut.u_dtcm.memory['ha5d]!=(frames-1)*HOP+first_input_id)$fatal(1,"hop sequence mismatch");
     if((test_case==1 || test_case==2) && (dut.u_dtcm.memory['ha5b] || dut.beam_locked))$fatal(1,"invalid input steered audio");
     if(test_case==1 && !(dut.u_dtcm.memory['ha61]&1))$fatal(1,"silence not rejected");
     if(test_case==2 && !(dut.u_dtcm.memory['ha61]&2))$fatal(1,"clipping not rejected");
     if(test_case==3 && !confirmed && dut.beam_locked)$fatal(1,"unverified geometry steered");
     if(test_case==5)begin
      if(frames<=3 || frames>=7)begin
       if(dut.u_dtcm.memory['haec]!=2 || dut.direction_approved || dut.direction_trusted || (frames<=3&&dut.beam_locked))
        $fatal(1,"PS diagnosis hold retained trusted audio frame=%0d mode=%0d approved=%0d trusted=%0d",frames,dut.u_dtcm.memory['haec],dut.direction_approved,dut.direction_trusted);
      end else begin
       if(dut.u_dtcm.memory['haec]!=1 || dut.u_dtcm.memory['haed]!=800 || !dut.beam_locked || !dut.direction_approved || (frames>=5&&!dut.direction_trusted))
        $fatal(1,"PS selected candidate did not steer frame=%0d mode=%0d grid=%0d locked=%0d approved=%0d trusted=%0d",frames,dut.u_dtcm.memory['haec],dut.u_dtcm.memory['haed],dut.beam_locked,dut.direction_approved,dut.direction_trusted);
       manual_selected=1;
      end
     end
     $display("PRODUCTION_POST compute=%0d post=%0d custom_fft=%0d custom_ifft=%0d custom_cross=%0d custom_phat=%0d custom_srp=%0d",dut.u_dtcm.memory['hae8],dut.u_dtcm.memory['hae9],forward_runs,inverse_runs,cross_runs,phat_runs,srp_runs);
    end
    if(dut.u_dtcm.memory['ha81]==32'h43595031)begin
     for(i=0;i<8;i=i+1)$display("CHANNEL ch=%0d capture=%0d prepare=%0d push=%0d run=%0d pop=%0d",i,dut.u_dtcm.memory['ha86+i*5],dut.u_dtcm.memory['ha87+i*5],dut.u_dtcm.memory['ha88+i*5],dut.u_dtcm.memory['ha89+i*5],dut.u_dtcm.memory['ha8a+i*5]);
    end
    if(frames==windows)begin
     if(dut.u_beam.error_q || dut.u_beam.drop_q)$fatal(1,"audio service failure");
     if(production && !confirmed && dut.beam_locked)$fatal(1,"unverified geometry locked");
     if(confirmed && test_case==3 && (!dut.beam_locked || !dut.direction_trusted))$fatal(1,"approved direction never reached beam");
     if(gsc_fd)begin $fclose(gsc_fd);$display("GSC_PACKETS count=%0d",gsc_packets);end
     if(fine_mode)begin
      $display("FINE_STATUS enabled=%0d valid=%0d ready=%0d control_version=%h direction_version=%h applied_version=%h link_state=%0d fine_packets=%0d committed=%0d",dut.c9_fine_enabled,dut.c9_fine_valid,dut.c9_fine_ready,dut.c9_fine_version,dut.direction_version,dut.applied_version,dut.u_direction_link.state,fine_packets,fine_committed);
      if(!fine_committed||!fine_second||fine_packets<1024||fine_packets2<1024||fine_restored_packets<1024||
         !fine_restore_requested||dut.applied_version!==dut.approved_version||dut.applied_version[31])
       $fatal(1,"fine SoC pipeline never published complete trusted raw stream");
      $display("FINE_SOC_PASS trusted_packets=%0d second_packets=%0d restored_packets=%0d version=%0d",fine_packets,fine_packets2,fine_restored_packets,dut.applied_version);
     end
     if(production && test_case==4 && !raw_done)$fatal(1,"raw capture did not resume");
     if(test_case==5 && !manual_selected)$fatal(1,"PS selected direction never tested");
     if(production && (forward_runs!=9*windows || inverse_runs!=36*windows || cross_runs!=36*windows || phat_runs!=36*windows || srp_runs!=windows))$fatal(1,"custom instruction counts mismatch");
     $display("CIRCULAR9_LATENCY_PASS frames=%0d audio_samples=%0d",frames,audio_count);$finish;
    end
   end
   if((dut.retire_valid_o && fault) || dut.u_dtcm.memory['ha03])$fatal(1,"core/firmware fault=%0d error=%0d pc=%h",fault,dut.u_dtcm.memory['ha03],dut.u_core.idex_pc);
  end
 end
 initial begin #1500000000;$fatal(1,"simulation timeout");end
endmodule
