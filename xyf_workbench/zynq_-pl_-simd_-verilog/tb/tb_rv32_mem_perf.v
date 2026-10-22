`timescale 1ns/1ps
module tb_rv32_mem_perf;
parameter CASE_COUNT=76;
reg clk=0,rst=0; always #12.5 clk=~clk;
reg cw=0;reg[8:0] ci=0;reg[287:0] pcm=0;reg av=0;
reg cfgwr=0;
reg finished=0;
integer csr_events=0,exported_events=0,held_wb_events=0;
reg[31:0] golden[0:4095],expected_load[0:40000],load_pc[0:40000];
integer qwr=0,qrd=0,byte_k,offset,cap_index=0,audio_in=0,audio_out=0;
integer tr_rd=0,tr_case[0:40000],tr_req[0:40000],tr_acc[0:40000],tr_rsp[0:40000];
reg[31:0] tr_pc[0:40000],tr_addr[0:40000];reg tr_write[0:40000];
reg[31:0] expected_word,expected_value;reg[2:0] expected_led=0;
wire rv;wire[31:0] rpc,ri,host;wire[3:0] fault;wire hostwe;
rv32_soc #(.DAS_ACTIVE_CHANNELS(12)) dut(
 .clk_i(clk),.rst_n_i(rst),.test_en_i(1'b0),.halt_i(1'b0),
 .retire_valid_o(rv),.retire_pc_o(rpc),.retire_instr_o(ri),.retire_fault_o(fault),
 .tohost_o(host),.tohost_we_o(hostwe),.fromhost_i(32'h12345678),
 .ps_req_i(1'b0),.ps_write_i(1'b0),.ps_sel_i(1'b0),.ps_addr_i(0),.ps_wdata_i(0),
 .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),.coef_idx_i(ci),.coef_wdata_i(16'b0),
 .steer_cfg_wr_i(1'b0),.steer_cfg_rd_i(1'b0),.steer_cfg_addr_i(7'b0),.steer_cfg_wdata_i(0),
 .pdm_cfg_wr_i(cfgwr),.pdm_cfg_rd_i(1'b0),.pdm_cfg_addr_i(7'd32),.pdm_cfg_wdata_i(32'd5),.tacho_i(1'b0),.pdm_din_i(6'b0));
reg[31:0] tags[0:4095],ends[0:4095];
integer first[0:76],last[0:76],rq[0:76],acc[0:76],comp[0:76],dw[0:76],mw[0:76],swait[0:76],st[0:76],lu[0:76],ret[0:76],loads[0:76],stores[0:76],writes[0:76];
integer i,k,j,cy=0,fd,tf,errors=0,request_cycle,accept_cycle,transaction_id=0;
reg pending=0;reg[31:0] addr,wd;reg[3:0] strb;reg direction;
initial begin
 fd=$fopen("build/rv32_mem_perf/counters.csv","w");tf=$fopen("build/rv32_mem_perf/transactions.csv","w");
 $fdisplay(fd,"id,elapsed,req_cycles,accept,complete,dtcm_wait,mmio_wait,scratch_wait,lsu_stall,load_use_overlap,retired,retired_load,retired_store,write_pulses");
 $fdisplay(tf,"transaction,id,pc,address,write,request_cycle,accept_cycle,response_cycle,retire_cycle");
 for(i=0;i<4096;i=i+1)begin dut.u_itcm.memory[i]=32'h13;dut.u_dtcm.memory[i]=32'h80ff80ff;golden[i]=32'h80ff80ff;end
 for(i=0;i<3072;i=i+1)dut.u_pdm_cap.memory[i]=32'h80000000+i;
 for(i=0;i<=76;i=i+1)begin first[i]=0;last[i]=0;rq[i]=0;acc[i]=0;comp[i]=0;dw[i]=0;mw[i]=0;swait[i]=0;st[i]=0;lu[i]=0;ret[i]=0;loads[i]=0;stores[i]=0;writes[i]=0;end
 $readmemh("build/rv32_mem_perf/itcm.hex",dut.u_itcm.memory);
 $readmemh("build/rv32_mem_perf/tags.hex",tags);$readmemh("build/rv32_mem_perf/ends.hex",ends);
 force dut.u_pdm_cap.ready_q=2'b01;
 force dut.pdm_aligned=pcm;force dut.pdm_valid_aligned=av;
 #100 rst=1;
 for(i=0;i<32;i=i+1)begin @(negedge clk);cw=1;ci=i;end
 @(negedge clk);cw=0;cfgwr=1;@(negedge clk);cfgwr=0;
end
always @(negedge clk)if(rst)begin
 av=!finished && cy>1024 && cy%1024==0;
 if(av)audio_in=audio_in+1;
end
always @(posedge clk)if(rst)begin
 if(dut.u_core.memwb_valid)csr_events=csr_events+1;
 if(rv)exported_events=exported_events+1;
 if(dut.u_core.memwb_valid && dut.u_core.memory_stall)held_wb_events=held_wb_events+1;
 if(dut.beam_fir_valid)begin audio_out=audio_out+1;if(dut.beam_fir_sample!==0)begin $display("AUDIO_DATA_FAIL");errors=errors+1;end end
 if(dut.dmem_req && dut.dmem_write && !dut.dmem_mmio && !dut.scratch_sel)
  for(byte_k=0;byte_k<4;byte_k=byte_k+1)if(dut.dmem_wstrb[byte_k])golden[dut.dmem_addr[13:2]][byte_k*8+:8]=dut.dmem_wdata[byte_k*8+:8];
 if(dut.mmio_write && dut.mmio_gpio)expected_led=dut.dmem_wdata[2:0];
 if(dut.u_pdm_cap.cfg_wr_i && dut.u_pdm_cap.cfg_addr_i==7)cap_index=dut.u_pdm_cap.cfg_wdata_i;
 cy=cy+1;k=tags[dut.u_core.exmem_pc[13:2]];
 if(dut.u_core.exmem_valid && k!=0)begin
  if(first[k]==0)first[k]=cy;last[k]=cy;
  if(dut.dmem_req)rq[k]=rq[k]+1;
  if(dut.u_core.memory_stall)begin st[k]=st[k]+1;
   if(dut.dmem_mmio)mw[k]=mw[k]+1;else if(dut.scratch_sel)swait[k]=swait[k]+1;else dw[k]=dw[k]+1;
  end
  if(dut.u_core.load_use_stall)lu[k]=lu[k]+1;
  if(dut.dmem_req && !pending)begin
   pending=1;addr=dut.dmem_addr;wd=dut.dmem_wdata;strb=dut.dmem_wstrb;direction=dut.u_core.exmem_mem_write;
   request_cycle=cy;accept_cycle=direction && dut.dmem_mmio ? cy+1:cy;acc[k]=acc[k]+1;
  end
  if(pending && dut.dmem_req)begin
   if(addr!==dut.dmem_addr || (direction && (wd!==dut.dmem_wdata || strb!==dut.dmem_wstrb)))begin $display("UNSTABLE_REQUEST");errors=errors+1;end
   if(dut.dmem_ready)begin
    if(!direction)begin
     expected_word=!dut.dmem_mmio ? golden[addr[13:2]] : addr==32'h4004 ? 32'h12345678 : addr==32'h5000 ? {29'b0,expected_led} : addr==32'hc020 ? 32'h80000000+cap_index : addr==32'hc004 ? dut.u_pdm_cap.cfg_rdata_o : 0;
     offset=dut.u_core.exmem_alu_result[1:0]*8;expected_word=expected_word>>offset;
     case(dut.u_core.exmem_mem_size)
      0:expected_value=dut.u_core.exmem_load_unsigned ? {24'b0,expected_word[7:0]}:{{24{expected_word[7]}},expected_word[7:0]};
      1:expected_value=dut.u_core.exmem_load_unsigned ? {16'b0,expected_word[15:0]}:{{16{expected_word[15]}},expected_word[15:0]};
      default:expected_value=expected_word;
     endcase
     expected_load[qwr]=expected_value;load_pc[qwr]=dut.u_core.exmem_pc;qwr=qwr+1;
    end
    comp[k]=comp[k]+1;transaction_id=transaction_id+1;
    tr_case[transaction_id-1]=k;tr_pc[transaction_id-1]=dut.u_core.exmem_pc;tr_addr[transaction_id-1]=addr;
    tr_write[transaction_id-1]=direction;tr_req[transaction_id-1]=request_cycle;tr_acc[transaction_id-1]=direction?cy:request_cycle;tr_rsp[transaction_id-1]=cy;
    pending=0;
   end
  end
  if(dut.dmem_write && dut.dmem_req)writes[k]=writes[k]+1;
 end
 if(rv)begin
  if(fault!=0)begin $display("TRAP %h %h",rpc,fault);errors=errors+1;end
  j=tags[rpc[13:2]];
  if(j!=0)begin ret[j]=ret[j]+1;if(ri[6:0]==7'h03)loads[j]=loads[j]+1;if(ri[6:0]==7'h23)stores[j]=stores[j]+1;end
  if(j!=0 && (ri[6:0]==7'h03 || ri[6:0]==7'h23))begin
   if(tr_rd>=transaction_id || tr_pc[tr_rd]!==rpc)begin $display("RETIRE_TRANSACTION_ORDER_FAIL");errors=errors+1;end
   $fdisplay(tf,"%0d,%0d,%08x,%08x,%0d,%0d,%0d,%0d,%0d",tr_rd+1,tr_case[tr_rd],tr_pc[tr_rd],tr_addr[tr_rd],tr_write[tr_rd],tr_req[tr_rd],tr_acc[tr_rd],tr_rsp[tr_rd],cy);
   tr_rd=tr_rd+1;
  end
  if(j!=0 && ri[6:0]==7'h03)begin
   if(qrd>=qwr || load_pc[qrd]!==rpc || expected_load[qrd]!==dut.u_core.memwb_load_data)begin $display("LOAD_DATA_FAIL pc=%h got=%h expected=%h",rpc,dut.u_core.memwb_load_data,expected_load[qrd]);errors=errors+1;end
   qrd=qrd+1;
  end
  j=ends[rpc[13:2]];
  if(j!=0)begin
   $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",j,last[j]-first[j]+1,rq[j],acc[j],comp[j],dw[j],mw[j],swait[j],st[j],lu[j],ret[j],loads[j],stores[j],writes[j]);
   if(writes[j]!=stores[j] || comp[j]!=loads[j]+stores[j])begin $display("TRANSACTION_COUNT_FAIL id=%0d",j);errors=errors+1;end
  end
 end
 if(hostwe && host==32'h600dcafe)begin
  finished=1;
 end
 if(cy>1000000)begin $display("TIMEOUT");$finish;end
end
initial begin
 wait(finished);#4001;
 $display("CSR_RETIRE_AUDIT minstret=%0d csr_input_events=%0d exported_retire=%0d held_wb_events=%0d",dut.u_core.u_csr.minstret,csr_events,exported_events,held_wb_events);
 if(csr_events-exported_events!=held_wb_events || dut.u_core.u_csr.minstret!==exported_events)$fatal(1,"CSR retirement must match one-shot export");
 $fclose(fd);
 fd=$fopen("build/rv32_mem_perf/raw_rdcycle.csv","w");$fdisplay(fd,"id,rdcycle");
 for(i=1;i<=CASE_COUNT;i=i+1)$fdisplay(fd,"%0d,%0d",i,dut.u_dtcm.memory['ha00+i-1]);
 $fclose(fd);
 if(dut.u_beam.drop_q!=0 || audio_out!=audio_in || qrd!=qwr || tr_rd!=transaction_id)errors=errors+1;
 $display("MEM_AUDIO samples_in=%0d samples_out=%0d drops=%0d max_ticks=%0d",audio_in,audio_out,dut.u_beam.drop_q,dut.u_beam.max_ticks);
 $fclose(tf);if(errors==0)$display("RV32_MEM_PERF_PASS cycles=%0d transactions=%0d",cy,transaction_id);else $display("RV32_MEM_PERF_FAIL errors=%0d",errors);$finish;
end
endmodule
