`timescale 1ns/1ps
module srp_throughput_case #(
  parameter PAIRS=120, GRIDS=1024, RLEN=32, IW=5, GW=10, AW=17, FAST=0
)(output reg finished=0);
  reg clk=0; always #5 clk=~clk;
  reg rst=0,en=0,start=0,lw=0,rw=0;
  reg [AW-1:0] la=0,ra=0;
  reg [IW+3:0] ld=0;
  reg signed [15:0] rd=0;
  reg [GW-1:0] pa=0;
  wire busy,done; wire signed [31:0] value; wire [31:0] ticks;
  rv32_srp_scan #(.N_PAIR(PAIRS),.N_GRID(GRIDS),.R_LEN(RLEN),
    .IDX_W(IW),.GRID_IDX_W(GW),.ADDR_W(AW),.FAST_SCAN(FAST)) dut(
    .clk_i(clk),.rst_n_i(rst),.en_i(en),.start_i(start),.busy_o(busy),.done_o(done),
    .lut_we_i(lw),.lut_addr_i(la),.lut_data_i(ld),.r_we_i(rw),.r_addr_i(ra),
    .r_data_i(rd),.p_addr_i(pa),.p_data_o(value),.cycle_cnt_o(ticks));
  integer p,g,k,round,cycles,expected,v0,v1,idx,frac;
  function integer correlation;
    input integer pair_id,sample_id;
    begin correlation=((pair_id*101+sample_id*997)%60001)-30000; end
  endfunction
  task run_scan;
    begin
      @(negedge clk);start=1;@(negedge clk);start=0;cycles=0;
      while(!done && cycles<PAIRS*GRIDS*6+20)begin @(negedge clk);cycles=cycles+1;end
      if(!done)$fatal(1,"scan timeout");
`ifdef SRP_BASELINE
      if(cycles!==5*PAIRS*GRIDS)$fatal(1,"unexpected baseline cycles=%0d",cycles);
`else
      if(FAST)begin
        if(cycles>PAIRS*(GRIDS+16)+16)$fatal(1,"pipelined scan too slow cycles=%0d",cycles);
        if(FAST==4&&cycles>((PAIRS+3)/4)*(GRIDS+12)+4)$fatal(1,"parallel scan too slow cycles=%0d",cycles);
      end else if(cycles!==4*PAIRS*GRIDS+1)$fatal(1,"unexpected scan cycles=%0d",cycles);
`endif
      for(g=0;g<GRIDS;g=g+1)begin
        expected=0;
        for(p=0;p<PAIRS;p=p+1)begin
          idx=(p*7+g*3)%RLEN;frac=(p+g)%16;
          v0=correlation(p,idx);v1=correlation(p,(idx+1)%RLEN);
          expected=expected+v0+(((v1-v0)*frac)>>>4);
        end
        pa=g;repeat(2)@(negedge clk);
        if(value!==expected)$fatal(1,"score pairs=%0d round=%0d grid=%0d got=%0d expected=%0d",PAIRS,round,g,value,expected);
      end
      $display("SRP_THROUGHPUT pairs=%0d grids=%0d fast=%0d round=%0d cycles=%0d",PAIRS,GRIDS,FAST,round,cycles);
    end
  endtask
  initial begin
    repeat(3)@(negedge clk);rst=1;en=1;
    for(p=0;p<PAIRS;p=p+1)for(g=0;g<GRIDS;g=g+1)begin
      lw=1;la=p*GRIDS+g;ld=(((p*7+g*3)%RLEN)<<4)|((p+g)%16);@(negedge clk);
    end
    lw=0;
    for(p=0;p<PAIRS;p=p+1)for(k=0;k<RLEN;k=k+1)begin
      rw=1;ra=p*RLEN+k;rd=correlation(p,k);@(negedge clk);
    end
    rw=0;
    for(round=0;round<2;round=round+1)run_scan();
    start=1;@(negedge clk);start=0;repeat(13)@(negedge clk);en=0;
    repeat(2)@(negedge clk);if(busy||done||value!==0)$fatal(1,"abort left valid result");
    en=1;round=2;run_scan();finished=1;
  end
endmodule
module tb_srp_parallel4_edges;
  wire a,b;
  srp_throughput_case #(.PAIRS(5),.GRIDS(1),.GW(1),.RLEN(64),.IW(6),.FAST(4)) single_grid(a);
  srp_throughput_case #(.PAIRS(7),.GRIDS(17),.GW(5),.RLEN(64),.IW(6),.FAST(4)) partial_group(b);
  initial begin wait(a&&b);$display("SRP_PARALLEL4_EDGES_PASS partial_group_single_grid_restart_abort=1");$finish;end
  initial begin #100000;$fatal(1,"timeout");end
endmodule
module tb_srp_throughput;
  wire a,b,c,d,e,f,g,h,i,j;
  srp_throughput_case production(a);
  srp_throughput_case #(.PAIRS(28),.GRIDS(256),.RLEN(1024),.IW(10),.GW(8),.AW(15)) eight(b);
  srp_throughput_case #(.PAIRS(4),.GRIDS(256),.RLEN(1024),.IW(10),.GW(8),.AW(15)) four(c);
  srp_throughput_case #(.PAIRS(66)) twelve(d);
  srp_throughput_case #(.PAIRS(28)) rect8(e);
  srp_throughput_case #(.PAIRS(66),.FAST(1)) pipelined12(f);
  srp_throughput_case #(.PAIRS(2),.GRIDS(1),.GW(1),.FAST(1)) single_grid(g);
  srp_throughput_case #(.PAIRS(36),.RLEN(64),.IW(6),.FAST(4)) parallel_circular9(h);
  srp_throughput_case #(.PAIRS(5),.GRIDS(1),.GW(1),.RLEN(64),.IW(6),.FAST(4)) parallel_single_grid(i);
  srp_throughput_case #(.PAIRS(7),.GRIDS(17),.GW(5),.RLEN(64),.IW(6),.FAST(4)) parallel_partial_group(j);
  initial begin wait(a&&b&&c&&d&&e&&f&&g&&h&&i&&j);$display("SRP_THROUGHPUT_PASS signed_fractional_wrap_restart_abort=1");$finish;end
  initial begin #30000000;$fatal(1,"timeout");end
endmodule
