`timescale 1ns/1ps
module tb_planar8_overlap;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,en=0,valid=0;
 reg [191:0] pcm=0;
 reg [31:0] id=0;
 wire [31:0] raw_drop,window_drop;
 rv32_overlap_localizer #(.CHANNELS(8),.CPU_SCHEDULED(1)) dut(
  .clk_i(clk),.rst_n_i(rst),.enable_i(en),.rearm_i(1'b0),
  .valid_i(valid),.pcm_i(pcm),.sample_id_i(id),
  .raw_drop_o(raw_drop),.window_drop_o(window_drop),
  .fft_done_i(1'b0),.fft_result_i(32'b0),.srp_done_i(1'b0),
  .srp_busy_i(1'b0),.srp_score_i(32'b0),.fft_ready_i(1'b0),
  .ac_ready_i(1'b0),.ac_done_i(1'b0),.ac_result_i(32'b0));
 integer n,ch,w;
 reg [31:0] expected;
 initial begin
  repeat(4)@(negedge clk);rst=1;en=1;
  for(n=0;n<16;n=n+1)begin
   @(negedge clk);
   for(ch=0;ch<8;ch=ch+1)pcm[ch*24+:24]=(n*16+ch)<<8;
   id=100+n;valid=1;
   @(negedge clk);valid=0;
   repeat(8)@(negedge clk);
  end
  if($size(dut.raw_mem)!=8192 || $size(dut.spectrum)!=1664 || $size(dut.statistics)!=40)
   $fatal(1,"8-channel BRAM dimensions mismatch");
  for(n=0;n<16;n=n+1)for(w=0;w<4;w=w+1)begin
   expected=((n*16+2*w+1)<<16)|(n*16+2*w);
   if(dut.raw_mem[n*4+w]!==expected)
    $fatal(1,"overlap raw packing mismatch sample=%0d word=%0d",n,w);
  end
  if(raw_drop || window_drop)$fatal(1,"unexpected input drops");
  $display("PLANAR8_OVERLAP_PASS samples=16 words=64 channels=8 raw_words=8192 spectrum_words=1664");
  $finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
