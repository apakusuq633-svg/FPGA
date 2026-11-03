// Indexed PS extension at 0x3f0..0x3fc. Reset-disabled fine steering and tacho.
// Fine vectors are complete Q4-quantized Q16 delays, committed atomically.
module rv32_circular9_control # (parameter FINE_TTL=8000000)(
 input clk_i,rst_n_i,input [31:0] clock_i,epoch_i,input tacho_i,
 input wr_i,input [1:0] addr_i,input [31:0] wdata_i,output reg [31:0] rdata_o,
 output fine_enabled_o,output fine_valid_o,output [9:0] fine_grid_o,
 output [31:0] fine_version_o,output [287:0] fine_comp_o
);
 reg [7:0] index_q;
 reg [31:0] shadow_grid,shadow_sequence,shadow_epoch,shadow_clock;
 reg [31:0] shadow_delay[0:8],active_delay[0:8];
 reg [12:0] written;
 reg armed;reg [31:0] active_grid,active_sequence,active_epoch,active_clock,rejected;
 wire fine_fresh=(clock_i-active_clock)<FINE_TTL&&active_epoch==epoch_i;
 assign fine_enabled_o=armed;
 assign fine_valid_o=armed&&fine_fresh;
 assign fine_grid_o=active_grid[9:0];
 assign fine_version_o=32'h80000000|active_sequence;
 genvar g;generate for(g=0;g<9;g=g+1)begin:out_delay
  assign fine_comp_o[g*32+:32]=active_delay[g];
 end endgenerate
 reg vector_ok,has_zero,same_vector;integer k,j;
 always @*begin
  vector_ok=1;has_zero=0;same_vector=1;
  for(j=0;j<9;j=j+1)begin
   if(shadow_delay[j]>=(61<<16)||shadow_delay[j][11:0]!=0)vector_ok=0;
   if(shadow_delay[j]==0)has_zero=1;
   if(shadow_delay[j]!=active_delay[j])same_vector=0;
  end
 end
 // Asynchronous input is synchronized, then both pulse polarities must remain
 // stable for filter_ticks. Only rising edges measure revolutions/pulses.
 (* ASYNC_REG="TRUE" *) reg tach_meta,tach_sync;
 reg tach_filtered,tach_prior,tach_enabled,have_edge,tach_valid;
 reg [15:0] stable_ticks;
 reg [31:0] filter_ticks,min_period,timeout_ticks,last_edge,period_q;
 reg [31:0] tach_sequence,pulse_count,glitch_count,stable_periods;
 wire rising=tach_filtered&&!tach_prior;
 wire [31:0] interval=clock_i-last_edge;
 wire [31:0] difference=interval>period_q?interval-period_q:period_q-interval;
 wire period_consistent={4'b0,difference}*20<={4'b0,period_q};
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin tach_meta<=0;tach_sync<=0;end
  else begin tach_meta<=tacho_i;tach_sync<=tach_meta;end
 end
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin
   index_q<=0;written<=0;armed<=0;active_grid<=0;active_sequence<=0;
   active_epoch<=0;active_clock<=0;rejected<=0;shadow_grid<=0;
   shadow_sequence<=0;shadow_epoch<=0;shadow_clock<=0;
   for(k=0;k<9;k=k+1)begin shadow_delay[k]<=0;active_delay[k]<=0;end
   tach_filtered<=0;tach_prior<=0;tach_enabled<=0;have_edge<=0;tach_valid<=0;
   stable_ticks<=0;filter_ticks<=64;min_period<=128;timeout_ticks<=12000000;
   last_edge<=0;period_q<=0;tach_sequence<=0;pulse_count<=0;glitch_count<=0;stable_periods<=0;
  end else begin
   tach_prior<=tach_filtered;
   if(tach_sync==tach_filtered)stable_ticks<=0;
   else if(stable_ticks+1>=filter_ticks)begin tach_filtered<=tach_sync;stable_ticks<=0;end
   else stable_ticks<=stable_ticks+1'b1;
   if(!tach_enabled)begin have_edge<=0;tach_valid<=0;stable_periods<=0;end
   else begin
    if(have_edge&&interval>=timeout_ticks)begin have_edge<=0;tach_valid<=0;stable_periods<=0;tach_sequence<=tach_sequence+1;end
    if(rising)begin
     if(!have_edge)begin last_edge<=clock_i;have_edge<=1;tach_valid<=0;end
     else if(interval<min_period)glitch_count<=glitch_count+1;
     else begin
      last_edge<=clock_i;period_q<=interval;tach_sequence<=tach_sequence+1;
      if(period_q!=0&&period_consistent)begin
       if(stable_periods<3)stable_periods<=stable_periods+1;
       tach_valid<=stable_periods>=2;
      end else begin stable_periods<=1;tach_valid<=0;end
     end
     pulse_count<=pulse_count+1;
    end
   end
   if(wr_i)case(addr_i)
    0:case(wdata_i)
     32'h42454731:written<=0; // BEG1: shadow transaction; active bank unchanged
     32'h4f464631:begin armed<=0;written<=0;end // OFF1
     32'h434f4d31:begin // COM1: no partial, future, aliased or stale vector
      if(written==13'h1fff&&shadow_grid<1024&&shadow_sequence>0&&
        !shadow_sequence[31]&&shadow_epoch==epoch_i&&
        (clock_i-shadow_clock)<FINE_TTL&&vector_ok&&has_zero&&
        (active_sequence==0||shadow_sequence>active_sequence||
         (shadow_sequence==active_sequence&&same_vector&&shadow_grid==active_grid&&shadow_epoch==active_epoch)))begin
       active_grid<=shadow_grid;active_sequence<=shadow_sequence;
       active_epoch<=shadow_epoch;active_clock<=shadow_clock;armed<=1;
       for(k=0;k<9;k=k+1)active_delay[k]<=shadow_delay[k];
      end else rejected<=rejected+1;
      written<=0;
     end
     default:rejected<=rejected+1;
    endcase
    1:index_q<=wdata_i[7:0];
    2:case(index_q)
     1:begin shadow_grid<=wdata_i;written[0]<=1;end
     2:begin shadow_sequence<=wdata_i;written[1]<=1;end
     3:begin shadow_epoch<=wdata_i;written[2]<=1;end
     4:begin shadow_clock<=wdata_i;written[3]<=1;end
     64:begin tach_enabled<=wdata_i==1;have_edge<=0;tach_valid<=0;period_q<=0;stable_periods<=0;tach_sequence<=tach_sequence+1;end
     65:if(wdata_i>=2&&wdata_i<=4000)begin filter_ticks<=wdata_i;have_edge<=0;tach_valid<=0;period_q<=0;stable_periods<=0;tach_sequence<=tach_sequence+1;end
     66:if(wdata_i>=4&&wdata_i<=4000000)begin min_period<=wdata_i;have_edge<=0;tach_valid<=0;period_q<=0;stable_periods<=0;tach_sequence<=tach_sequence+1;end
     67:if(wdata_i>=400000&&wdata_i<=80000000)begin timeout_ticks<=wdata_i;have_edge<=0;tach_valid<=0;period_q<=0;stable_periods<=0;tach_sequence<=tach_sequence+1;end
     default:if(index_q>=8&&index_q<=16)begin shadow_delay[index_q-8]<=wdata_i;written[index_q-4]<=1;end
    endcase
    default:begin end
   endcase
  end
 end
 always @*begin
  rdata_o=0;
  case(addr_i)
   0:rdata_o=32'h43395831; // C9X1 extension signature
   1:rdata_o={24'b0,index_q};
   3:rdata_o={28'b0,tach_valid,tach_enabled,fine_valid_o,armed};
   2:case(index_q)
    0:rdata_o=32'h00010003;
    20:rdata_o=active_grid;21:rdata_o=fine_version_o;22:rdata_o=active_epoch;
    23:rdata_o=active_clock;24:rdata_o=rejected;25:rdata_o={30'b0,fine_valid_o,armed};
    26:rdata_o=clock_i;27:rdata_o=epoch_i;
    64:rdata_o={31'b0,tach_enabled};65:rdata_o=filter_ticks;
    66:rdata_o=min_period;67:rdata_o=timeout_ticks;
    68:rdata_o=tach_sequence;69:rdata_o=period_q;70:rdata_o=clock_i-last_edge;
    71:rdata_o=pulse_count;72:rdata_o=glitch_count;
    73:rdata_o={30'b0,have_edge,tach_valid};74:rdata_o=last_edge;75:rdata_o=stable_periods;
    default:if(index_q>=32&&index_q<=40)rdata_o=active_delay[index_q-32];
   endcase
  endcase
 end
endmodule
