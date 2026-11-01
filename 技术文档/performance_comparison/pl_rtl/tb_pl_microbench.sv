`timescale 1ns/1ps
module tb_pl_microbench;
  reg clk=0; always #12.5 clk=~clk;
  reg rst=0,cw=0,hold_cpu=0;reg [8:0] ci=0;reg [15:0] cd=0;
  wire [3:0] fault;string fw,dump;
  reg [15:0] coefficients[0:31];
  longint tick=0,fft_start_tick=0;integer vfft=0,vpush=0,vred=0;
  reg [31:0] fir_trace_pc=0,last_ck=0;
  reg signed [31:0] fir_y[0:1023];
  integer fir_points=0,fir_mismatches=0;
  rv32_soc #(.DAS_ACTIVE_CHANNELS(9)) dut(
    .clk_i(clk),.rst_n_i(rst),.halt_i(hold_cpu),.test_en_i(1'b0),.fromhost_i(32'b0),
    .retire_fault_o(fault),.gsc_ready_i(1'b1),.ps_req_i(1'b0),.ps_write_i(1'b0),
    .ps_sel_i(1'b0),.ps_addr_i(32'b0),.ps_wdata_i(32'b0),.tacho_i(1'b0),.pdm_din_i(5'b0),
    .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b0),.coef_idx_i(ci),.coef_wdata_i(cd),
    .pdm_cfg_wr_i(1'b0),.pdm_cfg_rd_i(1'b0),.pdm_cfg_addr_i(7'b0),.pdm_cfg_wdata_i(32'b0),
    .srp_cfg_wr_i(1'b0),.srp_cfg_rd_i(1'b0),.srp_cfg_addr_i(7'b0),.srp_cfg_wdata_i(32'b0),
    .xsp_cfg_wr_i(1'b0),.xsp_cfg_rd_i(1'b0),.xsp_cfg_addr_i(7'b0),.xsp_cfg_wdata_i(32'b0),
    .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(32'b0));
  initial begin
    if(!$value$plusargs("FW=%s",fw)) $fatal(1,"missing FW");
    if(!$value$plusargs("DUMP=%s",dump)) $fatal(1,"missing DUMP");
    if(!$value$plusargs("FIR_TRACE_PC=%h",fir_trace_pc)) $fatal(1,"missing FIR_TRACE_PC");
    #1;$readmemh({fw,"/itcm.hex"},dut.u_itcm.memory);$readmemh({fw,"/dtcm.hex"},dut.u_dtcm.memory);
    $readmemh("../inputs/fir_coeff.hex",coefficients);
    /* Coefficient BRAM writes work during reset; release the CPU only afterwards. */
    repeat(4)@(negedge clk);
    for(integer k=0;k<32;k++)begin @(negedge clk);cw=1;ci=k;cd=coefficients[k];end
    @(negedge clk);cw=0;rst=1;
    wait(dut.u_dtcm.memory['ha00]==32'h50455246);
    @(negedge clk);
    for(integer k=0;k<16;k++)$display("MICRO_RESULT index=%0d value=%0d",k,dut.u_dtcm.memory['ha00+k]);
    $writememh({dump,"/results.hex"},dut.u_dtcm.memory,'ha00,'ha0f);
    $writememh({dump,"/scratch.hex"},dut.g_live16_scratch.u_ram.memory);
    $writememh({dump,"/fir_retired_samples.hex"},fir_y);
    for(integer k=0;k<512;k++)if(fir_y[k]!==fir_y[k+512])fir_mismatches++;
    $display("FIR_POINT_COMPARE samples=%0d mismatches=%0d",fir_points,fir_mismatches);
    $display("MICRO_COUNTS vfft=%0d vpush=%0d vred=%0d",vfft,vpush,vred);
    if(dut.u_dtcm.memory['ha06]||dut.u_dtcm.memory['ha0d])$fatal(1,"bit mismatch FFT/FIR");
    if(dut.u_dtcm.memory['ha09]!==dut.u_dtcm.memory['ha0b]||dut.u_dtcm.memory['ha0a]!==dut.u_dtcm.memory['ha0c])$fatal(1,"FIR fingerprint mismatch");
    if(vfft!=1||vred!=512||fir_points!=1024||fir_mismatches)$fatal(1,"custom operation/point comparison");
    $display("PL_MICROBENCH_PASS tick=%0d",tick);$finish;
  end
  always @(posedge clk)if(rst)begin
    tick=tick+1;
    if(tick%1000000==0)$display("MICRO_PROGRESS tick=%0d pc=%h res=%h halt=%0d",tick,dut.u_core.idex_pc,dut.u_dtcm.memory['ha00],hold_cpu);
    if(dut.retire_valid_o&&fault)$fatal(1,"CPU fault pc=%h code=%0d",dut.retire_pc_o,fault);
    if(dut.retire_valid_o&&dut.retire_pc_o==fir_trace_pc&&dut.retire_instr_o!==32'h00f80833)
      $display("MICRO_PC_TAG pc=%h expected_instr=00f80833 actual_instr=%h",dut.retire_pc_o,dut.retire_instr_o);
    if(dut.retire_valid_o&&dut.retire_instr_o==32'h00f80833)begin
      if(fir_points==512)last_ck=0;
      fir_y[fir_points]=$signed(dut.u_core.wb_write_data-last_ck);
      last_ck=dut.u_core.wb_write_data;fir_points++;
    end
    if(dut.retire_valid_o&&dut.retire_instr_o[6:0]==7'h0b)begin
      if(dut.retire_instr_o[14:12]==7&&dut.retire_instr_o[31:25]==7'h50)vfft++;
      if(dut.retire_instr_o[14:12]==0)vpush++;
      if(dut.retire_instr_o[14:12]==1)vred++;
    end
    if(dut.u_core.u_fft_bfly.run_start)fft_start_tick=tick;
    if(dut.u_core.u_fft_bfly.done_o&&fft_start_tick!=0)begin
      $display("MICRO_FFT_ENGINE cycles=%0d",tick-fft_start_tick);fft_start_tick=0;
    end
  end
  initial begin #125000000;$fatal(1,"micro timeout");end
endmodule
