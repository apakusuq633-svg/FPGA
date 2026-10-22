`timescale 1ns/1ps
module tb_das_precision;
reg clk=0;always #12.5 clk=~clk;
reg rst=0,valid=0,wr=0,rd=0;reg[4:0]addr=0;reg[31:0]data=0;wire[31:0]q;
reg[287:0]pcm=0;wire av;wire[15:0]sample;reg done=0;reg[15:0]result=0;
rv32_das_stream #(.ACTIVE_CHANNELS(12)) dut(.clk_i(clk),.rst_n_i(rst),.pcm_i(pcm),.valid_i(valid),
 .steer_comp_i(384'b0),.steer_locked_i(1'b0),.steer_busy_i(1'b0),
 .cfg_wr_i(wr),.cfg_rd_i(rd),.cfg_addr_i(addr),.cfg_wdata_i(data),.cfg_rdata_o(q),
 .fir_valid_o(av),.fir_sample_o(sample),.fir_ready_i(1'b1),.fir_done_i(done),.fir_result_i(result));
always @(posedge clk)begin done<=av;if(av)result<=sample;end
reg[15:0]v[0:24575],expected[0:2047];integer n,m,t,max_t=0;
task write;input[4:0]a;input[31:0]d;begin @(negedge clk);addr=a;data=d;wr=1;@(negedge clk);wr=0;end endtask
initial begin
 $readmemh("VECTOR_DIR/pcm.hex",v);$readmemh("VECTOR_DIR/expected.hex",expected);
 repeat(4)@(negedge clk);rst=1;write(0,8);
 for(m=0;m<12;m=m+1)write(m<8?8+m:24+m-8,(m*3*16+(m*7)%16)*4096);
 write(0,9);
 for(n=0;n<2048;n=n+1)begin
  if(n%128==0)for(m=0;m<12;m=m+1)write(m<8?8+m:24+m-8,(m*3*16+(m*7+n/128)%16)*4096);
  @(negedge clk);for(m=0;m<12;m=m+1)pcm[m*24+:24]={v[n*12+m],8'b0};valid=1;
  @(negedge clk);valid=0;t=0;
  while(!done&&t<1024)begin @(negedge clk);t=t+1;end
  if(t==1024)$fatal(1,"deadline");if(t>max_t)max_t=t;
  if(sample!==expected[n])$fatal(1,"sample n=%0d got=%0d expected=%0d",n,$signed(sample),$signed(expected[n]));
  if(dut.group_delay_q16_o!=(33*16+(77+n/128)%16)*4096+65536)$fatal(1,"group delay metadata");
  repeat(3)@(negedge clk);addr=3;rd=1;@(negedge clk);rd=0;
  repeat(1024-t-6)@(negedge clk);
 end
 addr=4;#1;if(q!=0)$fatal(1,"drop");
 addr=1;#1;if(q[2])$fatal(1,"error");
 $display("DAS_PRECISION_PASS samples=2048 channels=12 max_cycles=%0d bit_exact=1",max_t);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
