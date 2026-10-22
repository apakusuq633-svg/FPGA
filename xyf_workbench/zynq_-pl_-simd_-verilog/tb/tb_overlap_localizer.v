`timescale 1ns/1ps
module tb_overlap_localizer;
 parameter WINDOWS=4;
 reg clk=0,rst=0,en=0,valid=0;always #12.5 clk=~clk;
 reg[287:0] pcm=0;reg[31:0] sample_id=0;
 wire busy,done,fs,fi,finv,fp,fseek,fdone;wire[31:0]fdata,fresult,window_id,first,latency,raw_drop,window_drop;
 wire rw,ss,sbusy,sdone;wire[16:0]ra;wire[15:0]rd;wire[9:0]pa,best_grid;wire signed[31:0]pd,best_score;
 rv32_overlap_localizer dut(.clk_i(clk),.rst_n_i(rst),.enable_i(en),.valid_i(valid),.pcm_i(pcm),.sample_id_i(sample_id),
  .busy_o(busy),.done_o(done),.window_id_o(window_id),.first_o(first),.latency_o(latency),.raw_drop_o(raw_drop),.window_drop_o(window_drop),
  .best_grid_o(best_grid),.best_score_o(best_score),.fft_start_o(fs),.fft_io_o(fi),.fft_inv_o(finv),.fft_pop_o(fp),.fft_seek_o(fseek),.fft_data_o(fdata),.fft_done_i(fdone),.fft_result_i(fresult),
  .srp_r_we_o(rw),.srp_r_addr_o(ra),.srp_r_data_o(rd),.srp_start_o(ss),.srp_done_i(sdone),.srp_busy_i(sbusy),.srp_score_addr_o(pa),.srp_score_i(pd));
 rv32_fft_bfly fft(.clk_i(clk),.rst_n_i(rst),.start_i(fs),.keep_i(1'b1),.commit_i(1'b1),.inv_i(finv),.is_io_i(fi),.io_sel_i(fp),.io_seek_i(fseek),.scalar_i(fdata),.stall_o(),.done_o(fdone),.result_o(fresult));
 rv32_srp_scan #(.N_PAIR(66),.N_GRID(1024),.R_LEN(32),.IDX_W(5),.FRAC_W(4),.ADDR_W(17),.GRID_IDX_W(10),.FAST_SCAN(1)) srp(
  .clk_i(clk),.rst_n_i(rst),.en_i(1'b1),.start_i(ss),.busy_o(sbusy),.done_o(sdone),.lut_we_i(1'b0),.lut_addr_i(17'b0),.lut_data_i(9'b0),.r_we_i(rw),.r_addr_i(ra),.r_data_i($signed(rd)),.p_addr_i(pa),.p_data_o(pd),.cycle_cnt_o());
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
  $readmemh("build/strict_overlap/vectors/lut.hex",srp.lut_mem);
  repeat(4)@(negedge clk);rst=1;en=1;
 end
 always @(negedge clk)if(rst)begin
  valid=received<WINDOWS && cycle%1024==0;
  if(valid)begin
   sample_id=produced;
   for(ch=0;ch<12;ch=ch+1)pcm[ch*24+:24]={input_pcm[(produced%2048)*12+ch],8'b0};
   produced=produced+1;
  end
 end
 always @(posedge clk)if(rst)begin
  cycle=cycle+1;w=dut.active_first[10:9];
  if(valid&&produced>=1024&&(produced-1024)%512==0&&(produced-1024)/512<WINDOWS)
   ready_cycles[(produced-1024)/512]=cycle;
  if(dut.state==2&&dut.pass==0)begin
   if(dut.sample!==$signed(input_pcm[((dut.active_first+dut.n)%2048)*12+dut.channel]))
    $fatal(1,"RAW_WINDOW mismatch first=%0d ch=%0d n=%0d",dut.active_first,dut.channel,dut.n);
   raw_checked=raw_checked+1;
  end
  if(dut.wr_active)raw_writes=raw_writes+1;
  if(fs&&!fi)begin if(finv)inv_runs=inv_runs+1;else fwd_runs=fwd_runs+1;end
  if(fs&&fi&&fp&&!fseek&&!finv)begin
   if(fresult!==ref_spectra[(w*12+dut.channel)*513+dut.index])$fatal(1,"FFT mismatch win=%0d ch=%0d bin=%0d got=%h expected=%h",window_id,dut.channel,dut.index,fresult,ref_spectra[(w*12+dut.channel)*513+dut.index]);
   fft_bins=fft_bins+1;
  end
  if(dut.state==2&&dut.pass==2 &&dut.window_sample!==ref_prepared[(w*12+dut.channel)*1024+dut.n])$fatal(1,"PREP mismatch ch=%0d n=%0d got=%h expected=%h mean=%0d shifts=%0d,%0d",dut.channel,dut.n,dut.window_sample,ref_prepared[(w*12+dut.channel)*1024+dut.n],dut.mean,dut.left_shift,dut.right_shift);
  if(dut.state==15 &&dut.ac_result!==ref_phi[(w*66+dut.pair)*513+6+dut.index])$fatal(1,"PHAT mismatch pair=%0d bin=%0d",dut.pair,dut.index+6);
  if(rw)begin
   lag=ra%32;if(lag>=16)lag=lag+992;word_index=(w*66+dut.pair)*512+(lag>>1);ref_word=ref_corr[word_index];expected_ring=lag%2?ref_word[31:16]:ref_word[15:0];
   if(rd!==expected_ring)$fatal(1,"RING mismatch pair=%0d lag=%0d got=%h expected=%h",dut.pair,lag,rd,expected_ring);
   ring_values=ring_values+1;
  end
  if(ss)srp_runs=srp_runs+1;
  if(dut.state==27&&pd!==ref_scores[w*1024+pa])$fatal(1,"SRP score mismatch win=%0d grid=%0d",window_id,pa);
  if(done)begin
   received=received+1;if(first!==(received-1)*512)$fatal(1,"WINDOW_GAP");
   if(raw_drop||window_drop)$fatal(1,"CAPTURE_LOSS raw=%0d windows=%0d",raw_drop,window_drop);
   for(k=0;k<60;k=k+1)if(dut.statistics[k]!==ref_stats[w*60+k])$fatal(1,"STATS mismatch index=%0d",k);
   if(raw_checked!=received*12288)$fatal(1,"RAW_WINDOW_COUNT");
   end_to_end=cycle-ready_cycles[received-1];
   result_gap=previous_result==0?0:cycle-previous_result;previous_result=cycle;
   if(end_to_end>max_latency)max_latency=end_to_end;
   $display("OVERLAP_WINDOW id=%0d first=%0d latency=%0d fwd=%0d inv=%0d srp=%0d raw_drop=%0d window_drop=%0d ready=%0d result=%0d gap=%0d raw_checked=%0d",window_id,first,end_to_end,fwd_runs,inv_runs,srp_runs,raw_drop,window_drop,ready_cycles[received-1],cycle,result_gap,raw_checked);
   if(received==WINDOWS)begin
    if(fwd_runs!=12*WINDOWS||inv_runs!=66*WINDOWS||srp_runs!=WINDOWS||ring_values!=2112*WINDOWS||fft_bins!=6156*WINDOWS)$fatal(1,"WORK_COUNT_MISMATCH");
    $display("OVERLAP_LOCALIZER_NUMERIC_PASS windows=%0d max_latency=%0d raw_writes=%0d",received,max_latency,raw_writes);
    $display("OVERLAP_COVERAGE first=0 samples=%0d raw_drop=%0d window_drop=%0d",produced,raw_drop,window_drop);
    if(max_latency>524288)$display("STRICT_REALTIME_FAIL measured=%0d budget=524288",max_latency);else $display("STRICT_REALTIME_MODULE_PASS windows=%0d max_latency=%0d",received,max_latency);
    $finish;
   end
  end
  if(cycle>(WINDOWS+4)*524288)$fatal(1,"TIMEOUT windows=%0d state=%0d",received,dut.state);
 end
endmodule
