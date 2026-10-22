`timescale 1ns/1ps
module tb_live16_location;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,sw=0,sr=0,tw=0,tr=0;
 reg [6:0] sa=0,ta=0;reg [31:0] sd=0,td=0;
 wire [31:0] sq,tq;wire sb,tb;wire [511:0] comp;wire locked;
 rv32_srp_regs #(.N_PAIR(120),.N_GRID(1024),.R_LEN(32),.IDX_W(5),.ADDR_W(17),.GRID_IDX_W(10)) scan(
  .clk_i(clk),.rst_n_i(rst),.core_start_i(1'b0),.core_wr_i(1'b0),.core_rd_i(1'b0),
  .core_addr_i(7'b0),.core_wdata_i(32'b0),.core_rdata_o(),
  .ps_wr_i(sw),.ps_rd_i(sr),.ps_addr_i(sa),.ps_wdata_i(sd),.ps_rdata_o(sq),.busy_o(sb));
 rv32_steer_regs #(.N_MIC(16),.N_GRID(1024),.GRID_W(32)) steer(
  .clk_i(clk),.rst_n_i(rst),.core_start_i(1'b0),.core_wr_i(1'b0),.core_rd_i(1'b0),
  .core_addr_i(7'b0),.core_wdata_i(32'b0),.core_rdata_o(),
  .ps_wr_i(tw),.ps_rd_i(tr),.ps_addr_i(ta),.ps_wdata_i(td),.ps_rdata_o(tq),
  .busy_o(tb),.comp_o(comp),.locked_o(locked));
 reg [15:0] lut[0:122879];reg [13:0] sl[0:16383];
 reg [15:0] rv[0:3839];reg [31:0] pv[0:1023],cv[0:15];
 integer k,g,m,c,cycles;reg [31:0] value;
 task ws;input [6:0] a;input [31:0] d;
 begin @(negedge clk);sa=a;sd=d;sw=1;@(negedge clk);sw=0;@(negedge clk);end endtask
 task wt;input [6:0] a;input [31:0] d;
 begin @(negedge clk);ta=a;td=d;tw=1;@(negedge clk);tw=0;@(negedge clk);end endtask
 task rs;input [6:0] a;output [31:0] d;
 begin @(negedge clk);sa=a;sr=1;#1;d=sq;@(negedge clk);sr=0;@(negedge clk);end endtask
 task update;input [31:0] target;
 begin wt(5,target);k=0;while(tb&&k<300)begin @(negedge clk);k=k+1;end
 if(k==300)$fatal(1,"steer stuck (channel loop)");end endtask
 initial begin
 $readmemh("build/das16_loc/srp_lut.hex",lut);$readmemh("build/das16_loc/steer_lut.hex",sl);
 repeat(4)@(negedge clk);rst=1;
 ws(2,0);for(g=0;g<122880;g=g+1)ws(3,lut[g]);
 if(scan.idx_q!==0)$fatal(1,"17-bit LUT pointer wrap");
 wt(2,0);for(g=0;g<16384;g=g+1)wt(3,sl[g]);wt(6,32'h00010100);
 for(c=0;c<2;c=c+1)begin
  if(c==0)begin $readmemh("build/das16_loc/scene0_r.hex",rv);$readmemh("build/das16_loc/scene0_p.hex",pv);$readmemh("build/das16_loc/scene0_comp.hex",cv);end
  else begin $readmemh("build/das16_loc/scene1_r.hex",rv);$readmemh("build/das16_loc/scene1_p.hex",pv);$readmemh("build/das16_loc/scene1_comp.hex",cv);end
  ws(2,32'h20000);for(g=0;g<3840;g=g+1)ws(3,rv[g]);
  ws(0,3);cycles=0;while(sb&&cycles<800000)begin @(negedge clk);cycles=cycles+1;end
  if(cycles==800000)$fatal(1,"120-pair scan stuck");
  ws(2,32'h40000);for(g=0;g<1024;g=g+1)begin rs(4,value);if(value!==pv[g])$fatal(1,"P mismatch case=%0d grid=%0d got=%h expected=%h",c,g,value,pv[g]);end
  rs(1,value);if(value[3])$fatal(1,"scan WERR");
  // Repeated identical updates satisfy the existing hysteresis policy.
  for(m=0;m<8;m=m+1)update(c==0?773:250);
  if(!locked)$fatal(1,"not locked");
  ta=1;#1;if(((tq>>8)&1023)!==(c==0?773:250))$fatal(1,"committed grid truncated in STATUS");
  for(m=0;m<16;m=m+1)if(comp[m*32+:32]!==cv[m])$fatal(1,"16ch comp mismatch case=%0d ch=%0d got=%h ref=%h",c,m,comp[m*32+:32],cv[m]);
  $display("LIVE16_LOCATION_CASE_PASS case=%0d grid=%0d scan_wait_cycles=%0d all_1024_scores_match=1",c,c==0?773:250,cycles);
 end
 // Columns 26 and 10 differ by 16; a four-bit distance would wrap to zero.
 update(234);if(steer.committed_q!==250)$fatal(1,"32-grid axis distance wrapped");
 update(250);
 // Only CH15 changes; the upper bank must participate in both change and max-gap reductions.
 wt(6,32'h00010140);wt(2,15*1024+250);wt(3,14'h0100);
 update(250);if(steer.step_q<=0)$fatal(1,"upper-bank max gap ignored");
 if(comp[15*32+:32]===cv[15])$fatal(1,"CH15 update ignored");
 $display("LIVE16_LOCATION_PASS pairs=120 grid=1024 r_len=32 microphones=16");$finish;
 end
 initial begin #40000000;$fatal(1,"timeout");end
endmodule
