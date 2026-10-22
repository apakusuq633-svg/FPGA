`timescale 1ns/1ps
module tb_raw_capture;
`ifdef RAW12
  localparam CHANNELS=12;
`else
  localparam CHANNELS=8;
`endif
  reg clk=0;always #5 clk=~clk;
  reg rst=0,run=0,valid=0;reg [CHANNELS*24-1:0] pcm=0;
  reg [31:0] frame_number=0,command=0;
  reg wr=0,rd=0;reg [6:0] address=0;reg [31:0] data=0;wire [31:0] result;
  reg cw=0;reg [8:0] ci=0;reg [15:0] cd=0;wire [3:0] fault;
  rv32_soc #(.DAS_ACTIVE_CHANNELS(CHANNELS),.PDM_MICS_PER_LINE(2),
`ifdef RAW12
    .LIVE16_LOCALIZATION(1),.ITCM_FILE("build/das12/fw/itcm.hex"),.DTCM_FILE("build/das12/fw/dtcm.hex"))
`else
    .LIVE8_LOCALIZATION(1),.ITCM_FILE("build/das8_loc/fw/itcm.hex"),.DTCM_FILE("build/das8_loc/fw/dtcm.hex"))
`endif
  dut(.clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),.fromhost_i(command),
    .retire_fault_o(fault),.ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
    .tacho_i(1'b0),.pdm_din_i({CHANNELS/2{1'b0}}),.coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),
    .coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(cd),
    .pdm_cfg_wr_i(wr),.pdm_cfg_rd_i(rd),.pdm_cfg_addr_i(address),.pdm_cfg_wdata_i(data),.pdm_cfg_rdata_o(result),
    .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
    .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
    .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
  integer tick=0,n=0,ch,total,expected=0,audio_count=0,k,bank,index,pair,first,wait_count;
  reg [31:0] got,reference;
  function integer source;input integer frame,channel;
    begin source=((frame*97+channel*311)%65536)-32768;end
  endfunction
  always @(negedge clk)if(run)begin
    valid=tick==0;
    if(tick==0)begin
      total=0;frame_number=n;
      for(ch=0;ch<CHANNELS;ch=ch+1)begin pcm[ch*24+:24]=source(n,ch)*256;total=total+source(n,ch);end
      total=total+CHANNELS/2;
      expected=total<0?-((-total+CHANNELS-1)/CHANNELS):total/CHANNELS;n=n+1;
    end
    tick=(tick+1)%1024;
  end
  always @(posedge clk)if(rst)begin
    if(fault!=0)$fatal(1,"raw mode RV32 fault");
    if(run&&dut.beam_fir_valid)begin
      if($signed(dut.beam_fir_sample)!==expected)$fatal(1,"raw mode interrupted DAS");
      audio_count=audio_count+1;
    end
    if(run&&dut.beam_fir_done&&$signed(dut.beam_fir_result)!==((expected*32767)>>>15))
      $fatal(1,"raw mode interrupted FIR");
  end
  task wc;input [6:0] a;input [31:0] value;
    begin @(negedge clk);address=a;data=value;wr=1;@(negedge clk);wr=0;end
  endtask
  task rc;input [6:0] a;
    begin @(negedge clk);address=a;rd=1;#1;got=result;@(negedge clk);rd=0;end
  endtask
  task wait_state;input integer state;
    begin
      wait_count=0;
      while(dut.u_dtcm.memory['ha00+105]!==state&&wait_count<20000)begin
        rc(35);repeat(128)@(negedge clk);wait_count=wait_count+1;
      end
      if(wait_count==20000)$fatal(1,"raw handshake timeout state=%0d",state);
    end
  endtask
  initial begin
    force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;force dut.pdm_frame_cnt=frame_number;
    repeat(4)@(negedge clk);rst=1;
    for(k=0;k<32;k=k+1)begin @(negedge clk);cw=1;ci=k;cd=k==0?32767:0;end
    @(negedge clk);cw=0;wc(32,5);
    while(!dut.u_pdm_cap.capture_q)@(negedge clk);
    command=32'hc1000001;run=1;wait_state(1);
    first=dut.u_dtcm.memory['ha00+106];
    if(dut.u_dtcm.memory['ha00+104]!==command || dut.u_dtcm.memory['ha00+108]!==CHANNELS ||
       dut.u_dtcm.memory['ha00+91]!==0)$fatal(1,"raw ABI or localization pause invalid");
    for(bank=0;bank<2;bank=bank+1)begin
      wc(3,bank);
      for(index=0;index<512*(CHANNELS/2);index=index+1)begin
        wc(7,index);rc(1);rc(8);
        pair=index%(CHANNELS/2);
        reference[15:0]=source(first+bank*512+index/(CHANNELS/2),2*pair);
        reference[31:16]=source(first+bank*512+index/(CHANNELS/2),2*pair+1);
        if(got!==reference)$fatal(1,"raw payload mismatch bank=%0d index=%0d got=%h expected=%h",bank,index,got,reference);
      end
    end
    command=32'hc2000001;wait_state(2);
    // A new request must acquire a fresh snapshot, then allow cancellation.
    command=32'hc1000002;wait_state(1);
    if(dut.u_dtcm.memory['ha00+106]<=first)$fatal(1,"raw snapshot did not advance");
    command=32'hc0000002;wait_state(3);
    rc(36);if(got!==0)$fatal(1,"raw mode dropped audio");
    if(audio_count<2048)$fatal(1,"insufficient continuous audio coverage");
    $display("RAW_CAPTURE_SOC_PASS channels=%0d samples=%0d payload_samples=%0d release=1 cancel=1 audio_drops=0",CHANNELS,audio_count,CHANNELS*1024);
    $finish;
  end
  initial begin #80000000;$fatal(1,"raw SoC timeout");end
endmodule
