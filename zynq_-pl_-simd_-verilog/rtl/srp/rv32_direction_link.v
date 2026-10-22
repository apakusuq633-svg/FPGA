// TEST_GEOMETRY_ONLY gate is explicit and reset-disabled. No engine or LUT copy.
module rv32_direction_link # (parameter CHANNELS=8)(
 input clk_i,rst_n_i,enable_i,fault_i,result_valid_i,
 input [9:0] result_grid_i,input [31:0] result_version_i,
 input signed [31:0] result_score_i,
 input steer_busy_i,steer_locked_i,steer_bus_idle_i,
 input [9:0] steer_committed_i,input [CHANNELS*32-1:0] steer_comp_i,
 output reg steer_start_o,output reg [9:0] steer_target_o,
 output direction_valid_o,input direction_ready_i,
 output reg [CHANNELS*32-1:0] direction_comp_o,
 output reg [9:0] direction_id_o,output reg [31:0] direction_version_o,
 output reg [31:0] rejected_o
);
 reg [2:0] state;reg [9:0] target;reg [31:0] version;
 assign direction_valid_o=state==4&&enable_i&&!fault_i;
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin state<=0;target<=0;version<=0;steer_start_o<=0;steer_target_o<=0;
   direction_comp_o<=0;direction_id_o<=0;direction_version_o<=0;rejected_o<=0;end
  else begin
   steer_start_o<=0;
   if(!enable_i||fault_i)state<=0;
   else case(state)
    0:if(result_valid_i)begin
     if(result_grid_i<1024&&result_score_i>0)begin target<=result_grid_i;version<=result_version_i;state<=1;end
     else rejected_o<=rejected_o+1;
    end
    1:if(!steer_busy_i&&steer_bus_idle_i)begin steer_start_o<=1;steer_target_o<=target;state<=2;end
    2:if(steer_busy_i)state<=3;
    3:if(!steer_busy_i)begin
      if(steer_locked_i&&steer_committed_i==target)begin
       direction_comp_o<=steer_comp_i;direction_id_o<=target;direction_version_o<=version;state<=4;
      end else state<=0;
    end
    4:if(direction_ready_i)state<=0;
    default:state<=0;
   endcase
   if(enable_i&&!fault_i&&state!=0&&result_valid_i)rejected_o<=rejected_o+1;
  end
 end
endmodule
