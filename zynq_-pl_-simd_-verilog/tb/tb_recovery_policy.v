`timescale 1ns/1ps
module tb_recovery_policy;
reg clk=0;always #12.5 clk=~clk;reg rst=0,fault=0,request=0,auto_en=0;
wire rearm;wire[2:0]state;wire[31:0]epoch,events,raw_total,window_total,first,gapend;
reg[31:0]sample=10;integer k;
rv32_localizer_recovery dut(.clk_i(clk),.rst_n_i(rst),.fault_i(fault),.request_i(request),.auto_enable_i(auto_en),
 .engines_idle_i(1'b1),.window_done_i(1'b1),.sample_seq_i(sample),.raw_drop_i(fault?32'd1:0),.window_drop_i(32'b0),
 .rearm_o(rearm),.state_o(state),.epoch_o(epoch),.fault_events_o(events),.total_raw_drop_o(raw_total),.total_window_drop_o(window_total),
 .first_fault_sample_o(first),.gap_end_sample_o(gapend));
initial begin
 repeat(4)@(negedge clk);rst=1;fault=1;repeat(20)@(negedge clk);
 if(epoch!=0||events!=1||state!=1)$fatal(1,"automatic recovery not disabled by default");
 auto_en=1;
 for(k=0;k<3;k=k+1)begin
  wait(rearm);@(negedge clk);fault=0;wait(state==0);repeat(4)@(negedge clk);sample=sample+10;fault=1;
 end
 repeat(20)@(negedge clk);
 if(epoch!=3||events!=4||state!=1||raw_total!=3||first!=10)$fatal(1,"retry budget or history lost");
 request=1;@(negedge clk);request=0;wait(rearm);@(negedge clk);fault=0;wait(state==0);
 if(epoch!=4||raw_total!=4||first!=10)$fatal(1,"manual acknowledgement failed");
 $display("RECOVERY_POLICY_PASS default_disabled=1 auto_retries=3 fourth_fault_latched=1 manual_ack=1 history_preserved=1");$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
