// Independent nonblocking tap -> 128-byte DDR ownership ring, one AXI burst/slot.
// Timeout quarantines a transaction but never withdraws AXI VALID or abandons it.
module rv32_stream_dma #(parameter FIFO_DEPTH=4, parameter ACTIVE_CHANNELS=12)(
 (* X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET rst_n_i, FREQ_HZ 40000000", X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 clk_i CLK" *) input clk_i,
 (* X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW", X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 rst_n_i RST" *) input rst_n_i,
 input stream_valid_i,output stream_ready_o,input[511:0]stream_data_i,input[63:0]stream_timestamp_i,
 input[11:0]s_axi_awaddr,input s_axi_awvalid,output s_axi_awready,
 input[31:0]s_axi_wdata,input[3:0]s_axi_wstrb,input s_axi_wvalid,output s_axi_wready,
 output[1:0]s_axi_bresp,output s_axi_bvalid,input s_axi_bready,
 input[11:0]s_axi_araddr,input s_axi_arvalid,output s_axi_arready,
 output[31:0]s_axi_rdata,output[1:0]s_axi_rresp,output s_axi_rvalid,input s_axi_rready,
 (* X_INTERFACE_PARAMETER="XIL_INTERFACENAME m_axi, PROTOCOL AXI4, ADDR_WIDTH 32, DATA_WIDTH 64, ID_WIDTH 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 16, FREQ_HZ 40000000" *)
 output[31:0]m_axi_awaddr,output[7:0]m_axi_awlen,output[2:0]m_axi_awsize,output[1:0]m_axi_awburst,
 output m_axi_awlock,output[3:0]m_axi_awcache,output[2:0]m_axi_awprot,output[3:0]m_axi_awqos,
 output m_axi_awvalid,input m_axi_awready,
 output reg[63:0]m_axi_wdata,output[7:0]m_axi_wstrb,output m_axi_wlast,output m_axi_wvalid,input m_axi_wready,
 input[1:0]m_axi_bresp,input m_axi_bvalid,output m_axi_bready,
 output[31:0]m_axi_araddr,output[7:0]m_axi_arlen,output[2:0]m_axi_arsize,output[1:0]m_axi_arburst,
 output m_axi_arlock,output[3:0]m_axi_arcache,output[2:0]m_axi_arprot,output[3:0]m_axi_arqos,
 output m_axi_arvalid,input m_axi_arready,input[63:0]m_axi_rdata,input[1:0]m_axi_rresp,
 input m_axi_rlast,input m_axi_rvalid,output m_axi_rready,output irq_o
);
 localparam QAW=$clog2(FIFO_DEPTH);
 localparam IDLE=3'd0,ADDRESS=3'd1,DATA=3'd2,RESPONSE=3'd3;
 reg[2:0]state_q;
 reg enabled_q,fault_q,timed_out_q;
 reg[31:0]base_q,producer_q,consumer_q,timeout_q,watchdog_q,calibration_q,last_fault_q;
 reg[3:0]slots_log2_q,beat_q;
 reg[31:0]drops_q,errors_q,timeouts_q,config_errors_q,inputs_q;
 reg[575:0]fifo[0:FIFO_DEPTH-1];reg[QAW-1:0]wp_q,rp_q;reg[QAW:0]count_q;
 reg[511:0]active_data_q;reg[63:0]active_time_q;
 reg[31:0]active_addr_q,active_seq_q,active_drops_q,active_calibration_q,crc_q;
 wire reg_wr,reg_rd;wire[11:0]reg_addr;wire[31:0]reg_wdata;wire[3:0]reg_wstrb;
 reg[31:0]reg_rdata_q;reg reg_rd_error_q;reg reg_wr_error;
 wire[31:0]capacity=32'd1<<slots_log2_q;
 wire[31:0]used=producer_q-consumer_q;
 wire quiescent=!enabled_q&&state_q==IDLE&&count_q==0&&producer_q==consumer_q;
 wire valid_base=base_q>=32'h01000000&&base_q<32'h10000000&&base_q[6:0]==0&&
                 base_q+(capacity<<7)<=32'h10000000;
 wire pop=state_q==IDLE&&enabled_q&&!fault_q&&count_q!=0&&used<capacity;
 wire push=stream_valid_i&&enabled_q&&!fault_q&&(count_q<FIFO_DEPTH||pop);
 wire flush=reg_wr&&!reg_wr_error&&reg_addr==12'h004&&reg_wdata[2];
 wire aw_fire=m_axi_awvalid&&m_axi_awready;
 wire w_fire=m_axi_wvalid&&m_axi_wready;
 wire b_fire=m_axi_bvalid&&m_axi_bready;
 wire failed_completion=b_fire&&(m_axi_bresp!=0||fault_q||timed_out_q);
 wire[31:0]drop_delta=(stream_valid_i&&!push?32'd1:32'd0)+(failed_completion?32'd1:32'd0)+
                     (flush?{{(31-QAW){1'b0}},count_q}:32'd0);
 function[31:0]sat_add;input[31:0]a,b;reg[32:0]t;
  begin t={1'b0,a}+{1'b0,b};sat_add=t[32]?32'hffffffff:t[31:0];end
 endfunction
 function[31:0]crc64;input[31:0]previous;input[63:0]data;reg[31:0]c;integer i;
  begin c=previous;for(i=0;i<64;i=i+1)begin
    if(c[0]^data[i])c=(c>>1)^32'hedb88320;else c=c>>1;
   end crc64=c;end
 endfunction
 assign stream_ready_o=1'b1; // never propagate DDR/network pressure into PCM/DAS
 assign irq_o=fault_q||producer_q!=consumer_q;
 assign m_axi_awaddr=active_addr_q;assign m_axi_awlen=8'd15;assign m_axi_awsize=3'd3;
 assign m_axi_awburst=2'b01;assign m_axi_awlock=0;assign m_axi_awcache=4'b0011;
 assign m_axi_awprot=0;assign m_axi_awqos=0;assign m_axi_awvalid=state_q==ADDRESS;
 assign m_axi_wstrb=8'hff;assign m_axi_wlast=beat_q==15;assign m_axi_wvalid=state_q==DATA;
 assign m_axi_bready=state_q==RESPONSE;
 assign m_axi_araddr=0;assign m_axi_arlen=0;assign m_axi_arsize=3;
 assign m_axi_arburst=1;assign m_axi_arlock=0;assign m_axi_arcache=3;
 assign m_axi_arprot=0;assign m_axi_arqos=0;assign m_axi_arvalid=0;assign m_axi_rready=1;
 always @*begin
  if(beat_q<8)m_axi_wdata=active_data_q[beat_q*64+:64];
  else case(beat_q)
   8:m_axi_wdata=active_time_q;
   9:m_axi_wdata={active_drops_q,active_seq_q};
   10:m_axi_wdata={32'd128,32'h394d4450};
   11:m_axi_wdata={(ACTIVE_CHANNELS==9?32'h00100009:32'h0010000c),active_calibration_q};
   15:m_axi_wdata={~active_seq_q,~crc_q};
   default:m_axi_wdata=0;
  endcase
 end
 always @*begin
  reg_wr_error=reg_addr[1:0]!=0||reg_wstrb!=4'hf;
  case(reg_addr)
   12'h004:begin
    if(reg_wdata&32'hfffffff8)reg_wr_error=1;
    if(reg_wdata[0]&&(!valid_base||fault_q))reg_wr_error=1;
    if((reg_wdata[1]||reg_wdata[2])&&(enabled_q||state_q!=IDLE))reg_wr_error=1;
   end
   12'h008:if(!quiescent||reg_wdata[6:0]!=0||reg_wdata<32'h01000000||
                 reg_wdata>=32'h10000000||reg_wdata+(capacity<<7)>32'h10000000)reg_wr_error=1;
   12'h00c:if(!quiescent||reg_wdata<4||reg_wdata>12||
                 (base_q!=0&&base_q+((32'd1<<reg_wdata)<<7)>32'h10000000))reg_wr_error=1;
   12'h010:if(reg_wdata-consumer_q>used)reg_wr_error=1;
   12'h028:if(!quiescent||reg_wdata<16)reg_wr_error=1;
   12'h040,12'h044:if(!quiescent)reg_wr_error=1;
   default:reg_wr_error=1;
  endcase
 end
 wire counter_saturated=drops_q==32'hffffffff||errors_q==32'hffffffff||timeouts_q==32'hffffffff||
                         inputs_q==32'hffffffff||config_errors_q==32'hffffffff;
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin reg_rdata_q<=0;reg_rd_error_q<=0;end
  else if(reg_rd)begin
   reg_rd_error_q<=reg_addr[1:0]!=0;
   case(reg_addr)
    12'h000:reg_rdata_q<=32'h394d4450;
    12'h004:reg_rdata_q<={31'b0,enabled_q};
    12'h008:reg_rdata_q<=base_q;
    12'h00c:reg_rdata_q<={28'b0,slots_log2_q};
    12'h010:reg_rdata_q<=consumer_q;
    12'h014:reg_rdata_q<=producer_q;
    12'h018:reg_rdata_q<=drops_q;
    12'h01c:reg_rdata_q<=errors_q;
    12'h020:reg_rdata_q<=timeouts_q;
    12'h024:reg_rdata_q<={23'b0,counter_saturated,{{(3-QAW-1){1'b0}},count_q},fault_q,enabled_q,state_q};
    12'h028:reg_rdata_q<=timeout_q;
    12'h02c:reg_rdata_q<=config_errors_q;
    12'h030:reg_rdata_q<=inputs_q;
    12'h034:reg_rdata_q<=count_q;
    12'h038:reg_rdata_q<=last_fault_q;
    12'h03c:reg_rdata_q<=used;
    12'h040:reg_rdata_q<=producer_q;
    12'h044:reg_rdata_q<=calibration_q;
    12'h048:reg_rdata_q<=ACTIVE_CHANNELS==9?32'h000a0009:32'h000c000c;
    default:begin reg_rdata_q<=0;reg_rd_error_q<=1;end
   endcase
  end
 end
 rv32_axi_lite_slave control(.clk_i(clk_i),.rst_n_i(rst_n_i),
  .s_axi_awaddr(s_axi_awaddr),.s_axi_awvalid(s_axi_awvalid),.s_axi_awready(s_axi_awready),
  .s_axi_wdata(s_axi_wdata),.s_axi_wstrb(s_axi_wstrb),.s_axi_wvalid(s_axi_wvalid),.s_axi_wready(s_axi_wready),
  .s_axi_bresp(s_axi_bresp),.s_axi_bvalid(s_axi_bvalid),.s_axi_bready(s_axi_bready),
  .s_axi_araddr(s_axi_araddr),.s_axi_arvalid(s_axi_arvalid),.s_axi_arready(s_axi_arready),
  .s_axi_rdata(s_axi_rdata),.s_axi_rresp(s_axi_rresp),.s_axi_rvalid(s_axi_rvalid),.s_axi_rready(s_axi_rready),
  .reg_wr_o(reg_wr),.reg_addr_o(reg_addr),.reg_wdata_o(reg_wdata),.reg_wstrb_o(reg_wstrb),
  .reg_rd_o(reg_rd),.reg_rdata_i(reg_rdata_q),.reg_wr_err_i(reg_wr_error),.reg_rd_err_i(reg_rd_error_q));
 always @(posedge clk_i)if(push)fifo[wp_q]<={stream_timestamp_i,stream_data_i};
 always @(posedge clk_i or negedge rst_n_i)begin
  if(!rst_n_i)begin
   state_q<=IDLE;enabled_q<=0;fault_q<=0;timed_out_q<=0;wp_q<=0;rp_q<=0;count_q<=0;
   base_q<=0;slots_log2_q<=4;producer_q<=0;consumer_q<=0;calibration_q<=0;
   timeout_q<=40000000;watchdog_q<=0;last_fault_q<=0;
   drops_q<=0;errors_q<=0;timeouts_q<=0;config_errors_q<=0;inputs_q<=0;
   active_data_q<=0;active_time_q<=0;active_addr_q<=0;active_seq_q<=0;active_drops_q<=0;active_calibration_q<=0;
   beat_q<=0;crc_q<=32'hffffffff;
  end else begin
   drops_q<=sat_add(drops_q,drop_delta);
   if(stream_valid_i)inputs_q<=sat_add(inputs_q,1);
   if(reg_wr&&reg_wr_error)config_errors_q<=sat_add(config_errors_q,1);
   if(flush)begin wp_q<=0;rp_q<=0;count_q<=0;end
   else begin
    if(push)wp_q<=wp_q+1'b1;
    if(pop)rp_q<=rp_q+1'b1;
    case({push,pop})2'b10:count_q<=count_q+1'b1;2'b01:count_q<=count_q-1'b1;default:;endcase
   end
   if(reg_wr&&!reg_wr_error)case(reg_addr)
    12'h004:begin
     enabled_q<=reg_wdata[0];
     if(reg_wdata[1])begin fault_q<=0;last_fault_q<=0;end
    end
    12'h008:base_q<=reg_wdata;
    12'h00c:slots_log2_q<=reg_wdata[3:0];
    12'h010:consumer_q<=reg_wdata;
    12'h028:timeout_q<=reg_wdata;
    12'h040:begin producer_q<=reg_wdata;consumer_q<=reg_wdata;end
    12'h044:calibration_q<=reg_wdata;
    default:;
   endcase
   if(state_q!=IDLE&&!timed_out_q)begin
    if(aw_fire||w_fire||b_fire)watchdog_q<=0;
    else if(watchdog_q>=timeout_q-1)begin
     timed_out_q<=1;fault_q<=1;last_fault_q<=last_fault_q|32'h100;
     timeouts_q<=sat_add(timeouts_q,1);
    end else watchdog_q<=watchdog_q+1'b1;
   end
   case(state_q)
    IDLE:if(pop)begin
     active_data_q<=fifo[rp_q][511:0];active_time_q<=fifo[rp_q][575:512];
     active_addr_q<=base_q+((producer_q&(capacity-1))<<7);
     active_seq_q<=producer_q;active_drops_q<=drops_q;active_calibration_q<=calibration_q;
     state_q<=ADDRESS;beat_q<=0;crc_q<=32'hffffffff;watchdog_q<=0;timed_out_q<=0;
    end
    ADDRESS:if(aw_fire)state_q<=DATA;
    DATA:if(w_fire)begin
     if(beat_q<15)crc_q<=crc64(crc_q,m_axi_wdata);
     if(beat_q==15)state_q<=RESPONSE;else beat_q<=beat_q+1'b1;
    end
    RESPONSE:if(b_fire)begin
     if(m_axi_bresp!=0)begin fault_q<=1;last_fault_q<=last_fault_q|{30'b0,m_axi_bresp};errors_q<=sat_add(errors_q,1);end
     if(!failed_completion)producer_q<=producer_q+1'b1;
     state_q<=IDLE;
    end
    default:begin state_q<=IDLE;fault_q<=1;last_fault_q<=32'h80000000;end
   endcase
  end
 end
endmodule
