`timescale 1ns/1ps
// Two independent drivers, with a driven-but-invalid interval before tDV.
module pdm_shared_mic_model #(parameter SEED=1)(
  input clk,rst,en,lr,absent,input wire [31:0] dd,dv,hz,input [2:0] pattern,
  output data,output reg source_bit
);
  reg [31:0] lfsr=SEED;
  reg alternate=0;
  wire active=en && rst && (clk==lr);
  wire driven,valid;
  assign #(dd,dd,hz) driven=active;
  assign #(dv,dv,0) valid=active;
  assign data=absent ? 1'bz : (!driven ? 1'bz : (valid ? source_bit : 1'bx));
  always @(posedge active or negedge rst or negedge en) begin
    if(!rst || !en) begin lfsr=SEED;source_bit=0;alternate=0;end
    else begin
      lfsr={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
      alternate=~alternate;
      case(pattern)
        1:source_bit=0;
        2:source_bit=1;
        3:source_bit=alternate;
        default:source_bit=lfsr[31];
      endcase
    end
  end
endmodule

module tb_pdm_shared_startup;
  parameter N_CH=12;
  localparam N_LINE=N_CH/2;
  parameter MODE=0; // normal, swap, conflict, missing A, missing B, late
  parameter DELAY=108;
  parameter STARTUP=8192;
  parameter FULL=0;
  parameter DRIVE=40;
  parameter RELEASE=30;
  parameter HOLD=4,CONSUME=12;
  reg clk=0,rst=0,en=0;
  always #12.5 clk=~clk;
  tri [N_LINE-1:0] data;
  wire pclk,valid;
  wire [N_CH*24-1:0] pcm;
  wire [31:0] frame;
  wire [N_CH-1:0] frozen;
  wire [N_CH-1:0] source_bits;
  reg [2:0] pattern=0;
  integer dd=DRIVE,dv=DELAY,hz=RELEASE;
  integer cycles=0,frames=0,last_frame=0,first_frame=0,checks=0,detected=0;
  integer bit_count[0:N_CH-1];
  integer prev_bits[0:N_CH-1];
  integer epoch_frames=0;
  wire [2:0] model_pattern=FULL==1 ? (cycles<STARTUP ? 3'd1 : 3'd2) : pattern;
  wire stopped=MODE==8 && cycles>STARTUP+6500;
  wire mic_clk=MODE==9 ? (pclk ^ (cycles[5:0]==4)) : (stopped ? 1'b0 : pclk);
  integer clock_faults=0,valid_under_fault=0,hold_ghosts=0;
  integer last_clock_cycle=0;
  realtime last_clock_edge=0;
  always @(negedge en or negedge rst)begin last_clock_edge=0;last_clock_cycle=0;end
  always @(mic_clk)begin
    if(rst && en)begin
      if(last_clock_edge!=0 && $realtime-last_clock_edge!=200.0)clock_faults=clock_faults+1;
      last_clock_edge=$realtime;last_clock_cycle=cycles;
    end else begin last_clock_edge=0;last_clock_cycle=0;end
  end
  realtime last_rise=0,last_fall=0;
  integer i,phase;
  reg primed=0;
  always @(posedge pclk) last_rise=$realtime;
  always @(negedge pclk) last_fall=$realtime;
  always @(posedge clk) if(rst && en && primed)begin
    if(dut.hold_en_w && $realtime-last_fall!=(HOLD+1)*25.0)$fatal(1,"A_PHASE");
    if(dut.bit_en_w && $realtime-last_rise!=(CONSUME-7)*25.0)$fatal(1,"B_PHASE");
  end
  rv32_pdm_array_rx #(.N_CH(N_CH),.MIC_STARTUP_CYCLES(STARTUP),.CIC_SETTLE_FRAMES(4),.HOLD_TICK(HOLD),.CONSUME_TICK(CONSUME),.LOSS_FRAMES(16)) dut(
    .clk_i(clk),.rst_n_i(rst),.en_i(en),.pdm_din_i(data),.pdm_clk_o(pclk),
    .audio_vec_o(pcm),.sample_valid_o(valid),.frame_cnt_o(frame),.frozen_o(frozen));
  genvar k;
  generate for(k=0;k<N_LINE;k=k+1)begin:bus
    wire a,b;
    wire alr=MODE==1;
    wire blr=MODE==2 ? 1'b0 : MODE!=1;
    wire removed=MODE==10 && cycles>STARTUP+6500;
    if(MODE==6 || MODE==7 || MODE==10)begin:keeper
      reg held=0;
      always @(data[k])if(data[k]===1'b0 || data[k]===1'b1)held<=data[k];
      assign (weak0,weak1) data[k]=held;
    end else begin:pull
      pulldown pd(data[k]);
    end
    pdm_shared_mic_model #(.SEED(32'had2186f1+k*107)) ma(
      .clk(mic_clk),.rst(rst),.en(en),.lr(alr),.absent(MODE==3 || MODE==6 || removed),
      .dd(dd),.dv(dv),.hz(hz),.pattern(MODE==2?3'd1:model_pattern),.data(a),.source_bit(source_bits[2*k]));
    pdm_shared_mic_model #(.SEED(32'h59e713ab+k*311)) mb(
      .clk(mic_clk),.rst(rst),.en(en),.lr(blr),.absent(MODE==4 || MODE==7 || removed),
      .dd(dd),.dv(dv),.hz(hz),.pattern(MODE==2?3'd2:model_pattern),.data(b),.source_bit(source_bits[2*k+1]));
    assign data[k]=a;
    assign data[k]=b;
  end endgenerate

  // Independent wide CIC oracle runs from the source sequence, not sampled DATA.
  reg [63:0] acc[0:N_CH-1][0:2];
  reg [63:0] comb[0:N_CH-1][0:2];
  reg [63:0] x,y,z;
  reg [N_CH*24-1:0] expected;
  reg bit_value;
  reg [9:0] tick=0;
  reg eligible=0;
  integer ref_bits=0;
  always @(posedge clk) begin
    if(!rst || !en)begin
      tick<=0;primed<=0;eligible<=0;ref_bits=0;
      for(integer c=0;c<N_CH;c=c+1)begin
        bit_count[c]=0;prev_bits[c]=0;
        for(integer n=0;n<3;n=n+1)begin acc[c][n]=0;comb[c][n]=0;end
      end
    end else begin
      tick<=tick+1'b1;
      // DUT integrates one clock after capture and reads previous acc[2].
      if(tick[3:0]==CONSUME)begin primed<=1;eligible<=primed;end
      if(tick[3:0]==CONSUME+1 && eligible)begin
        for(integer c=0;c<N_CH;c=c+1)begin
          if((MODE==3 || MODE==6) && c%2==0 || (MODE==4 || MODE==7) && c%2==1)bit_value=0;
          else bit_value=source_bits[MODE==1 ? (c^1) : c];
          if(tick[9:4]==63)begin
            x=acc[c][2];y=x-comb[c][0];z=y-comb[c][1];
            x=z-comb[c][2];comb[c][0]=acc[c][2];comb[c][1]=y;comb[c][2]=z;
            if(x==262144)expected[c*24+:24]=24'h7fffff;
            else expected[c*24+:24]=(x-131072)<<6;
          end
          acc[c][2]=acc[c][2]+acc[c][1];acc[c][1]=acc[c][1]+acc[c][0];acc[c][0]=acc[c][0]+bit_value;
          bit_count[c]=bit_count[c]+1;
        end
        ref_bits=ref_bits+1;
      end
    end
  end
  always @(negedge clk)begin
    if(!rst || !en)begin cycles=0;frames=0;last_frame=0;end
    else begin
      cycles=cycles+1;
      if(dut.ch_valid_w!=={N_CH{dut.ch_valid_w[0]}})$fatal(1,"CHANNEL_VALID_SKEW");
      if(stopped && cycles-last_clock_cycle>20)clock_faults=clock_faults+1;
      if(valid)begin
        if(cycles<STARTUP+4*1024)$fatal(1,"EARLY_ACOUSTIC_VALID");
        if(frames && cycles-last_frame!=1024)$fatal(1,"PCM_INTERVAL");
        if(frame!==frames)$fatal(1,"FRAME_INDEX");
        if(!frames)begin
          if(first_frame==0)first_frame=cycles;
          else if(first_frame!=cycles)$fatal(1,"NONDETERMINISTIC_RESTART");
        end
        for(i=0;i<N_CH;i=i+1)begin
          if(frames && bit_count[i]-prev_bits[i]!=64)$fatal(1,"PDM_BIT_COUNT");
          if(FULL==1 && pcm[i*24+:24]!==24'h7fffff)$fatal(1,"MIC_STARTUP_TRANSIENT_LEAKED");
          prev_bits[i]=bit_count[i];
        end
        if(pcm!==expected)begin
          detected=detected+1;
          if(MODE!=2 && MODE<5)$fatal(1,"REFERENCE_MISMATCH mode=%0d cycle=%0d ch0=%h expected=%h",MODE,cycles,pcm[23:0],expected[23:0]);
        end
        if((stopped || MODE==9) && clock_faults)valid_under_fault=valid_under_fault+1;
        if((MODE==6 || MODE==7) && detected && frozen==0)hold_ghosts=hold_ghosts+1;
        checks=checks+N_CH;frames=frames+1;epoch_frames=epoch_frames+1;last_frame=cycles;
      end
    end
  end
  task epoch;
    input integer pat;
    input integer reset_it;
    begin
      #1;en=0;if(reset_it)rst=0;
      repeat(24)@(negedge clk);
      #1;pattern=pat;rst=1;en=1;
      repeat(STARTUP+((MODE>=8)?45000:12000))@(negedge clk);
      if(frames<6)$fatal(1,"VACUOUS_EPOCH");
    end
  endtask
  initial begin
    repeat(8)@(negedge clk);
    epoch(0,1);
    if(!FULL)begin
      epoch(1,1);epoch(2,0);epoch(3,0);
      for(phase=0;phase<16;phase=phase+1)begin
        while(tick[3:0]!=phase)@(negedge clk);
        epoch(0,phase%2);
      end
    end
    #1;en=0;repeat(24)@(negedge clk);
    if(valid || frame || pclk)$fatal(1,"DISABLE_STATE");
    if((MODE==2 || MODE==5 || MODE==6 || MODE==7 || MODE==10) && detected==0)$fatal(1,"FAULT_NOT_DETECTED");
    if(MODE!=2 && MODE<5 && detected)$fatal(1,"UNEXPECTED_FAULT");
    if((MODE==8 || MODE==9) && (clock_faults==0 || valid_under_fault==0))$fatal(1,"CLOCK_MONITOR_VACUOUS");
    if((MODE==6 || MODE==7) && hold_ghosts==0)$fatal(1,"KEEPER_COUNTEREXAMPLE_VACUOUS");
    if(MODE<8 && clock_faults)$fatal(1,"CLOCK_MONITOR_FALSE_POSITIVE");
    $display("FAULT_EVIDENCE clock_events=%0d valid_under_fault=%0d keeper_ghosts_without_frozen=%0d hardware_detection=UNVERIFIED",clock_faults,valid_under_fault,hold_ghosts);
    $display("PDM_SHARED_PASS mode=%0d dv=%0d startup=%0d first_cycle=%0d checks=%0d detected=%0d",MODE,DELAY,STARTUP,first_frame,checks,detected);
    $finish;
  end
  initial begin #(200000000);$fatal(1,"TIMEOUT");end
endmodule
