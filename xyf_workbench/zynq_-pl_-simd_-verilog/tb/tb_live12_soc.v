`timescale 1ns/1ps
module tb_live12_soc;
  localparam integer SNAPSHOT_FRAMES = 2;
  reg clk=0;always #5 clk=~clk;
  reg rst=0;reg [287:0] pcm=0;reg valid=0;reg [31:0] frame_number=0;
  reg wr=0,rd=0;reg [6:0] addr=0;reg [31:0] data=0;wire [31:0] result;
  reg cw=0;reg [8:0] ci=0;reg [15:0] cd=0;wire [3:0] fault;
`ifdef LIVE12_PROFILE
  rv32_soc #(.DAS_ACTIVE_CHANNELS(12),.ITCM_FILE("build/das12_profile/fw/itcm.hex"),.DTCM_FILE("build/das12_profile/fw/dtcm.hex")) dut(
`else
  rv32_soc #(.DAS_ACTIVE_CHANNELS(12),.ITCM_FILE("build/das12/fw/itcm.hex"),.DTCM_FILE("build/das12/fw/dtcm.hex")) dut(
`endif
    .clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),.fromhost_i(32'b0),
    .retire_fault_o(fault),.ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),
    .ps_addr_i(32'b0),.ps_wdata_i(32'b0),.tacho_i(1'b0),.pdm_din_i(6'b0),
    .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
    .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd),.pdm_cfg_addr_i(addr),.pdm_cfg_wdata_i(data),.pdm_cfg_rdata_o(result),
    .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
    .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
    .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
  integer n,ch,k,total,expected,sample_value,stats_sum;
`ifdef LIVE12_TEST_SRP
 reg[31:0] test_scores[0:4095];integer test_srp_frame=0,test_srp_k;
 initial begin
  $readmemh("build/pdm12_test_srp/lut.hex",dut.u_srp.u_scan.lut_mem);
  $readmemh("build/pdm12_test_srp/scores.hex",test_scores);
 end
 always @(negedge clk)if(rst && dut.u_dtcm.memory['ha01]>test_srp_frame)begin
  for(test_srp_k=0;test_srp_k<1024;test_srp_k=test_srp_k+1)
   if(dut.g_live16_scratch.u_ram.memory['h2800+test_srp_k]!==test_scores[test_srp_frame*1024+test_srp_k])
    $fatal(1,"TEST_SRP_SCORE_MISMATCH frame=%0d grid=%0d",test_srp_frame,test_srp_k);
  $display("TEST_SRP_FRAME frame=%0d pairs=66 grid=1024 wait=%0d hardware=%0d readback=%0d best_grid=%0d best_score=%0d TEST_GEOMETRY_ONLY",
    test_srp_frame+1,dut.u_dtcm.memory['ha00+203],dut.u_dtcm.memory['ha00+204],dut.u_dtcm.memory['ha00+205],dut.u_dtcm.memory['ha00+206],$signed(dut.u_dtcm.memory['ha00+207]));
  test_srp_frame=test_srp_frame+1;
 end
`endif
`ifdef LIVE12_PROFILE
  integer fft_stall_cycles=0,max_fft_stall_cycles=0;
  always @(posedge clk)begin
    if(dut.u_core.fft_stall)fft_stall_cycles=fft_stall_cycles+1;
    else if(fft_stall_cycles!=0)begin
      if(fft_stall_cycles>max_fft_stall_cycles)max_fft_stall_cycles=fft_stall_cycles;
      fft_stall_cycles=0;
    end
  end
`endif
  reg [63:0] stats_energy;reg [31:0] stats_square;integer stats_peak,stats_abs;
  reg [31:0] word;
