// Independent microphone histories; steering is snapshotted once per sample vector.
// CTRL bit3 selects cubic Lagrange (one extra common sample of causal delay).
module rv32_das_stream #(parameter integer ACTIVE_CHANNELS = 8,
  parameter integer CHANNELS = ACTIVE_CHANNELS == 4 ? 8 : ACTIVE_CHANNELS) (
  input clk_i, input rst_n_i,
  input [CHANNELS*24-1:0] pcm_i, input valid_i,
  input [CHANNELS*32-1:0] steer_comp_i, input steer_locked_i, input steer_busy_i,
  input cfg_wr_i, input cfg_rd_i, input [4:0] cfg_addr_i,
  input [31:0] cfg_wdata_i, output reg [31:0] cfg_rdata_o,
  output fir_valid_o, output signed [15:0] fir_sample_o,
  input fir_ready_i, input fir_done_i, input signed [15:0] fir_result_i,
  input link_enable_i,input direction_fault_i,input direction_valid_i,input [CHANNELS*32-1:0] direction_comp_i,
  input [31:0] direction_version_i,input [9:0] direction_id_i,input [31:0] sample_seq_i,
  output direction_ready_o,output reg direction_applied_o,
  output reg [31:0] direction_version_o,output reg [9:0] direction_id_o,
  output reg [31:0] effective_sample_seq_o,output reg [31:0] audio_sample_seq_o,
  output reg [31:0] group_delay_q16_o,output reg transitioning_o,output reg direction_trusted_o
);
  localparam IDLE=0, WRITE=1, READ0=2, WAIT0=3, READ1=4,
             WAIT1=5, ADD=6, EMIT=7, FIR=8;
  reg [3:0] state;
  reg enable_q, auto_q, error_q, steer_seen, cubic_q, cubic_snap;
  reg smooth_q,pending_direction;
  reg [31:0] pending_version;
  reg [9:0] pending_id;
  reg [21:0] target_delay[0:CHANNELS-1];
  reg [21:0] snap [0:CHANNELS-1];
  reg [21:0] delay_q [0:CHANNELS-1];
  reg direction_range_ok,cubic_range_ok;
  reg [21:0] group_max_delay;
  integer dc;
  always @*begin
    direction_range_ok=1;
    cubic_range_ok=1;
    for(dc=0;dc<CHANNELS;dc=dc+1)begin
      if(direction_comp_i[dc*32+:32]>=(cubic_q?32'h003d0000:32'h003f0000))direction_range_ok=0;
      if(delay_q[dc]>=22'h3d0000||target_delay[dc]>=22'h3d0000||snap[dc]>=22'h3d0000)cubic_range_ok=0;
    end
  end
  assign direction_ready_o=!pending_direction&&!(cfg_wr_i&&cfg_addr_i==0)&&direction_fault_i!==1'b1;
  function [21:0] next_delay;input[21:0]current_delay,wanted;input smooth;
    begin
      if(!smooth)next_delay=wanted;
      else if(wanted>current_delay&&wanted-current_delay>4096)next_delay=current_delay+4096;
      else if(current_delay>wanted&&current_delay-wanted>4096)next_delay=current_delay-4096;
      else next_delay=wanted;
    end
  endfunction
  reg [$clog2(CHANNELS)-1:0] ch;
  reg [5:0] head;
  reg [6:0] valid_len;
  reg [CHANNELS*16-1:0] samples;
  reg signed [15:0] history [0:CHANNELS*64-1];
  reg [$clog2(CHANNELS)+5:0] read_addr;
  wire delay_addr_valid = (cfg_addr_i >= 8 && cfg_addr_i < 16) ||
                         (CHANNELS > 8 && cfg_addr_i >= 24 && cfg_addr_i < 24+CHANNELS-8);
  wire [3:0] delay_channel = (cfg_addr_i >= 24 ? 8 : 0) + cfg_addr_i[2:0];
  reg signed [15:0] read_q, v0, v1, das_q;
  reg signed [15:0] v2,v3;
  reg [1:0] tap;
  reg signed [35:0] cubic_acc;
  `include "beamformer/das_lagrange_coeff.vh"
  wire signed [15:0] tap_value=tap==0?v0:tap==1?v1:tap==2?v2:v3;
  wire signed [15:0] tap_coeff=lagrange_coeff(snap[ch][15:12],tap);
  wire signed [31:0] tap_product=tap_value*tap_coeff;
  wire signed [35:0] cubic_total=cubic_acc+{{4{tap_product[31]}},tap_product};
  wire signed [35:0] cubic_rounded=cubic_total<0 ? -((-cubic_total+36'sd8192)>>>14) : (cubic_total+36'sd8192)>>>14;
  wire signed [20:0] cubic_value=cubic_rounded>32767?21'sd32767:cubic_rounded< -32768?-21'sd32768:cubic_rounded[20:0];
  reg signed [20:0] sum;
  reg [31:0] accepted_q, output_q, drop_q, ticks, max_ticks;
  reg [31:0] fifo [0:255];
  reg [7:0] wr_ptr, rd_ptr;
  reg [8:0] count;
  wire pop = cfg_rd_i && cfg_addr_i == 5'd3 && count != 0;
  wire push = state == FIR && fir_done_i && (count < 256 || pop);
  wire input_drop = enable_q && valid_i && state != IDLE;
  wire fifo_drop = state == FIR && fir_done_i && !push;
  wire clear = cfg_wr_i && cfg_addr_i == 0 && cfg_wdata_i[1] &&
               !enable_q && state == IDLE && accepted_q == 0;
  wire signed [16:0] difference = {v1[15],v1} - {v0[15],v0};
  wire signed [21:0] correction = difference * $signed({1'b0,snap[ch][15:12]});
  wire signed [21:0] interpolated = $signed(v0) + (correction >>> 4);
  wire signed [21:0] rounded_sum = $signed(sum) + 22'sd6;
  wire signed [21:0] average12 = rounded_sum < 0 ?
      -((-rounded_sum + 22'sd11) / 22'sd12) : rounded_sum / 22'sd12;
  wire signed [21:0] average = ACTIVE_CHANNELS == 12 ? average12 : ACTIVE_CHANNELS == 16 ?
      ($signed(sum) + 22'sd8) >>> 4 : ACTIVE_CHANNELS == 4 ?
      ($signed(sum) + 21'sd2) >>> 2 : ($signed(sum) + 21'sd4) >>> 3;
  wire [5:0] idx0 = head - snap[ch][21:16];
  wire [5:0] idx1 = idx0 - 1'b1;
  wire [6:0] age0 = {1'b0,snap[ch][21:16]};
  wire [6:0] age1 = age0 + 1'b1;
  assign fir_valid_o = state == EMIT;
  assign fir_sample_o = das_q;
  always @(posedge clk_i) begin
    read_q <= history[read_addr];
    if (state == WRITE) history[{ch,head}] <= samples[ch*16 +: 16];
    if (push) fifo[wr_ptr] <= {fir_result_i,das_q};
  end
  integer m;
  // RAM address/write controls use synchronous reset, not asynchronous RAM pins.
  always @(posedge clk_i) begin
    if (!rst_n_i) begin
      state<=IDLE; enable_q<=0; auto_q<=1; error_q<=0; steer_seen<=0;cubic_q<=0;cubic_snap<=0;
      v2<=0;v3<=0;tap<=0;cubic_acc<=0;
      smooth_q<=0;pending_direction<=0;pending_version<=0;pending_id<=0;
      direction_applied_o<=0;direction_version_o<=0;direction_id_o<=0;
      effective_sample_seq_o<=0;audio_sample_seq_o<=0;group_delay_q16_o<=0;transitioning_o<=0;
      direction_trusted_o<=0;
      group_max_delay<=0;
      ch<=0; head<=0; valid_len<=0; samples<=0; read_addr<=0;
      v0<=0; v1<=0; das_q<=0; sum<=0;
      accepted_q<=0; output_q<=0; drop_q<=0; ticks<=0; max_ticks<=0;
      wr_ptr<=0; rd_ptr<=0; count<=0;
      for (m=0;m<CHANNELS;m=m+1) begin delay_q[m]<=0; snap[m]<=0;target_delay[m]<=0; end
    end else if (clear) begin
      head<=0; valid_len<=0; error_q<=0; accepted_q<=0;
      output_q<=0; drop_q<=0; ticks<=0; max_ticks<=0;
      wr_ptr<=0; rd_ptr<=0; count<=0;
    end else begin
      direction_applied_o<=0;
      if(link_enable_i===1'b1&&direction_fault_i!==1'b1&&direction_valid_i===1'b1&&direction_ready_o)begin
        if(direction_range_ok)begin
          for(m=0;m<CHANNELS;m=m+1)target_delay[m]<=direction_comp_i[m*32+:22];
          pending_direction<=1;pending_version<=direction_version_i;pending_id<=direction_id_i;
        end else error_q<=1;
      end
      if(direction_fault_i===1'b1)begin
        pending_direction<=0;direction_trusted_o<=0;
        for(m=0;m<CHANNELS;m=m+1)target_delay[m]<=snap[m];
      end
      if (cfg_wr_i) begin
        if (cfg_addr_i==0) begin
          // Re-enabling requires a SoC reset to reset the shared FIR history too.
          if (cfg_wdata_i[1]) error_q<=1;
          else if(cfg_wdata_i[3]&&!cubic_range_ok)error_q<=1;
          else begin enable_q<=cfg_wdata_i[0]; auto_q<=cfg_wdata_i[2];cubic_q<=cfg_wdata_i[3];smooth_q<=cfg_wdata_i[4]; end
        end else if (delay_addr_valid) begin
          if (cfg_wdata_i >= (cubic_q?32'h003d0000:32'h003f0000)) error_q<=1;
          else delay_q[delay_channel]<=cfg_wdata_i[21:0];
        end else error_q<=1;
      end
      if (cfg_rd_i && cfg_addr_i==3 && count==0) error_q<=1;
      if (pop) rd_ptr<=rd_ptr+1'b1;
      if (push) wr_ptr<=wr_ptr+1'b1;
      case ({push,pop})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: ;
      endcase
      if (state!=IDLE) ticks<=ticks+1;
      if (input_drop || fifo_drop) begin
        drop_q<=drop_q+{31'b0,input_drop}+{31'b0,fifo_drop}; error_q<=1;
      end
      case (state)
        IDLE: if (enable_q && valid_i) begin
          cubic_snap<=cubic_q;
          group_max_delay<=0;
          audio_sample_seq_o<=sample_seq_i;
          if(link_enable_i===1'b1)begin
            transitioning_o<=0;
            for(m=0;m<CHANNELS;m=m+1)begin
              if(next_delay(snap[m],target_delay[m],smooth_q)!=target_delay[m])transitioning_o<=1;
            end
            if(pending_direction&&direction_fault_i!==1'b1)begin
              direction_version_o<=pending_version;direction_id_o<=pending_id;
              direction_trusted_o<=1;
              effective_sample_seq_o<=sample_seq_i;direction_applied_o<=1;pending_direction<=0;
            end
          end
          for (m=0;m<CHANNELS;m=m+1) begin
            samples[m*16 +: 16]<=pcm_i[m*24+8 +: 16];
            if(link_enable_i===1'b1)snap[m]<=next_delay(snap[m],target_delay[m],smooth_q);
            else if (auto_q && steer_locked_i && !steer_busy_i) begin
              if (steer_comp_i[m*32 +: 32] < (cubic_q?32'h003d0000:32'h003f0000))
                snap[m]<=steer_comp_i[m*32 +: 22];
              else begin error_q<=1; snap[m]<=delay_q[m]; end
            end else if (!auto_q || !steer_seen) begin
              if(delay_q[m] < (cubic_q?32'h003d0000:32'h003f0000))snap[m]<=delay_q[m];
              else begin snap[m]<=0;error_q<=1;end
            end
          end
          if(auto_q && steer_locked_i && !steer_busy_i) steer_seen<=1;
          ch<=0; sum<=0; ticks<=0; state<=WRITE;
          accepted_q<=accepted_q+1;
          if (valid_len<64) valid_len<=valid_len+1'b1;
        end
        WRITE: begin
          // Reuse the channel walk; metadata reduction must not form a 12-way
          // combinational compare chain on the 40MHz input boundary.
          if(snap[ch]>group_max_delay)group_max_delay<=snap[ch];
          if (ch==CHANNELS-1) begin ch<=0; state<=READ0; end else ch<=ch+1;
        end
        READ0: begin read_addr<={ch,idx0}; state<=WAIT0; end
        WAIT0: state<=READ1;
        READ1: begin
          v0 <= age0 < valid_len ? read_q : 16'sd0;
          read_addr<={ch,idx1}; state<=WAIT1;
        end
        WAIT1: state<=ADD;
        ADD: begin v1<=age1 < valid_len ? read_q : 16'sd0; state<=4'd9; end
        4'd9: begin
          if(cubic_snap)begin read_addr<={ch,idx0-6'd2};state<=4'd11;end
          else begin
            if (ch < ACTIVE_CHANNELS) sum<=sum+interpolated;
            if (ch==CHANNELS-1) state<=4'd10; else begin ch<=ch+1; state<=READ0; end
          end
        end
        4'd11:state<=4'd12;
        4'd12:begin v2<=age0+7'd2<valid_len?read_q:16'sd0;read_addr<={ch,idx0-6'd3};state<=4'd13;end
        4'd13:state<=4'd14;
        4'd14:begin v3<=age0+7'd3<valid_len?read_q:16'sd0;tap<=0;cubic_acc<=0;state<=4'd15;end
        4'd15:begin
          cubic_acc<=cubic_total;
          if(tap==3)begin
            if(ch<ACTIVE_CHANNELS)sum<=sum+cubic_value;
            if(ch==CHANNELS-1)state<=4'd10;else begin ch<=ch+1;state<=READ0;end
          end else tap<=tap+1'b1;
        end
        4'd10: begin das_q<=average[15:0];group_delay_q16_o<=group_max_delay+(cubic_snap?32'd65536:0);state<=EMIT; end
        EMIT: if (fir_ready_i) state<=FIR;
        FIR: if (fir_done_i) begin
          if (push) output_q<=output_q+1;
          if (ticks>max_ticks) max_ticks<=ticks;
          head<=head+1'b1; state<=IDLE;
        end
        default: state<=IDLE;
      endcase
    end
  end
  always @(*) begin
    cfg_rdata_o=0;
    case (cfg_addr_i)
      0: cfg_rdata_o={27'b0,smooth_q,cubic_q,auto_q,1'b0,enable_q};
      1: cfg_rdata_o={20'b0,count,error_q,steer_locked_i,(state!=IDLE)};
      2: cfg_rdata_o=output_q;
      3: cfg_rdata_o=count!=0 ? fifo[rd_ptr] : 32'b0;
      4: cfg_rdata_o=drop_q;
      5: cfg_rdata_o=max_ticks;
      6: cfg_rdata_o=accepted_q;
      7: cfg_rdata_o=32'h44415301;
      16: cfg_rdata_o=ACTIVE_CHANNELS;
      17: cfg_rdata_o=32'h41435303; // Custom ISA: FFT SEEK, acoustic IO and normalized PHAT.
      default: if (delay_addr_valid)
        cfg_rdata_o={10'b0,delay_q[delay_channel]};
    endcase
  end
endmodule
