`timescale 1ns/1ps
module tb_acoustic_instruction_core;
  parameter LANES=4;
  reg clk=0;always #5 clk=~clk;reg rst=0;wire [3:0] fault;integer cycles=0;
  rv32_soc #(.ACOU_LANES(LANES),.ITCM_FILE("build/system_optimization/instruction_fw/itcm.hex"),
    .DTCM_FILE("build/system_optimization/instruction_fw/dtcm.hex")) dut(
    .clk_i(clk),.rst_n_i(rst),.halt_i(1'b0),.test_en_i(1'b0),.fromhost_i(32'b0),
    .retire_fault_o(fault),.ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),
    .tacho_i(1'b0),.pdm_din_i(8'b0),.coef_we_i(1'b0),.coef_re_i(1'b0),.coef_src_i(1'b0),
    .coef_ch_i(1'b0),.coef_idx_i(9'b0),.coef_wdata_i(16'b0),
    .pdm_cfg_wr_i(1'b0),.pdm_cfg_rd_i(1'b0),.pdm_cfg_addr_i(7'b0),.pdm_cfg_wdata_i(32'b0),
    .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
    .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
    .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
  initial begin repeat(4)@(negedge clk);rst=1;end
  always @(posedge clk)if(rst)begin
    cycles=cycles+1;
    if(fault!=0)$fatal(1,"acoustic instruction fault");
    if(dut.u_dtcm.memory['ha00]===32'hac100002)begin
      if(dut.u_dtcm.memory['ha00+1]!==1||dut.u_dtcm.memory['ha00+2]!==32'h0000ff00||
         dut.u_dtcm.memory['ha00+3]!==15888||dut.u_dtcm.memory['ha00+4]!==32'h0000c1f0)
        $fatal(1,"custom acoustic instruction numerical/IO mismatch %h %h %h %h",
          dut.u_dtcm.memory['ha00+1],dut.u_dtcm.memory['ha00+2],dut.u_dtcm.memory['ha00+3],dut.u_dtcm.memory['ha00+4]);
      $display("ACOUSTIC_INSTRUCTION_CORE_PASS lanes=%0d kernel_and_io_cycles=%0d total=%0d",LANES,dut.u_dtcm.memory['ha00+5],cycles);$finish;
    end
    if(cycles>100000)$fatal(1,"custom acoustic instruction timeout");
  end
endmodule