`ifdef LIVE12_NUMERIC66
  reg [15:0] test_pcm[0:49151];
  reg [31:0] test_stats[0:239];
  reg [31:0] test_spectra[0:24623],test_phi[0:135431],test_corr[0:135167],test_cross[0:54911];
  integer audit_count=0,audit_frame=0,audit_pair=0,audit_k,audit_sum=0,audit_full_sum=0;
  integer input_index;
  integer audit_stages[0:7],audit_copy_sum=0;
  initial begin
    for(audit_k=0;audit_k<8;audit_k=audit_k+1)audit_stages[audit_k]=0;
    $readmemh("build/pdm12_numeric/pcm.hex",test_pcm);
    $readmemh("build/pdm12_numeric/stats.hex",test_stats);
    $readmemh("build/pdm12_numeric/spectra.hex",test_spectra);
    $readmemh("build/pdm12_numeric/phi.hex",test_phi);
    if($test$plusargs("corrupt_ref"))test_phi[6]=test_phi[6]^1;
    $readmemh("build/pdm12_numeric/full_corr.hex",test_corr);
    $readmemh("build/pdm12_numeric/cross.hex",test_cross);
  end
  always @(negedge clk)if(rst && dut.u_dtcm.memory['ha00+196]>audit_pair)begin
    audit_frame=dut.u_dtcm.memory['ha00+197]-1;
    for(audit_k=0;audit_k<513;audit_k=audit_k+1)
      if(dut.g_live16_scratch.u_ram.memory['h3400+audit_k]!==test_phi[(audit_frame*66+audit_pair)*513+audit_k])
        $fatal(1,"PHAT mismatch frame=%0d pair=%0d bin=%0d",audit_frame,audit_pair,audit_k);
    for(audit_k=0;audit_k<512;audit_k=audit_k+1)
      if(dut.g_live16_scratch.u_ram.memory['h2400+audit_k]!==test_corr[(audit_frame*66+audit_pair)*512+audit_k])
        $fatal(1,"full IFFT mismatch frame=%0d pair=%0d word=%0d",audit_frame,audit_pair,audit_k);
    for(audit_k=0;audit_k<16;audit_k=audit_k+1)
      if(dut.g_live16_scratch.u_ram.memory['h2600+(audit_k<8?audit_k:audit_k+496)]!==test_corr[(audit_frame*66+audit_pair)*512+(audit_k<8?audit_k:audit_k+496)])
        $fatal(1,"ring mismatch frame=%0d pair=%0d word=%0d",audit_frame,audit_pair,audit_k);
    if(audit_pair==0||audit_pair==65)for(audit_k=0;audit_k<6156;audit_k=audit_k+1)
      if(dut.g_live16_scratch.u_ram.memory[audit_k]!==test_spectra[audit_frame*6156+audit_k])
        $fatal(1,"FFT cache mismatch frame=%0d word=%0d",audit_frame,audit_k);
    audit_sum=audit_sum+dut.u_dtcm.memory['ha00+198];audit_full_sum=audit_full_sum+dut.u_dtcm.memory['ha00+199];
    audit_copy_sum=audit_copy_sum+dut.u_dtcm.memory['ha00+201];
    for(audit_k=0;audit_k<8;audit_k=audit_k+1)audit_stages[audit_k]=audit_stages[audit_k]+dut.u_dtcm.memory['ha00+208+audit_k];
    audit_count=audit_count+1;audit_pair=audit_pair+1;
    if(audit_pair==66)begin
      $display("NUMERIC66_FRAME frame=%0d pairs=66 ring_cycles=%0d full_check_cycles=%0d",audit_frame+1,audit_sum,audit_full_sum);
      $display("GCC_STAGES frame=%0d input=%0d cross=%0d phat=%0d spectrum_pop_pad=%0d ifft_total=%0d ifft_push=%0d ifft_run=%0d ring_pop=%0d audit_copy=%0d",
        audit_frame+1,audit_stages[0],audit_stages[1],audit_stages[2],audit_stages[3],audit_stages[4],audit_stages[5],audit_stages[6],audit_stages[7],audit_copy_sum);
      for(audit_k=0;audit_k<8;audit_k=audit_k+1)audit_stages[audit_k]=0;audit_copy_sum=0;
      audit_sum=0;audit_full_sum=0;
    end
  end else if(dut.u_dtcm.memory['ha00+196]===0) audit_pair=0;
  genvar audit_lane;
  generate for(audit_lane=0;audit_lane<4;audit_lane=audit_lane+1)begin: cross_check
    integer q;
    always @(posedge clk)if(rst && dut.u_core.u_acoustic_ext.state_q==0 && dut.u_core.u_acoustic_ext.start_i &&
       !dut.u_core.u_acoustic_ext.is_io_i && dut.u_core.u_acoustic_ext.op_i==1)
      for(q=0;q<52;q=q+1)
        if(dut.u_core.u_acoustic_ext.g_mzb[audit_lane].mem[q]!==test_cross[((dut.u_dtcm.memory['ha00+197]-1)*66+audit_pair)*208+q*4+audit_lane])
          $fatal(1,"cross-spectrum mismatch pair=%0d lane=%0d index=%0d",audit_pair,audit_lane,q);
  end endgenerate
`endif
  function integer source;
    input integer time_index,channel;
    begin
