`timescale 1ns/1ps
// Actual PS AXI decode and SoC, with scaled startup and bank length for runtime.
module tb_pdm_ps_firstframe;
  reg clk=0,rst=0;
  always #12.5 clk=~clk;
  reg [11:0] awaddr=0,araddr=0;
  reg awvalid=0,wvalid=0,bready=0,arvalid=0,rready=0;
  reg [31:0] wdata=0;
  wire awready,wready,bvalid,arready,rvalid;
  wire [1:0] bresp,rresp;
  wire [31:0] rdata;
  wire pclk;
  tri0 [5:0] data;
  rv32_ps_top dut(.clk_i(clk),.rst_n_i(rst),
    .s_axi_awaddr(awaddr),.s_axi_awvalid(awvalid),.s_axi_awready(awready),
    .s_axi_wdata(wdata),.s_axi_wstrb(4'hf),.s_axi_wvalid(wvalid),.s_axi_wready(wready),
    .s_axi_bresp(bresp),.s_axi_bvalid(bvalid),.s_axi_bready(bready),
    .s_axi_araddr(araddr),.s_axi_arvalid(arvalid),.s_axi_arready(arready),
    .s_axi_rdata(rdata),.s_axi_rresp(rresp),.s_axi_rvalid(rvalid),.s_axi_rready(rready),
    .pdm_clk_o(pclk),.pdm_din_i(data),.tacho_i(1'b0),.gsc_ready_i(1'b1));
  defparam dut.u_soc.u_pdm_rx.MIC_STARTUP_CYCLES=4096;
  // Bank length is a real AXI setting; RAM capacity remains production 512.
  genvar k;
  generate for(k=0;k<6;k=k+1)begin:mic
    pdm_shared_mic_model #(.SEED(32'h1927ad03+k*107)) a(
      .clk(pclk),.rst(dut.soc_rst_n),.en(dut.u_soc.pdm_en),.lr(1'b0),.absent(1'b0),
      .dd(32'd40),.dv(32'd116),.hz(32'd30),.pattern(3'd0),.data(data[k]),.source_bit());
    pdm_shared_mic_model #(.SEED(32'h830bdfe1+k*311)) b(
      .clk(pclk),.rst(dut.soc_rst_n),.en(dut.u_soc.pdm_en),.lr(1'b1),.absent(1'b0),
      .dd(32'd40),.dv(32'd116),.hz(32'd30),.pattern(3'd0),.data(data[k]),.source_bit());
  end endgenerate
  integer raw_groups=0,aligned_groups=0,cycle=0,last_raw=0,first_cycle=0,epochs=0,word_checks=0;
  reg [31:0] expected[0:383];
  always @(posedge clk)begin
    if(!dut.soc_rst_n || !dut.u_soc.pdm_en)begin raw_groups=0;aligned_groups=0;cycle=0;last_raw=0;end
    else begin
      cycle=cycle+1;
      if(dut.u_soc.pdm_valid_raw)begin
        if(dut.u_soc.pdm_frame_cnt!==raw_groups)$fatal(1,"RAW_FRAME_ID");
        if(raw_groups && cycle-last_raw!=1024)$fatal(1,"RAW_RATE");
        if(!raw_groups)begin
          if(cycle<4096+4096)$fatal(1,"EARLY_FIRST_FRAME");
          if(first_cycle==0)first_cycle=cycle;
          else if(first_cycle!=cycle)$fatal(1,"FIRST_FRAME_RESTART_SKEW");
        end
        last_raw=cycle;raw_groups=raw_groups+1;
      end
      if(dut.u_soc.pdm_valid_aligned)begin
        if(dut.u_soc.pdm_frame_cnt!==aligned_groups+1)$fatal(1,"ALIGNED_FRAME_ID");
        if(aligned_groups<64)for(integer c=0;c<6;c=c+1)
          expected[aligned_groups*6+c]={dut.u_soc.pdm_aligned[c*48+32+:16],dut.u_soc.pdm_aligned[c*48+8+:16]};
        aligned_groups=aligned_groups+1;
      end
    end
  end
  task write_axi;
    input [11:0] address;input [31:0] value;
    integer guard;reg got_aw,got_w;
    begin
      @(negedge clk);awaddr=address;wdata=value;awvalid=1;wvalid=1;bready=1;got_aw=0;got_w=0;guard=0;
      while(!got_aw || !got_w)begin
        @(posedge clk);if(awready)got_aw=1;if(wready)got_w=1;
        @(negedge clk);if(got_aw)awvalid=0;if(got_w)wvalid=0;
        guard=guard+1;if(guard>80)$fatal(1,"AXI_WRITE_TIMEOUT");
      end
      @(posedge clk);
      while(!bvalid)begin @(posedge clk);guard=guard+1;if(guard>80)$fatal(1,"AXI_B_TIMEOUT");end
      if(bresp!==0)$fatal(1,"AXI_BRESP");
      @(negedge clk);bready=0;
    end
  endtask
  task read_axi;
    input [11:0] address;output [31:0] value;
    integer guard;
    begin
      @(negedge clk);araddr=address;arvalid=1;rready=1;guard=0;
      @(posedge clk);
      while(!arready)begin @(posedge clk);guard=guard+1;if(guard>80)$fatal(1,"AXI_AR_TIMEOUT");end
      @(negedge clk);arvalid=0;
      @(posedge clk);
      while(!rvalid)begin @(posedge clk);guard=guard+1;if(guard>80)$fatal(1,"AXI_R_TIMEOUT");end
      value=rdata;if(rresp!==0)$fatal(1,"AXI_RRESP");
      @(negedge clk);rready=0;
    end
  endtask
  integer epoch,poll,word_index;
  reg [31:0] value;
  initial begin
    repeat(10)@(negedge clk);#1;rst=1;
    for(epoch=0;epoch<3;epoch=epoch+1)begin
      if(epoch==1)begin write_axi(12'h300,0);repeat(24)@(negedge clk);end
      if(epoch==2)begin write_axi(12'h000,32'h10);repeat(24)@(negedge clk);end
      read_axi(12'h32c,value);if(value!==0)$fatal(1,"FRAME_NOT_RESET");
      write_axi(12'h308,16);write_axi(12'h300,3);
      repeat(1000)@(negedge clk);
      read_axi(12'h32c,value);if(value!==0)$fatal(1,"FRAME_DURING_STARTUP");
      value=0;poll=0;
      while(!value[0] && poll<10000)begin read_axi(12'h304,value);poll=poll+1;end
      if(!value[0])$fatal(1,"FIRST_BANK_TIMEOUT");
      write_axi(12'h30c,0);
      read_axi(12'h310,value);if(value!==0)$fatal(1,"BANK_SEQ");
      read_axi(12'h314,value);if(value!==1)$fatal(1,"BANK_FIRST");
      read_axi(12'h334,value);if(value!==16)$fatal(1,"BANK_META");
      for(word_index=0;word_index<96;word_index=word_index+1)begin
        write_axi(12'h31c,word_index);
        read_axi(12'h320,value);
        if(value!==expected[word_index])$fatal(1,"AXI_PCM_WORD epoch=%0d word=%0d got=%h want=%h",epoch,word_index,value,expected[word_index]);
        word_checks=word_checks+1;
      end
      write_axi(12'h324,0);write_axi(12'h328,1);
      read_axi(12'h304,value);if(value[0]!==0)$fatal(1,"BANK_RELEASE");
      epochs=epochs+1;
      $display("FIRST_FRAME_EPOCH_PASS epoch=%0d first_raw_cycle=%0d raw_id=0 aligned_id=1 bank_FIRST=1 SEQ=0 words=96",epoch,first_cycle);
    end
    $display("PDM_PS_FIRSTFRAME_PASS epochs=%0d words=%0d",epochs,word_checks);$finish;
  end
  initial begin #10000000;$fatal(1,"TIMEOUT");end
endmodule
