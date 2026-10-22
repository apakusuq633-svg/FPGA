`timescale 1ns/1ps
module tb_integrated_direction;
parameter SMOOTH=1;
reg clk=0;always #12.5 clk=~clk;reg rst=0,run=0,fault=0;
reg rv=0;reg[9:0]grid=585;reg[31:0]version=0;reg signed[31:0]score=100;
reg sw=0;reg[6:0]sa=0;reg[31:0]sd=0;wire sb,locked,ls,dv,dr,ap,trusted,transition;
wire[9:0]lt,comm,did,aid;wire[383:0]comp,dc;wire[31:0]ver,rejects,aver,eff,aseq,delay;
rv32_direction_link link(.clk_i(clk),.rst_n_i(rst),.enable_i(1'b1),.fault_i(fault),
 .result_valid_i(rv),.result_grid_i(grid),.result_version_i(version),.result_score_i(score),
 .steer_busy_i(sb),.steer_locked_i(locked),.steer_bus_idle_i(!sw),.steer_committed_i(comm),.steer_comp_i(comp),
 .steer_start_o(ls),.steer_target_o(lt),.direction_valid_o(dv),.direction_ready_i(dr),.direction_comp_o(dc),
 .direction_id_o(did),.direction_version_o(ver),.rejected_o(rejects));
rv32_steer_regs #(.N_GRID(1024),.GRID_W(32),.N_MIC(12)) steer(.clk_i(clk),.rst_n_i(rst),
 .core_start_i(1'b0),.core_wr_i(1'b0),.core_rd_i(1'b0),.core_addr_i(7'b0),.core_wdata_i(32'b0),
 .ps_wr_i(sw),.ps_rd_i(1'b0),.ps_addr_i(sa),.ps_wdata_i(sd),.busy_o(sb),.comp_o(comp),.locked_o(locked),
 .link_start_i(ls),.link_target_i(lt),.committed_grid_o(comm));
reg valid=0,wr=0,rd=0;reg[4:0]addr=0;reg[31:0]data=0;reg[287:0]pcm=0;reg[31:0]seq=0;
wire av;wire[15:0]sample;reg done=0;reg[15:0]result=0;wire[31:0]q;
rv32_das_stream #(.ACTIVE_CHANNELS(12)) beam(.clk_i(clk),.rst_n_i(rst),.pcm_i(pcm),.valid_i(valid),
 .steer_comp_i(comp),.steer_locked_i(locked),.steer_busy_i(sb),.cfg_wr_i(wr),.cfg_rd_i(rd),.cfg_addr_i(addr),.cfg_wdata_i(data),.cfg_rdata_o(q),
 .fir_valid_o(av),.fir_sample_o(sample),.fir_ready_i(1'b1),.fir_done_i(done),.fir_result_i(result),
 .link_enable_i(1'b1),.direction_fault_i(fault),.direction_valid_i(dv),.direction_comp_i(dc),
 .direction_version_i(ver),.direction_id_i(did),.sample_seq_i(seq),.direction_ready_o(dr),.direction_applied_o(ap),
 .direction_version_o(aver),.direction_id_o(aid),.effective_sample_seq_o(eff),.audio_sample_seq_o(aseq),
 .group_delay_q16_o(delay),.transitioning_o(transition),.direction_trusted_o(trusted));
always @(posedge clk)begin done<=av;if(av)result<=sample;end
reg[31:0]lut[0:12287];integer n,m,t,changes=0;reg[31:0]lastver=0;reg[21:0]prevdelay[0:11];real x;
integer checked_channel,packed_tau,min_tau;integer tau_values[0:11];
always @(posedge clk)if(rst&&dv&&dr)begin
 min_tau=2147483647;
 for(checked_channel=0;checked_channel<12;checked_channel=checked_channel+1)begin
  packed_tau=lut[checked_channel*1024+did]&16383;
  if(packed_tau>=8192)packed_tau=packed_tau-16384;
  tau_values[checked_channel]=packed_tau*4096;
  if(tau_values[checked_channel]<min_tau)min_tau=tau_values[checked_channel];
 end
 for(checked_channel=0;checked_channel<12;checked_channel=checked_channel+1)
  if(dc[checked_channel*32+:32]!==tau_values[checked_channel]-min_tau)
   $fatal(1,"committed direction delay mismatch version=%0d grid=%0d ch=%0d",ver,did,checked_channel);
end
task s_write;input[6:0]a;input[31:0]v;begin @(negedge clk);sa=a;sd=v;sw=1;@(negedge clk);sw=0;end endtask
task request;input[9:0]g;begin
 wait(link.state==0);@(negedge clk);grid=g;version=version+1;rv=1;@(negedge clk);rv=0;
 wait(link.state==0);repeat(3)@(negedge clk);
end endtask
initial begin
 $readmemh("STEER_LUT",lut);repeat(4)@(negedge clk);rst=1;
 s_write(6,32'h00010100);s_write(2,0);for(m=0;m<12288;m=m+1)s_write(3,lut[m]);
 @(negedge clk);addr=0;data=SMOOTH?25:9;wr=1;@(negedge clk);wr=0;run=1;
 repeat(8)request(585);wait(seq>=100);repeat(8)request(64);
 wait(seq>=250);repeat(8)request(900);
 wait(seq>=350);score=0;request(900);score=100;
 wait(seq>=400);fault=1;repeat(4)request(4); // requests are suppressed while fault is latched
end
initial begin
 for(m=0;m<12;m=m+1)prevdelay[m]=0;
 wait(run);
 for(n=0;n<512;n=n+1)begin
  @(negedge clk);seq=n;x=9000*$sin(6.283185307179586*1000*n/39062.5);
  for(integer ch=0;ch<12;ch=ch+1)pcm[ch*24+:24]=$rtoi(x)*256;
  valid=1;@(negedge clk);valid=0;t=0;
  while(!done&&t<1024)begin @(negedge clk);t=t+1;end
  if(t==1024)$fatal(1,"deadline");
  if(aseq!=n)$fatal(1,"sample sequence");
  if(aver!=lastver)begin
   if(eff!=n||aver<lastver)$fatal(1,"atomic metadata");changes=changes+1;lastver=aver;
  end
  for(integer ch=0;ch<12;ch=ch+1)begin
   if(SMOOTH&&(beam.snap[ch]>prevdelay[ch]+4096||prevdelay[ch]>beam.snap[ch]+4096))$fatal(1,"slew bound");
   prevdelay[ch]=beam.snap[ch];
  end
  if(fault&&trusted)$fatal(1,"fault direction trusted");
  $display("DIRECTION_AUDIO seq=%0d pcm=%0d version=%0d effective=%0d transition=%0d trusted=%0d",n,$signed(sample),aver,eff,transition,trusted);
  repeat(3)@(negedge clk);addr=3;rd=1;@(negedge clk);rd=0;
  repeat(1024-t-6)@(negedge clk);
 end
 addr=4;#1;if(q!=0)$fatal(1,"audio loss");
 if(changes<3||rejects!=1)$fatal(1,"link not exercised changes=%0d rejects=%0d",changes,rejects);
 $display("INTEGRATED_DIRECTION_PASS samples=512 changes=%0d",changes);$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
