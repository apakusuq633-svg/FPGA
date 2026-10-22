// Explicit acknowledgement only; no automatic fault clearing. History survives rearm.
module rv32_localizer_recovery(
 input clk_i,rst_n_i,fault_i,request_i,auto_enable_i,engines_idle_i,window_done_i,
 input [31:0] sample_seq_i,raw_drop_i,window_drop_i,
 output reg rearm_o,output reg [2:0] state_o,
 output reg [31:0] epoch_o,fault_events_o,total_raw_drop_o,total_window_drop_o,
 output reg [31:0] first_fault_sample_o,gap_end_sample_o
);
 localparam RUN=0,FAULT_LATCHED=1,QUIESCE=2,WARMUP=3,REARM_WAIT=4;
 reg [1:0] auto_attempts;
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin rearm_o<=0;state_o<=RUN;epoch_o<=0;fault_events_o<=0;
   total_raw_drop_o<=0;total_window_drop_o<=0;first_fault_sample_o<=0;gap_end_sample_o<=0;auto_attempts<=0;end
  else begin
   rearm_o<=0;
   case(state_o)
    RUN,WARMUP:begin
     if(fault_i)begin
      state_o<=FAULT_LATCHED;fault_events_o<=fault_events_o+1;
      if(fault_events_o==0)first_fault_sample_o<=sample_seq_i;
     end else if(state_o==WARMUP&&window_done_i)state_o<=RUN;
    end
    FAULT_LATCHED:if(request_i)begin state_o<=QUIESCE;auto_attempts<=0;end
      else if(auto_enable_i===1'b1&&auto_attempts<3)begin state_o<=QUIESCE;auto_attempts<=auto_attempts+1'b1;end
    QUIESCE:if(engines_idle_i)begin
     total_raw_drop_o<=total_raw_drop_o+raw_drop_i;
     total_window_drop_o<=total_window_drop_o+window_drop_i;
     gap_end_sample_o<=sample_seq_i;epoch_o<=epoch_o+1;rearm_o<=1;state_o<=REARM_WAIT;
    end
    REARM_WAIT:if(!fault_i)state_o<=WARMUP;
    default:state_o<=FAULT_LATCHED;
   endcase
  end
 end
endmodule
