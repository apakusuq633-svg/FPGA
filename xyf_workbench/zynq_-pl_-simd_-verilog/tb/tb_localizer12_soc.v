`timescale 1ns/1ps
module tb_localizer12_soc;
 parameter WINDOWS=4;
 reg clk=0,rst=0,en=0,valid=0;always #12.5 clk=~clk;
 reg[287:0] pcm=0;reg[31:0] sample_id=0;
 reg cw=0,wr=0,rd_cfg=0;reg[8:0] ci=0;reg[15:0] cd=0;
 reg[6:0] cfg_addr=0;reg[31:0] cfg_data=0;
 wire[3:0] fault;wire retire_valid;wire[31:0] retire_instr;
 rv32_soc #(.ITCM_FILE("build/localizer12/fw/itcm.hex"),.DTCM_FILE("build/localizer12/fw/dtcm.hex")) dut(
 .clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),.fromhost_i(32'b0),
 .retire_fault_o(fault),.retire_valid_o(retire_valid),.retire_instr_o(retire_instr),
 .ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
 .tacho_i(1'b0),.pdm_din_i(6'b0),.coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),
 .coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
 .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd_cfg),.pdm_cfg_addr_i(cfg_addr),.pdm_cfg_wdata_i(cfg_data),
 .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
 .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
 .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
 wire done=dut.loc_done,fs=dut.u_core.u_fft_bfly.io_fire||dut.u_core.u_fft_bfly.run_start;
 wire fi=dut.u_core.u_fft_bfly.is_io_i,finv=dut.u_core.u_fft_bfly.inv_i;
 wire fp=dut.u_core.u_fft_bfly.io_sel_i,fseek=dut.u_core.u_fft_bfly.io_seek_i;
 wire[31:0] fresult=dut.loc_fft_result,window_id=dut.loc_window,first=dut.loc_first,latency=dut.loc_latency;
 wire[31:0] raw_drop=dut.loc_raw_drop,window_drop=dut.loc_window_drop;
 wire rw=dut.loc_r_we,ss=dut.u_srp.scan_start;wire[16:0]ra=dut.loc_r_addr;
 wire[15:0]rd=dut.loc_r_data;wire[9:0]pa=dut.loc_score_addr;wire signed[31:0]pd=dut.loc_srp_score;
 integer audio_in=0,audio_out=0,total_pcm,expected_audio,j;
 integer retire_fwd=0,retire_inv=0,retire_cross=0,retire_phat=0,retire_srp=0;
 reg finish_pending=0;
 reg[31:0] audio_golden[0:(WINDOWS+4)*512];
 task wc;
 input[6:0] a;input[31:0] d;
 begin @(negedge clk);cfg_addr=a;cfg_data=d;wr=1;@(negedge clk);wr=0;end
 endtask
 reg[15:0] input_pcm[0:24575],ref_prepared[0:49151];
 reg[31:0] ref_spectra[0:24623],ref_phi[0:135431],ref_corr[0:135167],ref_scores[0:4095],ref_stats[0:239];
 integer cycle=0,produced=0,received=0,ch,k,w,lag,word_index,raw_writes=0,fwd_runs=0,inv_runs=0,fft_bins=0,ring_values=0,srp_runs=0,max_latency=0;
 integer ready_cycles[0:WINDOWS-1];
 integer raw_checked=0,previous_result=0,result_gap=0,end_to_end=0;
 reg[31:0] ref_word;reg[15:0] expected_ring;
 initial begin
  $readmemh("build/strict_overlap/vectors/pcm.hex",input_pcm);
  $readmemh("build/strict_overlap/vectors/prepared.hex",ref_prepared);
  $readmemh("build/strict_overlap/vectors/spectra.hex",ref_spectra);
  $readmemh("build/strict_overlap/vectors/phi.hex",ref_phi);
  $readmemh("build/strict_overlap/vectors/correlation.hex",ref_corr);
  $readmemh("build/strict_overlap/vectors/scores.hex",ref_scores);
  $readmemh("build/strict_overlap/vectors/stats.hex",ref_stats);
  $readmemh("build/strict_overlap/vectors/lut.hex",dut.u_srp.u_scan.lut_mem);
  force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=sample_id;
  repeat(4)@(negedge clk);rst=1;en=1;
  for(j=0;j<32;j=j+1)begin @(negedge clk);cw=1;ci=j;cd=j==0?32767:0;end
  @(negedge clk);cw=0;wc(32,5);cfg_addr=35;
 end
 always @(negedge clk)if(rst)begin
  valid=received<WINDOWS && dut.localizer_enable && cycle%1024==0;
  rd_cfg=cfg_addr==35 && dut.u_beam.count!=0;
  if(valid)begin
   sample_id=produced;
   for(ch=0;ch<12;ch=ch+1)pcm[ch*24+:24]={input_pcm[(produced%2048)*12+ch],8'b0};
   produced=produced+1;
  end
 end
 always @(posedge clk)if(rst)begin
  if(retire_valid&&fault)$fatal(1,"CPU_FAULT %h",fault);
  if(valid)begin
   total_pcm=0;
   for(j=0;j<12;j=j+1)total_pcm=total_pcm+$signed(pcm[j*24+8+:16]);
   expected_audio=total_pcm+6;
   expected_audio=expected_audio<0?-((-expected_audio+11)/12):expected_audio/12;
   audio_golden[audio_in]={16'((expected_audio*32767)>>>15),16'(expected_audio)};
   audio_in=audio_in+1;
  end
  if(dut.u_beam.push)begin
   if({dut.beam_fir_result,dut.u_beam.das_q}!==audio_golden[audio_out])
    $fatal(1,"AUDIO_GOLDEN sample=%0d got=%h expected=%h",audio_out,{dut.beam_fir_result,dut.u_beam.das_q},audio_golden[audio_out]);
   audio_out=audio_out+1;
  end
  if(retire_valid)begin
   if(retire_instr[6:0]==7'h0b&&retire_instr[14:12]==7&&retire_instr[31]&&retire_instr[29])begin
    if(retire_instr[30])retire_inv=retire_inv+1;else retire_fwd=retire_fwd+1;
   end
   if(retire_instr[6:0]==7'h0b&&!retire_instr[31]&&retire_instr[14:12]==6)retire_cross=retire_cross+1;
   if(retire_instr[6:0]==7'h0b&&!retire_instr[31]&&retire_instr[14:12]==5)retire_phat=retire_phat+1;
   if(retire_instr[6:0]==7'h2b&&retire_instr[14:12]==0)retire_srp=retire_srp+1;
  end
  cycle=cycle+1;w=dut.g_localizer.u_transfer.active_first[10:9];
  if(valid&&produced>=1024&&(produced-1024)%512==0&&(produced-1024)/512<WINDOWS)
   ready_cycles[(produced-1024)/512]=cycle;
  if(dut.g_localizer.u_transfer.state==2&&dut.g_localizer.u_transfer.pass==0)begin
   if(dut.g_localizer.u_transfer.sample!==$signed(input_pcm[((dut.g_localizer.u_transfer.active_first+dut.g_localizer.u_transfer.n)%2048)*12+dut.g_localizer.u_transfer.channel]))
    $fatal(1,"RAW_WINDOW mismatch first=%0d ch=%0d n=%0d",dut.g_localizer.u_transfer.active_first,dut.g_localizer.u_transfer.channel,dut.g_localizer.u_transfer.n);
   raw_checked=raw_checked+1;
  end
  if(dut.g_localizer.u_transfer.wr_active)raw_writes=raw_writes+1;
  if(fs&&!fi)begin if(finv)inv_runs=inv_runs+1;else fwd_runs=fwd_runs+1;end
  if(fs&&fi&&fp&&!fseek&&!finv)begin
   if(fresult!==ref_spectra[(w*12+dut.g_localizer.u_transfer.channel)*513+dut.g_localizer.u_transfer.index])$fatal(1,"FFT mismatch win=%0d ch=%0d bin=%0d got=%h expected=%h",window_id,dut.g_localizer.u_transfer.channel,dut.g_localizer.u_transfer.index,fresult,ref_spectra[(w*12+dut.g_localizer.u_transfer.channel)*513+dut.g_localizer.u_transfer.index]);
   fft_bins=fft_bins+1;
  end
  if(dut.g_localizer.u_transfer.state==2&&dut.g_localizer.u_transfer.pass==2 &&dut.g_localizer.u_transfer.window_sample!==ref_prepared[(w*12+dut.g_localizer.u_transfer.channel)*1024+dut.g_localizer.u_transfer.n])$fatal(1,"PREP mismatch ch=%0d n=%0d got=%h expected=%h mean=%0d shifts=%0d,%0d",dut.g_localizer.u_transfer.channel,dut.g_localizer.u_transfer.n,dut.g_localizer.u_transfer.window_sample,ref_prepared[(w*12+dut.g_localizer.u_transfer.channel)*1024+dut.g_localizer.u_transfer.n],dut.g_localizer.u_transfer.mean,dut.g_localizer.u_transfer.left_shift,dut.g_localizer.u_transfer.right_shift);
  if(dut.g_localizer.u_transfer.state==15 && dut.loc_ac_ready &&dut.g_localizer.u_transfer.ac_result!==ref_phi[(w*66+dut.g_localizer.u_transfer.pair)*513+6+dut.g_localizer.u_transfer.index])$fatal(1,"PHAT mismatch pair=%0d bin=%0d",dut.g_localizer.u_transfer.pair,dut.g_localizer.u_transfer.index+6);
  if(rw)begin
   lag=ra%32;if(lag>=16)lag=lag+992;word_index=(w*66+dut.g_localizer.u_transfer.pair)*512+(lag>>1);ref_word=ref_corr[word_index];expected_ring=lag%2?ref_word[31:16]:ref_word[15:0];
   if(rd!==expected_ring)$fatal(1,"RING mismatch pair=%0d lag=%0d got=%h expected=%h",dut.g_localizer.u_transfer.pair,lag,rd,expected_ring);
   ring_values=ring_values+1;
  end
  if(ss)srp_runs=srp_runs+1;
  if(dut.g_localizer.u_transfer.state==27&&pd!==ref_scores[w*1024+pa])$fatal(1,"SRP score mismatch win=%0d grid=%0d",window_id,pa);
  if(done)begin
   received=received+1;if(first!==(received-1)*512)$fatal(1,"WINDOW_GAP");
   if(raw_drop||window_drop)$fatal(1,"CAPTURE_LOSS raw=%0d windows=%0d",raw_drop,window_drop);
   for(k=0;k<60;k=k+1)if(dut.g_localizer.u_transfer.statistics[k]!==ref_stats[w*60+k])$fatal(1,"STATS mismatch index=%0d",k);
   if(raw_checked!=received*12288)$fatal(1,"RAW_WINDOW_COUNT");
   end_to_end=cycle-ready_cycles[received-1];
   result_gap=previous_result==0?0:cycle-previous_result;previous_result=cycle;
   if(end_to_end>max_latency)max_latency=end_to_end;
   $display("OVERLAP_WINDOW id=%0d first=%0d latency=%0d fwd=%0d inv=%0d srp=%0d raw_drop=%0d window_drop=%0d ready=%0d result=%0d gap=%0d raw_checked=%0d",window_id,first,end_to_end,fwd_runs,inv_runs,srp_runs,raw_drop,window_drop,ready_cycles[received-1],cycle,result_gap,raw_checked);
   if(retire_fwd!=12*received||retire_inv!=66*received||retire_cross!=66*received||retire_phat!=66*received||retire_srp!=received)
    $fatal(1,"CPU_CUSTOM_COUNT fwd=%0d inv=%0d cross=%0d phat=%0d srp=%0d",retire_fwd,retire_inv,retire_cross,retire_phat,retire_srp);
   if(dut.u_beam.drop_q||dut.u_beam.max_ticks>=1024)$fatal(1,"AUDIO_DROP");
   if(received==WINDOWS)begin
    if(fwd_runs!=12*WINDOWS||inv_runs!=66*WINDOWS||srp_runs!=WINDOWS||ring_values!=2112*WINDOWS||fft_bins!=6156*WINDOWS)$fatal(1,"WORK_COUNT_MISMATCH");
    $display("OVERLAP_LOCALIZER_NUMERIC_PASS windows=%0d max_latency=%0d raw_writes=%0d",received,max_latency,raw_writes);
    $display("OVERLAP_COVERAGE first=0 samples=%0d raw_drop=%0d window_drop=%0d",produced,raw_drop,window_drop);
    if(max_latency>524288)$display("STRICT_REALTIME_FAIL measured=%0d budget=524288",max_latency);else $display("STRICT_REALTIME_MODULE_PASS windows=%0d max_latency=%0d",received,max_latency);
    finish_pending=1;
   end
  end
  if(finish_pending&&audio_out==audio_in&&dut.u_beam.count==0&&dut.tohost_q==32'h4c4f4302)begin
   $display("LOCALIZER12_SOC_PASS windows=%0d audio_in=%0d audio_out=%0d audio_drops=%0d audio_max=%0d custom_fwd=%0d custom_inv=%0d custom_cross=%0d custom_phat=%0d custom_srp=%0d",received,audio_in,audio_out,dut.u_beam.drop_q,dut.u_beam.max_ticks,retire_fwd,retire_inv,retire_cross,retire_phat,retire_srp);
   $finish;
  end
  if(cycle>(WINDOWS+4)*524288)$fatal(1,"TIMEOUT windows=%0d state=%0d",received,dut.g_localizer.u_transfer.state);
 end
endmodule
