`timescale 1ns/1ps
module tb_phat_reciprocal;
 wire done,stall;wire [31:0] result;
 rv32_acoustic_ext #(.LANES(4)) dut(.clk_i(1'b0),.rst_n_i(1'b0),.start_i(1'b0),
 .keep_i(1'b0),.commit_i(1'b0),.op_i(3'd0),.is_io_i(1'b0),.io_sel_i(2'b0),.scalar_i(32'b0),
 .done_o(done),.stall_o(stall),.result_o(result));
 reg [15:0] expected[0:65535];integer k;
 initial begin
  $readmemh("build/phat_reciprocal.hex",expected);
  for(k=0;k<65536;k=k+1)begin
   #1;if(dut.recip_q14(k[15:0])!==expected[k])$fatal(1,"reciprocal mismatch magnitude=%0d",k);
  end
  $display("PHAT_RECIPROCAL_PASS magnitudes=65536");$finish;
 end
endmodule
