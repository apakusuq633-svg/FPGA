`timescale 1ns/1ps
// Synthetic same-word read/write edge; not an arithmetic or physical-board test.
module tb_localizer12_collision;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,en=0;wire done;wire[31:0]raw_drop;
 rv32_overlap_localizer #(.CPU_SCHEDULED(1)) dut(
 .clk_i(clk),.rst_n_i(rst),.enable_i(en),.valid_i(1'b0),.pcm_i(288'b0),.sample_id_i(32'b0),
 .done_o(done),.raw_drop_o(raw_drop),.fft_ready_i(1'b1),.ac_ready_i(1'b1),
 .fft_done_i(1'b0),.fft_result_i(32'b0),.ac_done_i(1'b0),.ac_result_i(32'b0),
 .srp_done_i(1'b0),.srp_busy_i(1'b0),.srp_score_i(32'b0));
 initial begin
  repeat(4)@(negedge clk);rst=1;en=1;
  @(negedge clk);
  dut.raw_mem[0]=32'h22221111;dut.state=1;dut.active_first=0;dut.n=0;dut.channel=0;
  dut.sample_count=2049;dut.wr_active=1;dut.wr_sample=0;dut.wr_word=0;dut.wr_pcm=192'h44443333;
  @(posedge clk);#1;
  if(dut.raw_q!==32'h22221111||dut.raw_mem[0]!==32'h44443333)$fatal(1,"READ_FIRST_MISMATCH");
  if(dut.state!=0||raw_drop==0||done)$fatal(1,"COLLISION_NOT_QUARANTINED");
  repeat(16)begin @(posedge clk);#1;if(done)$fatal(1,"COLLISION_PUBLISHED");end
  $display("LOCALIZER_COLLISION_PASS read_first=1 lifetime_loss=1 result_quarantined=1");$finish;
 end
endmodule
