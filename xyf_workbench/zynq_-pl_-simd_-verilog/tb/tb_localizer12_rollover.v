`timescale 1ns/1ps
// Scheduling/RAW-only counter-wrap regression; arithmetic engines are handshake stubs.
module tb_localizer12_rollover;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,en=0,valid=0;reg[287:0]pcm=0;reg[31:0]sid=0;
 wire done;wire[31:0]id,first,raw_drop,window_drop;wire[2:0]request;
 rv32_overlap_localizer #(.CPU_SCHEDULED(1),.RESULT_OFFSET(393216)) dut(
 .clk_i(clk),.rst_n_i(rst),.enable_i(en),.valid_i(valid),.pcm_i(pcm),.sample_id_i(sid),
 .done_o(done),.window_id_o(id),.first_o(first),.raw_drop_o(raw_drop),.window_drop_o(window_drop),
 .fft_ready_i(1'b1),.ac_ready_i(1'b1),.fft_done_i(dut.state==7||dut.state==19),
 .fft_result_i(32'b0),.ac_done_i(dut.state==12||dut.state==14),.ac_result_i(32'b0),
 .srp_done_i(dut.state==25),.srp_busy_i(1'b0),.srp_score_i(32'b0),.run_request_o(request));
 integer cycle=0,produced=0,received=0,ch,last_done=0;reg teleported=0,tick_wrapped=0;
 reg[31:0]seq;reg[15:0]expected;
 function[15:0]value;input[31:0]s;input integer c;begin value=(s*32'h45d9f3b)^(c*7919)^(s>>7);end endfunction
 initial begin repeat(4)@(negedge clk);rst=1;en=1;end
 always @(negedge clk)if(rst)begin
  cycle=cycle+1;valid=0;
  if(teleported&&dut.tick<32'h00010000)tick_wrapped=1;
  if(cycle%1024==0)begin
   valid=1;sid=produced;
   for(ch=0;ch<12;ch=ch+1)pcm[ch*24+:24]={value(produced,ch),8'b0};
   produced=produced+1;
  end
  if(done)begin
   received=received+1;
   if(last_done!=0&&cycle-last_done!=524288)$fatal(1,"TICK_WRAP_RESULT_GAP got=%d",cycle-last_done);
   last_done=cycle;
   if(first!=(received-1)*512||id!=received)$fatal(1,"SILENT_WINDOW_JUMP first=%d expected=%d",first,(received-1)*512);
   $display("ROLLOVER_WINDOW id=%0d first=%0d count=%h",received,first,dut.sample_count);
   if(received==6)begin
    if(!tick_wrapped)$fatal(1,"TICK_WRAP_NOT_COVERED");
    $display("LOCALIZER_ROLLOVER_PASS windows=6 raw_sequence_checked=1 tick_wrap=1 fixed_gap=524288");$finish;
   end
  end
  if(received==2&&!teleported&&dut.state==0&&!dut.pending)begin
   dut.sample_count=dut.sample_count+32'hfffff800;
   dut.active_first=dut.active_first+32'hfffff800;
   dut.pending_first=dut.pending_first+32'hfffff800;
   dut.source_first=dut.source_first-32'hfffff800;
   dut.tick=32'hfffc0000;
   teleported=1;$display("ROLLOVER_INJECT count=%h",dut.sample_count);
  end
  if(raw_drop||window_drop)$fatal(1,"ROLLOVER_LOSS raw=%d window=%d",raw_drop,window_drop);
  if(cycle>5000000)$fatal(1,"ROLLOVER_TIMEOUT windows=%d raw_drop=%d window_drop=%d",received,raw_drop,window_drop);
 end
 always @(posedge clk)if(rst&&dut.state==2)begin
  seq=dut.source_first+dut.active_first+dut.n;expected=value(seq,dut.channel);
  if(dut.sample!==expected)$fatal(1,"RAW_SEQUENCE_ERROR seq=%d ch=%d",seq,dut.channel);
 end
endmodule
