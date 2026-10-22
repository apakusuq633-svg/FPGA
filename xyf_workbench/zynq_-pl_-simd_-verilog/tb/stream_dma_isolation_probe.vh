// Simulation-only probe appended inside tb_localizer12_safety, never product RTL.
reg[2:0]dma_cfg_step;reg dma_aw_sent,dma_w_sent;
reg[11:0]dma_cfg_addr;reg[31:0]dma_cfg_data;
wire dma_cfg_done=dma_cfg_step==5;
wire dma_awready,dma_wready,dma_bvalid;wire[1:0]dma_bresp;
wire dma_awvalid=!dma_cfg_done&&!dma_aw_sent;
wire dma_wvalid=!dma_cfg_done&&!dma_w_sent;
always @*case(dma_cfg_step)
 0:begin dma_cfg_addr=12'h008;dma_cfg_data=32'h08000000;end
 1:begin dma_cfg_addr=12'h00c;dma_cfg_data=4;end
 2:begin dma_cfg_addr=12'h028;dma_cfg_data=64;end
 3:begin dma_cfg_addr=12'h044;dma_cfg_data=2;end
 default:begin dma_cfg_addr=12'h004;dma_cfg_data=1;end
endcase
reg[31:0]dma_expected_inputs;
always @(posedge clk)begin
 if(!rst_n)begin dma_cfg_step<=0;dma_aw_sent<=0;dma_w_sent<=0;dma_expected_inputs<=0;end
 else begin
  if(gsc_valid&&gsc_ready)dma_expected_inputs<=dma_expected_inputs+1;
  if(dma_awvalid&&dma_awready)dma_aw_sent<=1;
  if(dma_wvalid&&dma_wready)dma_w_sent<=1;
  if(!dma_cfg_done&&dma_bvalid)begin
   if(dma_bresp!=0)$fatal(1,"DMA_PROBE_CONFIG_ERROR");
   dma_cfg_step<=dma_cfg_step+1;dma_aw_sent<=0;dma_w_sent<=0;
  end
 end
end
rv32_stream_dma dma_probe(.clk_i(clk),.rst_n_i(rst_n),
 .stream_valid_i(gsc_valid&&gsc_ready),.stream_ready_o(),.stream_data_i(gsc_data),.stream_timestamp_i(dut.gsc_timestamp_o),
 .s_axi_awaddr(dma_cfg_addr),.s_axi_awvalid(dma_awvalid),.s_axi_awready(dma_awready),
 .s_axi_wdata(dma_cfg_data),.s_axi_wstrb(4'hf),.s_axi_wvalid(dma_wvalid),.s_axi_wready(dma_wready),
 .s_axi_bresp(dma_bresp),.s_axi_bvalid(dma_bvalid),.s_axi_bready(1'b1),
 .s_axi_araddr(12'd0),.s_axi_arvalid(1'b0),.s_axi_arready(),.s_axi_rdata(),.s_axi_rresp(),.s_axi_rvalid(),.s_axi_rready(1'b1),
 .m_axi_awready(1'b0),.m_axi_wready(1'b1),.m_axi_bresp(2'b0),.m_axi_bvalid(1'b0),
 .m_axi_arready(1'b1),.m_axi_rdata(64'b0),.m_axi_rresp(2'b0),.m_axi_rlast(1'b0),.m_axi_rvalid(1'b0));
final begin
 if(!dma_cfg_done||!dma_probe.fault_q||dma_probe.state_q!=1||dma_probe.timeouts_q!=1||
    dma_probe.inputs_q!=dma_expected_inputs||dma_expected_inputs<1000||
    dma_probe.producer_q!=0||dma_probe.drops_q+1!=dma_expected_inputs)
   $fatal(1,"DMA_ISOLATION_COVERAGE inputs=%0d drops=%0d timeouts=%0d",dma_probe.inputs_q,dma_probe.drops_q,dma_probe.timeouts_q);
 $display("M9_DMA_ISOLATION_PASS inputs=%0d drops=%0d quarantined=1 timeouts=1 main_golden=PASS",dma_probe.inputs_q,dma_probe.drops_q);
end
