`timescale 1ns/1ps
module tb_c9_scalar;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,hold_cpu=1;wire [3:0] fault;
 string fw,dump,scratch;longint tick=0;integer custom_count=0;
 rv32_soc #(.DAS_ACTIVE_CHANNELS(9)) dut(
  .clk_i(clk),.rst_n_i(rst),.halt_i(hold_cpu),.test_en_i(1'b0),.fromhost_i(32'b0),
  .retire_fault_o(fault),.gsc_ready_i(1'b1),.ps_req_i(1'b0),.ps_write_i(1'b0),
  .ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),.tacho_i(1'b0),.pdm_din_i(5'b0),
  .coef_we_i(1'b0),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b0),.coef_idx_i(9'b0),.coef_wdata_i(16'b0),
  .pdm_cfg_wr_i(1'b0),.pdm_cfg_rd_i(1'b0),.pdm_cfg_addr_i(7'b0),.pdm_cfg_wdata_i(32'b0),
  .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
  .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
  .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
 initial begin
  if(!$value$plusargs("FW=%s",fw)||!$value$plusargs("DUMP=%s",dump)||!$value$plusargs("SCRATCH=%s",scratch))$fatal(1,"missing fixture path");
  #1;$readmemh({fw,"/itcm.hex"},dut.u_itcm.memory);$readmemh({fw,"/dtcm.hex"},dut.u_dtcm.memory);
  $readmemh(scratch,dut.g_live16_scratch.u_ram.memory);
  repeat(4)@(negedge clk);rst=1;hold_cpu=0;
  wait(dut.u_dtcm.memory['he00]==32'h43395343);
  @(negedge clk);hold_cpu=1;
  for(integer i=0;i<10;i++)$display("C9_SCALAR_RV_RESULT index=%0d value=%0d",i,dut.u_dtcm.memory['he00+i]);
  $writememh({dump,"/dtcm.hex"},dut.u_dtcm.memory);
  $writememh({dump,"/scratch.hex"},dut.g_live16_scratch.u_ram.memory);
  if(custom_count)$fatal(1,"scalar retired custom instructions");
  $display("C9_SCALAR_RV_PASS tick=%0d custom_instructions=%0d",tick,custom_count);$finish;
 end
 always @(posedge clk)if(rst)begin
  tick=tick+1;
  if(tick%1000000==0)$display("C9_SCALAR_RV_PROGRESS tick=%0d pc=%h",tick,dut.retire_pc_o);
  if(dut.retire_valid_o&&fault)$fatal(1,"CPU fault pc=%h code=%0d",dut.retire_pc_o,fault);
  if(dut.retire_valid_o&&(dut.retire_instr_o[6:0]==7'h0b||dut.retire_instr_o[6:0]==7'h2b))custom_count++;
  if(tick>80000000)$fatal(1,"scalar timeout");
 end
endmodule
