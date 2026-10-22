`timescale 1ns/1ps
module tb_live16_soc;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,halt=0;reg [383:0] pcm=0;reg valid=0;reg [31:0] frame_number=0;
 reg wr=0,rd=0;reg [6:0] addr=0;reg [31:0] data=0;wire [31:0] result;
 reg tw=0;reg [6:0] ta=0;reg [31:0] td=0;wire [31:0] tq;
 reg cw=0;reg [8:0] ci=0;reg [15:0] cd=0;wire [3:0] fault;
 rv32_soc #(.DAS_ACTIVE_CHANNELS(16),.LIVE16_LOCALIZATION(1),
 .ITCM_FILE("build/das16_loc/fw/itcm.hex"),.DTCM_FILE("build/das16_loc/fw/dtcm.hex")) dut(
 .clk_i(clk),.rst_n_i(rst),.halt_i(halt),.test_en_i(1'b0),.fromhost_i(32'b0),
 .retire_fault_o(fault),.ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
 .tacho_i(1'b0),.pdm_din_i(8'b0),.coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
 .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd),.pdm_cfg_addr_i(addr),.pdm_cfg_wdata_i(data),.pdm_cfg_rdata_o(result),
 .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
 .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
 .steer_cfg_wr_i(tw),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(ta),.steer_cfg_wdata_i(td),.steer_cfg_rdata_o(tq));
 reg [15:0] scene[0:16383];reg [31:0] comp[0:15],expected_p[0:1023];
 reg [31:0] expected_fft[0:8207];
 reg signed [15:0] history[0:1023];
 integer n=0,ch,k,d,f,v0,v1,total,expected,checked=0,steered=0;
 integer last_frame=0,settled=0;reg [31:0] word,delay_word;reg [511:0] applied=0;reg use_steer,natural_mode;
 task wc;input [6:0] a;input [31:0] v;
 begin @(negedge clk);addr=a;data=v;wr=1;@(negedge clk);wr=0;end endtask
 task wt;input [6:0] a;input [31:0] v;
 begin @(negedge clk);ta=a;td=v;tw=1;@(negedge clk);tw=0;@(negedge clk);end endtask
 task sample;
 begin
  for(ch=0;ch<16;ch=ch+1)begin
   pcm[ch*24+:24]={scene[(n%1024)*16+ch],8'b0};
   history[ch*64+n%64]=$signed(scene[(n%1024)*16+ch]);
  end
  @(negedge clk);frame_number=n;valid=1;
  use_steer=dut.beam_locked&&!dut.steer_busy;
  if(use_steer)for(ch=0;ch<16;ch=ch+1)
   applied[ch*32+:32]=natural_mode?dut.beam_comp[ch*32+:32]:comp[ch];
  total=0;
  for(ch=0;ch<16;ch=ch+1)begin
   delay_word=applied[ch*32+:32];
   d=delay_word>>16;f=(delay_word>>12)&15;
   v0=n>=d?history[ch*64+((n-d)&63)]:0;
   v1=n>d?history[ch*64+((n-d-1)&63)]:0;
   total=total+v0+(((v1-v0)*f)>>>4);
  end
  expected=(total+8)>>>4;
  @(negedge clk);valid=0;
  repeat(180)@(negedge clk);addr=35;rd=1;#1;word=result;
  if($signed(word[15:0])!==expected)$fatal(1,"DAS mismatch n=%0d auto=%0d got=%0d expected=%0d",n,use_steer,$signed(word[15:0]),expected);
  if($signed(word[31:16])!==((expected*32767)>>>15))$fatal(1,"FIR mismatch n=%0d got=%0d expected=%0d",n,$signed(word[31:16]),((expected*32767)>>>15));
  @(negedge clk);rd=0;repeat(841)@(negedge clk);
  checked=checked+1;if(use_steer)steered=steered+1;n=n+1;
 end endtask
 initial begin
  natural_mode=$test$plusargs("natural");
  $readmemh("build/das16_loc/scene0_pcm.hex",scene);
  $readmemh("build/das16_loc/scene0_comp.hex",comp);
  $readmemh("build/das16_loc/scene0_p.hex",expected_p);
  $readmemh("build/das16_loc/scene0_spectra.hex",expected_fft);
  $readmemh("build/das16_loc/srp_lut.hex",dut.u_srp.u_scan.lut_mem);
  $readmemh("build/das16_loc/steer_lut.hex",dut.u_steer.u_geo.lut_mem);
  force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=frame_number;
  repeat(4)@(negedge clk);rst=1;
  for(k=0;k<32;k=k+1)begin @(negedge clk);cw=1;ci=k;cd=k==0?32767:0;end
  @(negedge clk);cw=0;wc(32,5);
  k=0;while(!dut.u_pdm_cap.capture_q&&k<100000)begin @(negedge clk);k=k+1;end
  if(k==100000)$fatal(1,"FW initialization failed");
  while(dut.u_dtcm.memory['ha00+90]!==2&&n<30000)begin
   sample();
   if($test$plusargs("spectra_only")&&dut.u_dtcm.memory['ha00+88]===2)begin
    halt=1;repeat(16)@(negedge clk);
    $writememh("build/das16_loc/diagnostic_spectra.hex",dut.g_live16_scratch.u_ram.memory,0,8207);
    for(k=0;k<8208;k=k+1)if(dut.g_live16_scratch.u_ram.memory[k]!==expected_fft[k])
     $fatal(1,"FFT cache mismatch word=%0d got=%h expected=%h",k,dut.g_live16_scratch.u_ram.memory[k],expected_fft[k]);
    $display("LIVE16_SPECTRA_PASS words=8208");$finish;
   end
   if(dut.u_dtcm.memory['ha00+3]!==0)$fatal(1,"FW error=%h pc=%h",dut.u_dtcm.memory['ha00+3],dut.retire_pc_o);
   if(n%4096==0)$display("LIVE16_SOC_PROGRESS samples=%0d pc=%h",n,dut.retire_pc_o);
  end
  if(n==30000)$fatal(1,"FW localization timeout");
  halt=1;repeat(16)@(negedge clk);
  if(dut.u_dtcm.memory['ha00+2]!==773||dut.u_dtcm.memory['ha00+91]!==0||
     dut.u_dtcm.memory['ha00+96]!==32'h4c515431||dut.u_dtcm.memory['ha00+97]!==16)
    $fatal(1,"first candidate must wait for confirmation grid=%h valid=%h",dut.u_dtcm.memory['ha00+2],dut.u_dtcm.memory['ha00+91]);
  for(k=0;k<1024;k=k+1)if(dut.u_srp.u_scan.p_mem[k]!==expected_p[k])begin
   $writememh("build/das16_loc/diagnostic_spectra.hex",dut.g_live16_scratch.u_ram.memory,0,8207);
   $writememh("build/das16_loc/diagnostic_r.hex",dut.u_srp.u_scan.r_mem);
   $fatal(1,"FW/RTL golden P mismatch grid=%0d got=%0d expected=%0d",k,dut.u_srp.u_scan.p_mem[k],expected_p[k]);
  end
  $display("LIVE16_SOC_LOCATION_PASS grid=773 compute_cycles=%0d total_cycles=%0d snapshot_first=%0d",
   dut.u_dtcm.memory['ha00+4],dut.u_dtcm.memory['ha00+5],dut.u_dtcm.memory['ha00+93]);
  if(natural_mode)begin
   // Keep the production firmware and its 3/3/64 policy running. No PS target writes.
   halt=0;
   while(settled<256&&n<150000)begin
    sample();
    if(dut.u_dtcm.memory['ha00+3]!==0)$fatal(1,"natural FW error=%h",dut.u_dtcm.memory['ha00+3]);
    if(dut.u_dtcm.memory['ha00+90][0]===0&&dut.u_dtcm.memory['ha00+1]!=last_frame)begin
     last_frame=dut.u_dtcm.memory['ha00+1];
     if(dut.u_dtcm.memory['ha00+2]!==773||dut.u_dtcm.memory['ha00+91]!==(last_frame>1?1:0)||
        dut.u_dtcm.memory['ha00+97]!==(last_frame>1?0:16))
      $fatal(1,"natural frame=%0d grid=%0d valid=%0d",last_frame,dut.u_dtcm.memory['ha00+2],dut.u_dtcm.memory['ha00+91]);
     $display("LIVE16_NATURAL_FRAME frame=%0d samples=%0d compute_cycles=%0d total_cycles=%0d locked=%0d",
      last_frame,n,dut.u_dtcm.memory['ha00+4],dut.u_dtcm.memory['ha00+5],dut.beam_locked);
    end
    if(last_frame>=7&&use_steer&&dut.beam_comp=={comp[15],comp[14],comp[13],comp[12],comp[11],comp[10],comp[9],comp[8],comp[7],comp[6],comp[5],comp[4],comp[3],comp[2],comp[1],comp[0]})settled=settled+1;
    else settled=0;
    if(n%4096==0)$display("LIVE16_NATURAL_PROGRESS samples=%0d frame=%0d",n,last_frame);
   end
   if(settled!=256)$fatal(1,"natural steering did not converge frames=%0d samples=%0d",last_frame,n);
   addr=36;#1;if(result!==0)$fatal(1,"natural dropped audio=%0d",result);
   $display("LIVE16_NATURAL_PASS frames=%0d samples=%0d steered_samples=%0d settled_samples=%0d drops=0",last_frame,checked,steered,settled);
   $finish;
  end
  wt(6,32'h00010100);
  for(k=0;k<5;k=k+1)begin wt(5,773);repeat(160)@(negedge clk);end
  if(!dut.beam_locked)$fatal(1,"steering did not lock");
  for(ch=0;ch<16;ch=ch+1)if(dut.beam_comp[ch*32+:32]!==comp[ch])$fatal(1,"comp mismatch ch=%0d",ch);
  for(k=0;k<256;k=k+1)sample();
  addr=36;#1;if(result!==0)$fatal(1,"dropped audio=%0d",result);
  if(steered!=256)$fatal(1,"auto-steering not used");
  $display("LIVE16_SOC_PASS samples=%0d steered_samples=%0d drops=0 all_1024_scores_match=1",checked,steered);$finish;
 end
 always @(posedge clk)if(rst&&fault!=0)$fatal(1,"RV32 fault=%h",fault);
 initial begin #1800000000;$fatal(1,"simulation timeout");end
endmodule
