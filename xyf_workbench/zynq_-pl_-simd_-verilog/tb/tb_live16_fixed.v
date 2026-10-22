`timescale 1ns/1ps
module tb_live16_fixed;
  reg clk=0;always #5 clk=~clk;
  reg reset_n=0;
  reg [383:0] pcm=0;reg valid=0;
  reg cfg_wr=0,cfg_rd=0;reg [6:0] cfg_addr=0;reg [31:0] cfg_data=0;
  wire [31:0] cfg_result;
  reg coef_we=0;reg [8:0] coef_idx=0;reg [15:0] coef_data=0;
  wire [3:0] fault;
  rv32_soc #(.DAS_ACTIVE_CHANNELS(16),.LIVE16_LOCALIZATION(0),
    .ITCM_FILE("build/das16/fw/itcm.hex"),.DTCM_FILE("build/das16/fw/dtcm.hex")) dut(
    .clk_i(clk),.rst_n_i(reset_n),.halt_i(1'b0),.test_en_i(1'b0),.fromhost_i(32'b0),
    .retire_fault_o(fault),.ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),
    .ps_addr_i(32'b0),.ps_wdata_i(32'b0),.tacho_i(1'b0),.pdm_din_i(8'b0),
    .coef_we_i(coef_we),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),
    .coef_idx_i(coef_idx),.coef_wdata_i(coef_data),
    .pdm_cfg_wr_i(cfg_wr),.pdm_cfg_rd_i(cfg_rd),.pdm_cfg_addr_i(cfg_addr),
    .pdm_cfg_wdata_i(cfg_data),.pdm_cfg_rdata_o(cfg_result),
    .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
    .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
    .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
  integer ch,n,k,checked=0;reg [31:0] word;
  task write_cfg;
    input [6:0] addr;input [31:0] data;
    begin @(negedge clk);cfg_addr=addr;cfg_data=data;cfg_wr=1;
      @(negedge clk);cfg_wr=0;end
  endtask
  initial begin
    force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=valid;
    repeat(4)@(negedge clk);reset_n=1;
    for(k=0;k<32;k=k+1)begin
      @(negedge clk);coef_we=1;coef_idx=k;coef_data=k==0?32767:0;
    end
    @(negedge clk);coef_we=0;
    write_cfg(32,1);
    cfg_addr=48;#1;if(cfg_result!==16)$fatal(1,"active count not sixteen");
    for(ch=0;ch<16;ch=ch+1)pcm[ch*24 +: 24]=(ch+1)*1024*256;
    for(n=0;n<1200;n=n+1)begin
      @(negedge clk);valid=1;@(negedge clk);valid=0;
      repeat(180)@(negedge clk);
      cfg_addr=35;cfg_rd=1;#1;word=cfg_result;
      if($signed(word[15:0])!==8704 || $signed(word[31:16])!==8703)
        $fatal(1,"DAS/FIR mismatch n=%0d word=%h",n,word);
      @(negedge clk);cfg_rd=0;checked=checked+1;
      repeat(841)@(negedge clk);
    end
    k=0;
    while(dut.u_dtcm.memory['ha00+89]!==32'h4d493136 && k<2000000)begin
      @(negedge clk);k=k+1;
    end
    if(k==2000000)$fatal(1,"snapshot timeout magic=%h error=%h seq=%h pc=%h ready=%h",
      dut.u_dtcm.memory['ha00],dut.u_dtcm.memory['ha00+3],dut.u_dtcm.memory['ha00+88],dut.retire_pc_o,dut.u_pdm_cap.ready_q);
    if(dut.u_dtcm.memory['ha00+3]!==0)$fatal(1,"firmware capture error");
    for(ch=0;ch<16;ch=ch+1)begin
      if(dut.u_dtcm.memory['ha00+8+ch*5]!==((ch+1)*1024*1024))
        $fatal(1,"channel sum/packing mismatch ch=%0d",ch);
      if(dut.u_dtcm.memory['ha00+11+ch*5]!==((ch+1)*1024))
        $fatal(1,"channel peak mismatch ch=%0d",ch);
    end
    cfg_addr=36;#1;if(cfg_result!==0)$fatal(1,"audio drops");
    $display("LIVE16_FIXED_SOC_PASS samples=%0d firmware_channels=16 drops=0",checked);$finish;
  end
  always @(posedge clk)if(reset_n && fault!=0)$fatal(1,"RV32 fault %h",fault);
  initial begin #40000000;$fatal(1,"timeout");end
endmodule
