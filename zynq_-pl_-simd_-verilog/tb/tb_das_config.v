`timescale 1ns/1ps
module tb_das_config;
reg clk=0;always #12.5 clk=~clk;reg rst=0,wr=0,dv=0;reg[4:0]a=0;reg[31:0]d=0;wire[31:0]q;wire ready;
rv32_das_stream #(.ACTIVE_CHANNELS(12)) dut(.clk_i(clk),.rst_n_i(rst),.pcm_i(288'b0),.valid_i(1'b0),
 .steer_comp_i(384'b0),.steer_locked_i(1'b0),.steer_busy_i(1'b0),.cfg_wr_i(wr),.cfg_rd_i(1'b0),.cfg_addr_i(a),.cfg_wdata_i(d),.cfg_rdata_o(q),
 .fir_ready_i(1'b1),.fir_done_i(1'b0),.fir_result_i(16'b0),.link_enable_i(1'b1),.direction_fault_i(1'b0),
 .direction_valid_i(dv),.direction_comp_i({12{32'h003e0000}}),.direction_version_i(32'd1),.direction_id_i(10'd1),.sample_seq_i(32'b0),.direction_ready_o(ready));
task write;input[4:0]addr;input[31:0]value;begin @(negedge clk);a=addr;d=value;wr=1;@(negedge clk);wr=0;end endtask
initial begin
 repeat(4)@(negedge clk);rst=1;write(8,32'h003e0000);write(0,9);a=0;#1;
 if(q[3])$fatal(1,"cubic accepted an incompatible existing delay");
 a=1;#1;if(!q[2])$fatal(1,"invalid mode change was silent");
 rst=0;repeat(3)@(negedge clk);rst=1;
 @(negedge clk);a=0;d=9;wr=1;dv=1;#1;if(ready)$fatal(1,"mode change and command accepted together");
 @(negedge clk);wr=0;dv=0;
 if(dut.pending_direction)$fatal(1,"unvalidated pending delay");
 $display("DAS_CONFIG_PASS incompatible_mode_rejected=1 simultaneous_command_serialized=1");$finish;
end
endmodule
