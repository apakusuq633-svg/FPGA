// Isolated 40MHz profile. Average PDM=2.048MHz, PCM=PDM/16=128kHz.
// Quarter accumulator: edge spacings 4/5 clocks; A/B at the next quarter.
// Enables are combinational BEFORE the active system edge (NBA safe).
module raw9_clkgen #(parameter HOLD_TICK=4,CONSUME_TICK=12,DECIM=16)(
 input clk_i,rst_n_i,en_i,output pdm_clk_o,hold_en_o,bit_en_o,decim_en_o);
 reg [25:0] phase; reg [1:0] quarter;reg [3:0] bits;
 wire [26:0] next_phase={1'b0,phase}+27'd8192000;
 wire tick=en_i && next_phase>=27'd40000000;
 assign pdm_clk_o=quarter[1];
 assign hold_en_o=tick && quarter==0;
 assign bit_en_o=tick && quarter==2;
 assign decim_en_o=bit_en_o && bits==15;
 always @(posedge clk_i or negedge rst_n_i)
 if(!rst_n_i)begin phase<=0;quarter<=0;bits<=0;end
 else if(!en_i)begin phase<=0;quarter<=0;bits<=0;end
 else begin
  phase<=tick?next_phase-27'd40000000:next_phase;
  if(tick)quarter<=quarter+1'b1;
  if(bit_en_o)bits<=bits+1'b1;
 end
`ifndef SYNTHESIS
 initial if(DECIM!=16)$fatal(1,"raw profile requires R16");
`endif
endmodule
