`timescale 1ns/1ps
// Actual 40 MHz clock, 2.5 MHz PDM wire transitions and ten shared wire slots.
module tb_pdm_decim_rate;
  parameter DECIM=16;
  reg clk=0,rst=0,en=0;
  always #12.5 clk=~clk;
  reg [4:0] data=0;
  reg [9:0] stimulus[0:65535];
  wire pclk,valid;
  wire [239:0] pcm;
  wire [31:0] frame;
  wire [9:0] frozen;
  integer index=0,cycles=0,consumed=0,outputs=0,last_pcm=0;
  integer stream,edge_checks=0;
  realtime last_edge=0;
  reg [1023:0] input_path,output_path;
  reg [9:0] sampled;
  rv32_pdm_array_rx #(.N_CH(10),.ACTIVE_MASK(10'h1ff),.DECIM(DECIM),
    .MIC_STARTUP_CYCLES(4096),.CIC_SETTLE_FRAMES(4)) dut(
    .clk_i(clk),.rst_n_i(rst),.en_i(en),.pdm_din_i(data),
    .pdm_clk_o(pclk),.audio_vec_o(pcm),.sample_valid_o(valid),
    .frame_cnt_o(frame),.frozen_o(frozen));
  always @(posedge pclk) if(rst&&en)begin
    #116;
    for(integer k=0;k<5;k=k+1)data[k]=stimulus[index&65535][2*k+1];
  end
  always @(negedge pclk) if(rst&&en)begin
    index=index+1;
    #116;
    for(integer k=0;k<5;k=k+1)data[k]=stimulus[index&65535][2*k];
  end
  always @(pclk)if(rst&&en)begin
    if(last_edge && $realtime-last_edge!=200.0)$fatal(1,"PDM period changed");
    if(last_edge)edge_checks=edge_checks+1;
    last_edge=$realtime;
  end
  always @(posedge clk)begin
    cycles=cycles+1;
    if(rst&&en&&dut.cic_bit_en)begin
      for(integer k=0;k<5;k=k+1)begin
        sampled[2*k]=dut.phase_a_q[k];sampled[2*k+1]=data[k];
      end
      if(sampled!==stimulus[index&65535])$fatal(1,"Shared pin capture mismatch");
      $fdisplay(stream,"BIT %0d %0d %03x",cycles,dut.decim_en_w,sampled);
      consumed=consumed+1;
    end
  end
  always @(negedge clk)if(rst&&en)begin
    if(&dut.ch_valid_w)$fdisplay(stream,"RAW %0d %0d %0d %060x",cycles,valid,frame,pcm);
    if(valid)begin
      if(last_pcm && cycles-last_pcm!=16*DECIM)$fatal(1,"PCM cadence");
      if(pcm[239:216]!==0||frozen[9]!==0)$fatal(1,"Unused slot mask");
      last_pcm=cycles;outputs=outputs+1;
      if(outputs==1024)begin
        $fclose(stream);
        $display("PDM_DECIM_PASS decim=%0d pcm_cycles=%0d outputs=%0d consumed=%0d edges=%0d",DECIM,16*DECIM,outputs,consumed,edge_checks);
        $finish;
      end
    end
  end
  initial begin
    if(!$value$plusargs("INPUT=%s",input_path)||!$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"paths required");
    $readmemh(input_path,stimulus);stream=$fopen(output_path,"w");
    if(!stream)$fatal(1,"trace file");
    repeat(5)@(negedge clk);
    rst=1;en=1;
    for(integer k=0;k<5;k=k+1)data[k]=stimulus[0][2*k];
    repeat(1200000)@(posedge clk);
    $fatal(1,"timeout");
  end
endmodule
