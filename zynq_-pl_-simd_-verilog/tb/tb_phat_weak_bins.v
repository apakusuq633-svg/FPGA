`timescale 1ns/1ps
module tb_phat_weak_bins;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,start=0,commit=0,is_io=0;reg [2:0] op=0;reg [1:0] sel=0;
 reg [31:0] scalar=0;wire stall,done;wire [31:0] result;integer i;
 rv32_acoustic_ext #(.LANES(4)) dut(.clk_i(clk),.rst_n_i(rst),.start_i(start),.keep_i(1'b1),
 .commit_i(commit),.op_i(op),.is_io_i(is_io),.io_sel_i(sel),.scalar_i(scalar),.stall_o(stall),.done_o(done),.result_o(result));
 task io;input [1:0] s;input [31:0] w;
 begin @(negedge clk);start=1;commit=1;is_io=1;sel=s;scalar=w;
 @(negedge clk);start=0;commit=0;end endtask
 task run;input [2:0] operation;
 begin @(negedge clk);start=1;is_io=0;op=operation;
 @(negedge clk);start=0;while(!done)@(negedge clk);
 commit=1;@(negedge clk);commit=0;end endtask
 always @(negedge clk)if(dut.state_q==1&&dut.op_q==1&&dut.pass_q==7)
 $display("WEAK_BIN phase=%0d mag=%0d real=%0d imag=%0d coefficient=%0d exponent=%0d",dut.vph_q,dut.mag_q[2],dut.zr_q[2],dut.zi_q[2],dut.zinv_q[2],dut.zexp_q[2]);
 initial begin
 repeat(4)@(negedge clk);rst=1;
 for(i=0;i<208;i=i+1)io(0,i==30?32'h00c9fe82:0);
 for(i=0;i<208;i=i+1)io(1,i==30?32'h00fffea6:0);
 run(2);run(1);
 for(i=0;i<30;i=i+1)io(2,0);
 @(negedge clk);start=1;commit=1;is_io=1;sel=2;
 #1;if(result!==32'h0a283cf3)$fatal(1,"weak-bin normalization got=%h expected=0a283cf3",result);
 $display("PHAT_WEAK_BIN_PASS");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
