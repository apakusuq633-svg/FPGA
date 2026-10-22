`timescale 1ns/1ps
// Controller ownership only; full arithmetic and RV32 retirement are checked by the SoC harness.
module tb_localizer12_sessions;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,en=0,valid=0;reg[287:0]pcm=0;reg[31:0]sid=0;
 wire done;wire[31:0]id,first,raw_drop,window_drop;
 rv32_overlap_localizer #(.CPU_SCHEDULED(1),.RESULT_OFFSET(393216)) dut(
 .clk_i(clk),.rst_n_i(rst),.enable_i(en),.valid_i(valid),.pcm_i(pcm),.sample_id_i(sid),
 .done_o(done),.window_id_o(id),.first_o(first),.raw_drop_o(raw_drop),.window_drop_o(window_drop),
 .fft_ready_i(1'b1),.ac_ready_i(1'b1),.fft_done_i(dut.state==7||dut.state==19),
 .fft_result_i(32'b0),.ac_done_i(dut.state==12||dut.state==14),.ac_result_i(32'b0),
 .srp_done_i(dut.state==25),.srp_busy_i(1'b0),.srp_score_i(32'b0));
 integer cycle=0,produced=0,ch;reg gap=0;reg[31:0]session_first=0;reg arm_first=1;
 reg[31:0]expected_first=0;reg[31:0]reads=0;
 function[15:0]value;input[31:0]s;input integer c;begin value=(s*32'h45d9f3b)^(c*7919)^(s>>7);end endfunction
 always @(negedge clk)begin
  cycle=cycle+1;valid=0;
  if(rst&&cycle%1024==0)begin
   valid=1;sid=produced+gap;
   for(ch=0;ch<12;ch=ch+1)pcm[ch*24+:24]={value(sid,ch),8'b0};
   if(en&&arm_first)begin session_first=sid;expected_first=sid;arm_first=0;end
   produced=produced+1;
  end
  if(done)begin
   if(!en||raw_drop||window_drop)$fatal(1,"SESSION_INVALID_RESULT");
   if(first!=expected_first)$fatal(1,"SESSION_FIRST got=%d expected=%d",first,expected_first);
   expected_first=expected_first+512;
   $display("SESSION_RESULT id=%d first=%d",id,first);
  end
  if(cycle>10000000)$fatal(1,"SESSION_TIMEOUT");
 end
 always @(posedge clk)if(rst&&en&&!raw_drop&&dut.state==2)begin
  if(dut.sample!==value(dut.source_first+dut.active_first+dut.n,dut.channel))$fatal(1,"SESSION_RAW_SEQUENCE");
  reads=reads+1;
 end
 initial begin
  repeat(4)@(posedge clk);#1;rst=1;en=1;
  wait(done);wait(!done);wait(dut.state==2&&dut.channel==5);
  @(posedge clk);#1;en=0;arm_first=1;
  repeat(100)@(posedge clk);
  if(dut.state!=0||done)$fatal(1,"DISABLE_DID_NOT_ABORT");
  #1;en=1;wait(done);wait(!done);
  @(posedge clk);#1;gap=1;wait(raw_drop!=0);
  repeat(16)@(posedge clk);
  #1;en=0;repeat(16)@(posedge clk);#1;en=1;
  repeat(1200000)begin @(posedge clk);if(done)$fatal(1,"REENABLE_CLEARED_STICKY_LOSS");end
  #1;rst=0;en=0;gap=0;arm_first=1;
  repeat(4)@(posedge clk);#1;rst=1;en=1;
  wait(done);if(raw_drop||window_drop)$fatal(1,"RESET_DID_NOT_CLEAR_ERROR");
  $display("LOCALIZER_SESSIONS_PASS disable_abort=1 reenable_warmup=1 sticky_loss=1 reset_recovery=1 raw_reads=%0d",reads);$finish;
 end
endmodule
