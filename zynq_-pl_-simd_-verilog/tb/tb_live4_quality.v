`timescale 1ns/1ps
module tb_live4_quality;
 reg clk=0;always #5 clk=~clk;
 reg rst=0;reg [383:0] pcm=0;reg valid=0;reg [31:0] number=0;
 reg wr=0,rd=0;reg [6:0] addr=0;reg [31:0] data=0;wire [31:0] result;
 reg cw=0;reg [8:0] ci=0;reg [15:0] cd=0;wire [3:0] fault;
 rv32_soc #(.DAS_ACTIVE_CHANNELS(4),.ITCM_FILE("build/das4/fw/itcm.hex"),.DTCM_FILE("build/das4/fw/dtcm.hex")) dut(
 .clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),.fromhost_i(32'b0),.retire_fault_o(fault),
 .ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
 .tacho_i(1'b0),.pdm_din_i(8'b0),.coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
 .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd),.pdm_cfg_addr_i(addr),.pdm_cfg_wdata_i(data),.pdm_cfg_rdata_o(result),
 .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
 .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
 .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
 reg [15:0] scene[0:4095];reg [31:0] lut[0:2047];
 reg signed [15:0] history[0:255];reg [255:0] wanted,held;
 integer n=0,ch,k,d,f,v0,v1,total,expected,value,minimum,base,last_frame=0,mode=0;
 reg auto_delay;reg [255:0] applied=0;reg [31:0] word;integer tau[0:7];
 task wc;input [6:0] a;input [31:0] v;
 begin @(negedge clk);addr=a;data=v;wr=1;@(negedge clk);wr=0;end endtask
 task sample;
 begin
  for(ch=0;ch<4;ch=ch+1)begin
   value=mode==1?10000:$signed(scene[(n%1024)*4+ch]);
   pcm[ch*24+:24]={value[15:0],8'b0};history[ch*64+n%64]=value;
  end
  @(negedge clk);number=n;valid=1;
  auto_delay=dut.beam_locked&&!dut.steer_busy;
  // DAS keeps its last accepted steering snapshot while the next update is busy.
  if(auto_delay)applied=dut.beam_comp;
  total=0;
  for(ch=0;ch<4;ch=ch+1)begin
   d=applied[ch*32+:32]>>16;
   f=(applied[ch*32+:32]>>12)&15;
   v0=n>=d?history[ch*64+((n-d)&63)]:0;
   v1=n>d?history[ch*64+((n-d-1)&63)]:0;
   total=total+v0+(((v1-v0)*f)>>>4);
  end
  expected=(total+2)>>>2;
  @(negedge clk);valid=0;
  repeat(180)@(negedge clk);addr=35;rd=1;#1;word=result;
  if($signed(word[15:0])!==expected||$signed(word[31:16])!==((expected*32767)>>>15))
   $fatal(1,"four mic audio mismatch sample=%0d mode=%0d",n,mode);
  @(negedge clk);rd=0;repeat(841)@(negedge clk);n=n+1;
  if(dut.u_dtcm.memory['ha00+3]!==0)$fatal(1,"four mic FW error=%0d",dut.u_dtcm.memory['ha00+3]);
  if(dut.u_dtcm.memory['ha00+30][0]===0&&dut.u_dtcm.memory['ha00+1]!=last_frame)begin
   last_frame=dut.u_dtcm.memory['ha00+1];
   $display("LIVE4_QUALITY_FRAME frame=%0d samples=%0d valid=%0d reason=%0d grid=%0d cycles=%0d",last_frame,n,
    dut.u_dtcm.memory['ha00+31],dut.u_dtcm.memory['ha00+1081],dut.u_dtcm.memory['ha00+2],dut.u_dtcm.memory['ha00+4]);
  end
  if(n%4096==0)$display("LIVE4_QUALITY_PROGRESS samples=%0d phase=%0d frame=%0d",n,mode,last_frame);
 end endtask
 task geometry;
 begin
  minimum=2147483647;
  for(ch=0;ch<8;ch=ch+1)begin
   value=lut[ch*256+dut.u_dtcm.memory['ha00+2]];
   tau[ch]=(value>=8192?value-16384:value)*4096;
   if(tau[ch]<minimum)minimum=tau[ch];
  end
  for(ch=0;ch<8;ch=ch+1)wanted[ch*32+:32]=tau[ch]-minimum;
 end endtask
 initial begin
  $readmemh("build/location_robustness/debug4_pcm.hex",scene);
  $readmemh("build/das4/fw/steer_lut.hex",lut);
  $readmemh("build/das4/fw/steer_lut.hex",dut.u_steer.u_geo.lut_mem);
  force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=number;
  repeat(4)@(negedge clk);rst=1;
  for(k=0;k<32;k=k+1)begin @(negedge clk);cw=1;ci=k;cd=k==0?32767:0;end
  @(negedge clk);cw=0;wc(32,5);
  k=0;while(!dut.u_pdm_cap.capture_q&&k<1000000)begin @(negedge clk);k=k+1;end
  if(k==1000000)$fatal(1,"four mic initialization timeout");
  while(last_frame<9&&n<40000)sample();
  if(last_frame<9||dut.u_dtcm.memory['ha00+31]!==1)$fatal(1,"source not confirmed");
  geometry();
  while((dut.beam_comp!==wanted||!dut.beam_locked||dut.steer_busy)&&n<45000)sample();
  if(dut.beam_comp!==wanted)$fatal(1,"four mic steering geometry did not converge");
  repeat(256)sample();held=dut.beam_comp;
  mode=1;base=last_frame;
  while(last_frame<base+4&&n<60000)sample();
  if(dut.u_dtcm.memory['ha00+31]!==0||!(dut.u_dtcm.memory['ha00+1081]&1))$fatal(1,"DC-only input produced valid location");
  if(dut.beam_comp!==held)$fatal(1,"DC-only input changed steering");
  $display("LIVE4_DC_REJECT_PASS frame=%0d no_steering_change=1",last_frame);
  mode=0;base=last_frame;
  while(last_frame<base+4&&n<80000)sample();
  if(dut.u_dtcm.memory['ha00+31]!==1||dut.u_dtcm.memory['ha00+1081]!==0)$fatal(1,"source reacquisition failed");
  addr=36;#1;if(result!==0)$fatal(1,"four mic audio drops=%0d",result);
  $display("LIVE4_QUALITY_SOC_PASS frames=%0d samples=%0d dc_rejected=1 reacquired=1 drops=0",last_frame,n);$finish;
 end
 always @(posedge clk)if(rst&&fault!=0)$fatal(1,"RV32 fault=%h",fault);
 initial begin #1200000000;$fatal(1,"four mic simulation timeout");end
endmodule
