`timescale 1ns/1ps
module tb_gsc_timestamp;
 reg clk=0;always #12.5 clk=~clk;reg rst=0,rv=0,bv=0,ready=0,random_ready=0;
 reg[31:0]rs=0,bs=0;reg[191:0]pcm=0;
 wire valid;wire[511:0]data;wire[63:0]stamp;wire[31:0]drops,errors;
 rv32_gsc_tap dut(.clk_i(clk),.rst_n_i(rst),.raw_valid_i(rv),.raw_pcm_i(pcm),.raw_seq_i(rs),
  .beam_valid_i(bv),.beam_seq_i(bs),.beam_i(16'd17),.fir_i(16'd29),
  .direction_version_i(32'd1),.effective_seq_i(32'd0),.window_id_i(32'd1),.group_delay_q16_i(32'd65536),
  .recovery_epoch_i(32'd0),.direction_id_i(10'd3),.trusted_i(1'b1),.transition_i(1'b0),
  .valid_o(valid),.ready_i(ready),.data_o(data),.timestamp_o(stamp),.overflow_o(drops),.alignment_errors_o(errors));
 reg[63:0]cycle=0,raw_time=0,expected_time[0:255];reg[31:0]raw_seq=0,expected_seq[0:255];
 reg pending=0;integer wp=0,rp=0,count=0,expected_drops=0,checked=0,simultaneous=0;
 reg pop,push;
 always @(posedge clk)begin
  if(!rst)begin cycle<=0;raw_time<=0;raw_seq<=0;pending<=0;wp=0;rp=0;count=0;expected_drops=0;end
  else begin
   if(valid!==(count!=0))$fatal(1,"QUEUE_VALID");
   pop=valid&&ready;push=bv&&pending&&bs==raw_seq&&(count<4||pop);
   if(pop)begin
    if(data[63:32]!==expected_seq[rp]||stamp!==expected_time[rp])$fatal(1,"TIMESTAMP_PAIRING");
    if(data[255:224]!==32'h001d0011)$fatal(1,"AUDIO_PAYLOAD_CHANGED");
    rp=rp+1;checked=checked+1;
   end
   if(push)begin expected_seq[wp]=raw_seq;expected_time[wp]=raw_time;wp=wp+1;end
   if(bv&&pending&&bs==raw_seq&&!push)expected_drops=expected_drops+1;
   if(pop&&push)simultaneous=simultaneous+1;
   count=count+(push?1:0)-(pop?1:0);
   if(rv)begin raw_seq<=rs;raw_time<=cycle;pending<=1;end else if(bv)pending<=0;
   cycle<=cycle+1;
  end
 end
 always @(negedge clk)if(random_ready)ready=(cycle%3)!=0;
 task packet;input[31:0]s;begin
  @(negedge clk);rv=1;rs=s;pcm={6{s,16'h1234}};
  @(negedge clk);rv=0;repeat(2)@(negedge clk);bv=1;bs=s;
  @(negedge clk);bv=0;repeat(2)@(negedge clk);
 end endtask
 integer i;
 initial begin
  repeat(4)@(negedge clk);#1;rst=1;
  for(i=0;i<8;i=i+1)packet(i);
  #1;ready=1;repeat(8)@(negedge clk);#1;ready=0;
  // Fill then replace one element while the full queue pops.
  for(i=8;i<12;i=i+1)packet(i);
  @(negedge clk);rv=1;rs=12;@(negedge clk);rv=0;repeat(2)@(negedge clk);
  bv=1;bs=12;ready=1;@(negedge clk);bv=0;ready=0;
  #1;random_ready=1;
  for(i=13;i<45;i=i+1)packet(i);
  #1;random_ready=0;ready=1;repeat(12)@(negedge clk);#1;
  if(count!=0||errors||drops!=expected_drops||checked<35||simultaneous==0)$fatal(1,"COVERAGE");
  $display("GSC_TIMESTAMP_PASS checked=%0d drops=%0d simultaneous=%0d",checked,drops,simultaneous);$finish;
 end
 initial begin #1000000;$fatal(1,"TIMEOUT");end
endmodule
