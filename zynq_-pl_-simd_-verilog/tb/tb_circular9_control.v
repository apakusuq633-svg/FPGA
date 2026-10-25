`timescale 1ns/1ps
module tb_circular9_control;
 reg clk=0;always #12.5 clk=~clk;
 reg rst=0,wr=0,tach=0;reg[1:0] addr=0;reg[31:0] data=0,stamp=0,epoch=7;
 wire[31:0] rd,version;wire enabled,valid;wire[9:0] grid;wire[287:0] comp;
 always @(posedge clk)stamp<=stamp+1;
 rv32_circular9_control dut(.clk_i(clk),.rst_n_i(rst),.clock_i(stamp),.epoch_i(epoch),
  .tacho_i(tach),.wr_i(wr),.addr_i(addr),.wdata_i(data),.rdata_o(rd),
  .fine_enabled_o(enabled),.fine_valid_o(valid),.fine_grid_o(grid),.fine_version_o(version),.fine_comp_o(comp));
 task write_reg(input[1:0] a,input[31:0] value);begin
  @(negedge clk);addr=a;data=value;wr=1;@(negedge clk);wr=0;
 end endtask
 task indexed(input[7:0] idx,input[31:0] value);begin write_reg(1,idx);write_reg(2,value);end endtask
 task expect_index(input[7:0] idx,input[31:0] value);begin
  write_reg(1,idx);addr=2;#1;if(rd!==value)$fatal(1,"index%0d got%h expected%h",idx,rd,value);
 end endtask
 task stage(input[31:0] seq,input[31:0] ep,input[31:0] maximum);begin
  write_reg(0,32'h42454731);indexed(1,528);indexed(2,seq);indexed(3,ep);indexed(4,stamp);
  for(integer i=0;i<9;i=i+1)indexed(8+i,i==8?0:maximum+i*4096);
 end endtask
 task pulse(input integer period);begin
  tach=1;repeat(period/2)@(negedge clk);tach=0;
  repeat(period-period/2)@(negedge clk);
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;repeat(4)@(negedge clk);
  addr=0;#1;if(rd!==32'h43395831)$fatal(1,"signature");
  if(enabled||valid)$fatal(1,"reset must withhold fine direction");
  stage(1,7,4096);if(enabled)$fatal(1,"shadow must not change active");
  write_reg(0,32'h434f4d31);
  if(!valid||grid!=528||version!=32'h80000001||comp[31:0]!=4096||comp[287:256]!=0)$fatal(1,"atomic vector");
  stage(1,7,8192);write_reg(0,32'h434f4d31);
  expect_index(24,1);if(comp[31:0]!=4096)$fatal(1,"version alias changed active");
  stage(2,8,4096);write_reg(0,32'h434f4d31);expect_index(24,2);
  stage(2,7,61<<16);write_reg(0,32'h434f4d31);expect_index(24,3);
  stage(2,7,8192);write_reg(0,32'h434f4d31);
  if(version!=32'h80000002||comp[31:0]!=8192)$fatal(1,"new vector token");
  write_reg(0,32'h42454731);indexed(1,12);write_reg(0,32'h434f4d31);expect_index(24,4);
  epoch=8;#1;if(valid)$fatal(1,"epoch must revoke");epoch=7;
  repeat(8000001)@(negedge clk);if(valid)$fatal(1,"fine expiry");
  write_reg(0,32'h4f464631);if(enabled)$fatal(1,"release");
  indexed(64,1);
  // Reject a pulse shorter than the 64-cycle filter.
  tach=1;repeat(8)@(negedge clk);tach=0;repeat(100)@(negedge clk);expect_index(71,0);
  // Four actual 100ms periods at40MHz; stable600rpm for PPR1.
  repeat(5)pulse(4000000);
  expect_index(69,4000000);expect_index(73,3);
  // Abrupt speed change withdraws validity until three stable periods.
  pulse(2000000);pulse(2000000);expect_index(73,2);
  repeat(4)pulse(2000000);expect_index(69,2000000);expect_index(73,3);
  repeat(12000010)@(negedge clk);expect_index(73,0);
  indexed(64,0);expect_index(64,0);
  $display("CIRCULAR9_CONTROL_RTL_PASS atomic_fine=1 alias_partial_epoch_ttl_rejected=1 tach600_1200_filter_timeout=1");$finish;
 end
 initial begin #2000000000;$fatal(1,"timeout");end
endmodule
