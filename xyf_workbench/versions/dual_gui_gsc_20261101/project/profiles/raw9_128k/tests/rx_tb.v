`timescale 1ns/1ps
module rx_tb;
reg clk=0,rst=0,en=0;always #12.5 clk=~clk;
reg[4:0]din;wire pdm,valid;wire[239:0]pcm;wire[31:0]seq;wire[9:0]frozen;
integer n=0,line,frames=0,combos[0:3],j;reg[9:0]seen;
raw9_rx #(.N_CH(10),.ACTIVE_MASK(10'h1ff),.MICS_PER_LINE(2),.DECIM(16),
 .MIC_STARTUP_CYCLES(0),.CIC_SETTLE_FRAMES(0)) dut(clk,rst,en,din,pdm,pcm,valid,seq,frozen);
function bitvalue;input integer t;reg[31:0]v;begin v=t*32'd1103515245+32'd12345;bitvalue=v[19];end endfunction
always @(negedge clk)for(line=0;line<5;line=line+1)
 din[line]=bitvalue(n-(line*2+(pdm?1:0))*7);
always @(posedge clk)if(rst&&en)begin
 if(dut.bit_en_w)begin
 combos[{dut.phase_a_q[0],din[0]}]=combos[{dut.phase_a_q[0],din[0]}]+1;n=n+1;end
 if(valid)begin
 if(dut.ch_valid_w!=10'h3ff)$fatal(1,"channel cadence");
 if(pcm[239:216]!=0)$fatal(1,"inactive channel");
 for(j=1;j<9;j=j+1)if(pcm[j*24+:24]!=pcm[23:0])seen[j]=1;
 frames=frames+1;
 if(frames==512)begin
 for(j=0;j<4;j=j+1)if(!combos[j])$fatal(1,"missing phase combination");
 if(seen[8:1]!=8'hff)$fatal(1,"duplicate test stimulus/output");
 $display("RAW9_RX_PASS frames=512 combinations=%d/%d/%d/%d",combos[0],combos[1],combos[2],combos[3]);$finish;end
 end end
initial begin din=0;seen=0;for(j=0;j<4;j=j+1)combos[j]=0;#51;rst=1;en=1;#100000000;$fatal(1,"timeout");end
endmodule
