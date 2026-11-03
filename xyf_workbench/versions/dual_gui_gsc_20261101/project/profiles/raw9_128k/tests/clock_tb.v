`timescale 1ns/1ps
module clock_tb;
 reg clk=0,rst=0,en=0;always #12.5 clk=~clk;
 wire pdm,a,b,d;integer cycles=0,aa=0,bb=0,dd=0,last=0,delta;
 raw9_clkgen dut(clk,rst,en,pdm,a,b,d);
 initial begin #51;rst=1;en=1;end
 always @(posedge clk)if(rst&&en)begin
 cycles=cycles+1;
 if(a)begin if(pdm)$fatal;aa=aa+1;end
 if(b)begin if(!pdm)$fatal;bb=bb+1;end
 if(d)begin
 if(last!=0)begin delta=cycles-last;if(delta!=312&&delta!=313)$fatal(1,"cadence");end
 last=cycles;dd=dd+1;end
 if(cycles==400000)begin
 if(aa!=20480||bb!=20480||dd!=1280)$fatal(1,"rate %d %d %d",aa,bb,dd);
 $display("RAW9_CLOCK_PASS 10ms pdm=20480 pcm=1280");$finish;end
 end
endmodule