`ifdef LIVE12_NUMERIC66
      source=$signed(test_pcm[((dut.u_dtcm.memory['ha00+1]%4)*12+channel)*1024+time_index%1024]);
`else
      source=((time_index%1024)-512)*(channel+1)+channel*137;
`endif
    end
  endfunction
  task wc;
    input [6:0] a;input [31:0] value;
    begin @(negedge clk);addr=a;data=value;wr=1;@(negedge clk);wr=0;end
  endtask
  initial begin
    force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=frame_number;
    repeat(4)@(negedge clk);rst=1;
`ifdef LIVE12_NUMERIC66
    dut.g_live16_scratch.u_ram.memory[6156]=32'hcafe1234;
    dut.g_live16_scratch.u_ram.memory['h23ff]=32'hcafe1234;
    dut.g_live16_scratch.u_ram.memory['h2e00]=32'hcafe1234;
    dut.g_live16_scratch.u_ram.memory['h3601]=32'hcafe1234;
`endif
    for(k=0;k<32;k=k+1)begin @(negedge clk);cw=1;ci=k;cd=k==0?32767:0;end
    @(negedge clk);cw=0;wc(32,5);
    k=0;while(!dut.u_pdm_cap.capture_q&&k<100000)begin @(negedge clk);k=k+1;end
    if(k==100000)$fatal(1,"firmware initialization timeout");
    for(n=0;n<60000 && dut.u_dtcm.memory['ha00+1]<SNAPSHOT_FRAMES;n=n+1)begin
      total=0;
      for(ch=0;ch<12;ch=ch+1)begin
`ifdef LIVE12_NUMERIC66
    if(dut.g_live16_scratch.u_ram.memory[6156]!==32'hcafe1234 || dut.g_live16_scratch.u_ram.memory['h23ff]!==32'hcafe1234 ||
       dut.g_live16_scratch.u_ram.memory['h2e00]!==32'hcafe1234 || dut.g_live16_scratch.u_ram.memory['h3601]!==32'hcafe1234)
      $fatal(1,"scratch guard corruption");
        input_index=dut.u_pdm_cap.pos_q+(dut.u_pdm_cap.ready_q[0]?512:0);
        sample_value=source(input_index,ch);
`else
        sample_value=source(n,ch);
`endif
        pcm[ch*24+:24]=sample_value*256;total=total+sample_value;
      end
      expected=total+6;expected=expected<0?-((-expected+11)/12):expected/12;
      @(negedge clk);frame_number=n;valid=1;@(negedge clk);valid=0;
      repeat(180)@(negedge clk);addr=35;rd=1;#1;word=result;
      if($signed(word[15:0])!==expected || $signed(word[31:16])!==((expected*32767)>>>15))
        $fatal(1,"12-channel audio mismatch sample=%0d got=%h expected=%0d beam_state=%0d count=%0d drop=%0d max=%0d own=%0d fir_done=%0d pc=%h",n,word,expected,dut.u_beam.state,dut.u_beam.count,dut.u_beam.drop_q,dut.u_beam.max_ticks,dut.u_core.audio_own,dut.beam_fir_done,dut.u_core.idex_pc);
      @(negedge clk);rd=0;repeat(841)@(negedge clk);
      if(dut.u_dtcm.memory['ha00+3]!==0)$fatal(1,"firmware error=%0d",dut.u_dtcm.memory['ha00+3]);
    end
    if(dut.u_dtcm.memory['ha00+1]<SNAPSHOT_FRAMES)$fatal(1,"firmware snapshot timeout");
    if(dut.u_dtcm.memory['ha00]!==32'hda512001 || dut.u_dtcm.memory['ha00+89]!==32'h4d493132)
      $fatal(1,"wrong 12-channel ABI");
`ifndef LIVE12_NUMERIC66
    for(ch=0;ch<12;ch=ch+1)begin
      stats_sum=0;stats_energy=0;stats_peak=0;
      for(k=0;k<1024;k=k+1)begin
        sample_value=source(k,ch);stats_sum=stats_sum+sample_value;
        stats_square=sample_value*sample_value;stats_energy=stats_energy+stats_square;
        stats_abs=sample_value<0?-sample_value:sample_value;
        if(stats_abs>stats_peak)stats_peak=stats_abs;
      end
      if(dut.u_dtcm.memory['ha00+8+5*ch]!==stats_sum)$fatal(1,"capture channel=%0d stats sum mismatch",ch);
      if(dut.u_dtcm.memory['ha00+9+5*ch]!==stats_energy[31:0]||dut.u_dtcm.memory['ha00+10+5*ch]!==stats_energy[63:32])$fatal(1,"capture energy mismatch channel=%0d",ch);
      if(dut.u_dtcm.memory['ha00+11+5*ch]!==stats_peak||dut.u_dtcm.memory['ha00+12+5*ch]!==0)$fatal(1,"capture peak/clip mismatch channel=%0d",ch);
    end
`endif
    if(dut.beam_locked || dut.u_dtcm.memory['ha00+91]!==0 || dut.u_dtcm.memory['ha00+95]!==0)
      $fatal(1,"unconfirmed geometry published localization");
`ifdef LIVE12_PROFILE
    if(dut.u_dtcm.memory['ha00+129]!==32'h43595031 || dut.u_dtcm.memory['ha00+128][0] ||
       dut.u_dtcm.memory['ha00+130]!==SNAPSHOT_FRAMES || dut.u_dtcm.memory['ha00+131]!==12)
      $fatal(1,"cycle profile publication invalid");
    $display("CYCLE_BASELINE cycles=%0d",dut.u_dtcm.memory['ha00+132]);
`ifdef LIVE12_TEST_SRP
    $display("CYCLE_SCOPE frame=%0d compute=%0d total=%0d fft_channels=12 gcc_pairs=66 srp=1 steering=0 first=%0d",
`elsif LIVE12_NUMERIC66
    $display("CYCLE_SCOPE frame=%0d compute=%0d total=%0d fft_channels=12 gcc_pairs=66 srp=0 steering=0 first=%0d",
`else
    $display("CYCLE_SCOPE frame=%0d compute=%0d total=%0d fft_channels=12 gcc_pairs=0 srp=0 steering=0 first=%0d",
`endif
      dut.u_dtcm.memory['ha00+1],dut.u_dtcm.memory['ha00+4],dut.u_dtcm.memory['ha00+5],dut.u_dtcm.memory['ha00+93]);
    for(ch=0;ch<12;ch=ch+1)begin
      for(k=0;k<5;k=k+1)if(!(k==0 && ch%2==1) && dut.u_dtcm.memory['ha00+134+5*ch+k]===0)
        $fatal(1,"empty cycle stage ch=%0d stage=%0d",ch,k);
      if(max_fft_stall_cycles<1 || dut.u_dtcm.memory['ha00+137+5*ch]<max_fft_stall_cycles)
        $fatal(1,"RUN failed to include blocking FFT cycles");
      $display("CYCLE_PROFILE ch=%0d capture=%0d prepare=%0d push=%0d run=%0d pop=%0d",ch,
        dut.u_dtcm.memory['ha00+134+5*ch],dut.u_dtcm.memory['ha00+135+5*ch],
        dut.u_dtcm.memory['ha00+136+5*ch],dut.u_dtcm.memory['ha00+137+5*ch],dut.u_dtcm.memory['ha00+138+5*ch]);
    end
`endif
    addr=36;#1;if(result!==0)$fatal(1,"audio dropped");
`ifdef LIVE12_NUMERIC66
    if(audit_count!=66*SNAPSHOT_FRAMES)$fatal(1,"missing GCC pairs got=%0d",audit_count);
    $display("NUMERIC66_PASS frames=%0d pairs=%0d spectrum_phi_full_ring_errors=0",SNAPSHOT_FRAMES,audit_count);
`endif
    $display("LIVE12_SOC_PASS channels=12 lines=6 pairs=66 snapshots=%0d audio_samples=%0d drops=0 geometry_enabled=0",SNAPSHOT_FRAMES,n);
`ifdef LIVE12_TEST_SRP
    if(test_srp_frame!=SNAPSHOT_FRAMES)$fatal(1,"missing TEST SRP frames");
    $display("TEST_SRP_PASS frames=%0d score_errors=0 geometry=TEST_GEOMETRY_ONLY",test_srp_frame);
`endif
    $finish;
  end
  always @(posedge clk)if(rst && fault!=0)$fatal(1,"RV32 fault=%h",fault);
  initial begin #600000000;$fatal(1,"timeout");end

integer prof_total=0,prof_memory=0,prof_fft=0,prof_div=0,prof_vec=0,prof_acou=0,prof_load=0,prof_other=0;
integer stage_capture,stage_prepare,stage_push,stage_run,stage_pop,stage_k,previous_first=-1;
integer prof_retired=0,prof_srp=0,prof_audio=0,prof_fft_io=0,prof_xsp_io=0,prof_frame=0,prof_pc;
integer prof_capreads=0,prof_capindices=0,prof_scratch_reads=0,prof_scratch_writes=0;
integer prof_active=0,prof_i;
integer prof_fn_0=0;
integer prof_fn_1=0;
integer prof_fn_2=0;
integer prof_fn_3=0;
integer mem_phase,mem_k;
integer phase_total[0:9],phase_mmio[0:9],phase_dtcm[0:9],phase_scratch[0:9],phase_lsu[0:9],phase_retired[0:9];
initial for(mem_k=0;mem_k<10;mem_k=mem_k+1)begin phase_total[mem_k]=0;phase_mmio[mem_k]=0;phase_dtcm[mem_k]=0;phase_scratch[mem_k]=0;phase_lsu[mem_k]=0;phase_retired[mem_k]=0;end
`ifdef LIVE12_PROFILE
reg [3:0] function_tags[0:4095];
integer capture_ex=0,capture_memory=0,capture_load_use=0,capture_retired=0,capture_stack_reads=0,capture_stack_writes=0;
initial $readmemh("build/das12_profile/fw/function_tags.hex",function_tags);
`endif
always @(posedge clk) if(rst) begin
if(dut.u_pdm_cap.capture_q)prof_active=1;
if(prof_active)begin
 mem_phase=dut.u_dtcm.memory['haf0];
 if(mem_phase>=0 && mem_phase<10)begin
  phase_total[mem_phase]=phase_total[mem_phase]+1;
  if(dut.retire_valid_o)phase_retired[mem_phase]=phase_retired[mem_phase]+1;
  if(dut.u_core.memory_stall && dut.dmem_addr!=32'h2bc0)begin
   phase_lsu[mem_phase]=phase_lsu[mem_phase]+1;
   if(dut.dmem_mmio)phase_mmio[mem_phase]=phase_mmio[mem_phase]+1;
   else if(dut.scratch_sel)phase_scratch[mem_phase]=phase_scratch[mem_phase]+1;
   else phase_dtcm[mem_phase]=phase_dtcm[mem_phase]+1;
  end
 end
prof_total=prof_total+1;prof_pc=dut.u_core.idex_pc;
`ifdef LIVE12_PROFILE
if(prof_pc<16384 && function_tags[prof_pc>>2]==1)begin
  capture_ex=capture_ex+1;
  if(dut.u_core.memory_stall)capture_memory=capture_memory+1;
  if(dut.u_core.load_use_stall)capture_load_use=capture_load_use+1;
  if(dut.dmem_req&&dut.dmem_ready&&dut.dmem_addr>=32'h3c00&&dut.dmem_addr<32'h4000)begin
    if(dut.dmem_write)capture_stack_writes=capture_stack_writes+1;else capture_stack_reads=capture_stack_reads+1;
  end
end
if(dut.retire_valid_o&&dut.retire_pc_o<16384&&function_tags[dut.retire_pc_o>>2]==1)capture_retired=capture_retired+1;
`endif
if(dut.u_core.memory_stall)prof_memory=prof_memory+1;
else if(dut.u_core.fft_stall)prof_fft=prof_fft+1;
else if(dut.u_core.div_stall)prof_div=prof_div+1;
else if(dut.u_core.vec_stall)prof_vec=prof_vec+1;
else if(dut.u_core.acou_stall)prof_acou=prof_acou+1;
else if(dut.u_core.load_use_stall)prof_load=prof_load+1;
else prof_other=prof_other+1;
if(dut.retire_valid_o)prof_retired=prof_retired+1;
if(dut.u_srp.u_scan.busy_o)prof_srp=prof_srp+1;
if(dut.u_core.audio_own)prof_audio=prof_audio+1;
if(dut.u_core.u_fft_bfly.io_fire)prof_fft_io=prof_fft_io+1;
if(dut.u_core.u_acoustic_ext.io_fire)prof_xsp_io=prof_xsp_io+1;
if(dut.dmem_req&&dut.dmem_ready)begin
if(dut.dmem_write&&dut.dmem_addr==32'hc01c)prof_capindices=prof_capindices+1;
if(!dut.dmem_write&&dut.dmem_addr==32'hc020)prof_capreads=prof_capreads+1;
if(dut.scratch_sel)begin if(dut.dmem_write)prof_scratch_writes=prof_scratch_writes+1;else prof_scratch_reads=prof_scratch_reads+1;end
end
if(prof_pc>=0&&prof_pc<40)prof_fn_0=prof_fn_0+1;
if(prof_pc>=40&&prof_pc<256)prof_fn_1=prof_fn_1+1;
if(prof_pc>=256&&prof_pc<776)prof_fn_2=prof_fn_2+1;
if(prof_pc>=776&&prof_pc<1536)prof_fn_3=prof_fn_3+1;
if(dut.u_dtcm.memory['ha00+1]>prof_frame)begin
prof_frame=dut.u_dtcm.memory['ha00+1];
`ifdef LIVE12_NUMERIC66
for(stage_k=0;stage_k<60;stage_k=stage_k+1)
  if(dut.u_dtcm.memory['ha00+8+stage_k]!==test_stats[(prof_frame-1)*60+stage_k])$fatal(1,"raw statistics mismatch frame=%0d word=%0d",prof_frame,stage_k);
`endif
`ifdef LIVE12_PROFILE
stage_capture=0;stage_prepare=0;stage_push=0;stage_run=0;stage_pop=0;
for(stage_k=0;stage_k<12;stage_k=stage_k+1)begin
  stage_capture=stage_capture+dut.u_dtcm.memory['ha00+134+5*stage_k];
  stage_prepare=stage_prepare+dut.u_dtcm.memory['ha00+135+5*stage_k];
  stage_push=stage_push+dut.u_dtcm.memory['ha00+136+5*stage_k];
  stage_run=stage_run+dut.u_dtcm.memory['ha00+137+5*stage_k];
  stage_pop=stage_pop+dut.u_dtcm.memory['ha00+138+5*stage_k];
end
if(stage_capture+stage_prepare+stage_push+stage_run+stage_pop>dut.u_dtcm.memory['ha00+4] || dut.u_dtcm.memory['ha00+4]>dut.u_dtcm.memory['ha00+5])$fatal(1,"cycle accounting mismatch");
$display("FRAME_TIMING frame=%0d capture=%0d prepare=%0d push=%0d run=%0d pop=%0d compute=%0d total=%0d first=%0d interval=%0d audio_max=%0d",
 prof_frame,stage_capture,stage_prepare,stage_push,stage_run,stage_pop,dut.u_dtcm.memory['ha00+4],dut.u_dtcm.memory['ha00+5],
 dut.u_dtcm.memory['ha00+93],previous_first<0?0:dut.u_dtcm.memory['ha00+93]-previous_first,dut.u_beam.max_ticks);
previous_first=dut.u_dtcm.memory['ha00+93];
$display("FRAME_PROTOCOL frame=%0d ready=%0d seq0=%0d seq1=%0d first0=%0d first1=%0d ackseq=%0d ack_errors=%0d capture_drops=%0d audio_samples=%0d direction_updates=0 release=CTRL_RESET",
 prof_frame,dut.u_pdm_cap.ready_q,dut.u_pdm_cap.seq0_q,dut.u_pdm_cap.seq1_q,dut.u_pdm_cap.first0_q,dut.u_pdm_cap.first1_q,dut.u_pdm_cap.ack_seq_q,
 dut.u_pdm_cap.ack_errors_q,dut.u_pdm_cap.dropped_q,n);
if(dut.u_dtcm.memory['ha00+230]===1)begin
 $display("DETAIL_CAPTURE frame=%0d mmio=%0d unpack=%0d store=%0d stats=%0d",prof_frame,dut.u_dtcm.memory['ha00+226],dut.u_dtcm.memory['ha00+227],dut.u_dtcm.memory['ha00+228],dut.u_dtcm.memory['ha00+229]);
 $display("DETAIL_PREPARE frame=%0d dc=%0d peak=%0d scale_select=%0d scale_store=%0d hann=%0d",prof_frame,dut.u_dtcm.memory['ha00+220],dut.u_dtcm.memory['ha00+221],dut.u_dtcm.memory['ha00+222],dut.u_dtcm.memory['ha00+223],dut.u_dtcm.memory['ha00+224]);
end
$display("CAPTURE_RESIDENCY frame=%0d ex_cycles=%0d memory_stall_overlap=%0d load_use_overlap=%0d retired=%0d stack_reads=%0d stack_writes=%0d",prof_frame,capture_ex,capture_memory,capture_load_use,capture_retired,capture_stack_reads,capture_stack_writes);
capture_ex=0;capture_memory=0;capture_load_use=0;capture_retired=0;capture_stack_reads=0;capture_stack_writes=0;
`endif
$display("SYSTEM_PROFILE channels=12 frame=%0d total=%0d memory=%0d fft=%0d div=%0d vec=%0d acou=%0d load=%0d other=%0d retired=%0d srp_overlap=%0d audio_overlap=%0d fft_io=%0d acou_io=%0d cap_reads=%0d cap_indices=%0d scratch_reads=%0d scratch_writes=%0d",prof_frame,prof_total,prof_memory,prof_fft,prof_div,prof_vec,prof_acou,prof_load,prof_other,prof_retired,prof_srp,prof_audio,prof_fft_io,prof_xsp_io,prof_capreads,prof_capindices,prof_scratch_reads,prof_scratch_writes);
// Function classification comes from this ELF's objdump, not old hard-coded PC ranges.
for(mem_k=0;mem_k<10;mem_k=mem_k+1)begin
 if(phase_total[mem_k]>0)$display("MEM_STAGE frame=%0d phase=%0d total=%0d mmio_wait=%0d dtcm_wait=%0d scratch_wait=%0d lsu=%0d retired=%0d",prof_frame,mem_k,phase_total[mem_k],phase_mmio[mem_k],phase_dtcm[mem_k],phase_scratch[mem_k],phase_lsu[mem_k],phase_retired[mem_k]);
 phase_total[mem_k]=0;phase_mmio[mem_k]=0;phase_dtcm[mem_k]=0;phase_scratch[mem_k]=0;phase_lsu[mem_k]=0;phase_retired[mem_k]=0;
end
prof_total=0;prof_memory=0;prof_fft=0;prof_div=0;prof_vec=0;prof_acou=0;prof_load=0;prof_other=0;
prof_retired=0;prof_srp=0;prof_audio=0;prof_fft_io=0;prof_xsp_io=0;
prof_capreads=0;prof_capindices=0;prof_scratch_reads=0;prof_scratch_writes=0;
end end end

always @(posedge clk)if(rst)begin
// Check published capture data, not unused callee-saved registers restored from stack.
if(dut.dmem_req&&dut.dmem_ready&&!dut.dmem_write&&dut.dmem_addr==32'hc020&&(^dut.dmem_rdata===1'bx))$fatal(1,"unknown capture load pc=%h index=%d ready=%h",dut.u_core.idex_pc,dut.u_pdm_cap.rd_index_q,dut.u_pdm_cap.ready_q);
if(dut.retire_valid_o&&(^dut.retire_instr_o===1'bx))$fatal(1,"unknown instruction pc=%h",dut.retire_pc_o);
end
endmodule
