`timescale 1ns/1ps
module tb_gsc_tap;
reg clk=0;always #12.5 clk=~clk;reg rst=0,rv=0,bv=0,ready=1;reg[31:0]seq=0;reg[191:0]pcm=0;
wire valid;wire[511:0]packet;wire[31:0]overflow,errors;integer n,ch,received=0;reg[511:0]held;reg washeld=0;
rv32_gsc_tap dut(.clk_i(clk),.rst_n_i(rst),.raw_valid_i(rv),.raw_pcm_i(pcm),.raw_seq_i(seq),
 .beam_valid_i(bv),.beam_seq_i(seq),.beam_i(seq[15:0]),.fir_i(seq[15:0]+16'd1),
 .direction_version_i(32'd7),.effective_seq_i(32'd3),.window_id_i(32'd4),.group_delay_q16_i(32'd65536),
 .recovery_epoch_i(32'd2),.direction_id_i(10'd585),.trusted_i(1'b1),.transition_i(1'b0),
 .valid_o(valid),.ready_i(ready),.data_o(packet),.overflow_o(overflow),.alignment_errors_o(errors));
always @(posedge clk)if(rst)begin
 if(washeld&&packet!==held)$fatal(1,"backpressure changed payload");
 washeld<=valid&&!ready;held<=packet;
 if(valid&&ready)begin
  if(packet[31:0]!=32'h47534301||packet[95:64]!=7||packet[127:96]!=3||packet[159:128]!=4||packet[191:160]!=65536)$fatal(1,"metadata");
  for(integer c=0;c<12;c=c+1)if(packet[256+c*16+:16]!=(packet[63:32]*16+c)%65536)$fatal(1,"channel alignment");
  if(packet[239:224]!=packet[47:32]||packet[255:240]!=packet[47:32]+1)$fatal(1,"beam alignment");
  received=received+1;
 end
end
initial begin
 repeat(4)@(negedge clk);rst=1;
 for(n=0;n<24;n=n+1)begin
  @(negedge clk);seq=n;for(ch=0;ch<12;ch=ch+1)pcm[ch*16+:16]=n*16+ch;rv=1;ready=n<8||n>=20;
  @(negedge clk);rv=0;repeat(5)@(negedge clk);bv=1;@(negedge clk);bv=0;repeat(8)@(negedge clk);
 end
 repeat(10)@(negedge clk);
 if(errors!=0||overflow!=8||received!=16)$fatal(1,"counts errors=%0d overflow=%0d received=%0d",errors,overflow,received);
 @(negedge clk);bv=1;@(negedge clk);bv=0;repeat(2)@(negedge clk);
 if(errors!=1)$fatal(1,"unaligned beam not detected");
 $display("GSC_TAP_PASS packets=%0d explicit_overflow=%0d alignment_counterexample=1",received,overflow);$finish;
end
endmodule
