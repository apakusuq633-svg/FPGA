// M6 pin-level, delayed tri-state stimulus. Reference never samples the DATA bus.
`timescale 1ns/1ps
module tb_pdm12_sync;
  parameter integer MODE=0; // 0 normal, 1 LR swap, 2 LR conflict, 3 late DATA
  parameter integer DELAY_NS=108;
  reg clk=0, rst=0, en=0;
  always #12.5 clk=~clk;
  wire pclk,valid,aligned_valid;
  tri0 [5:0] data;
  wire [287:0] pcm,aligned;
  wire [31:0] frame;
  wire [11:0] ref_valid;
  wire [287:0] reference;
  reg [9:0] tick=0;
  reg prior_valid=0;
  integer cycles=0,frames=0,checks=0,mismatches=0,unknowns=0,epochs=0;
  integer last_frame_cycle=0,first_cycle=0,phase;
  rv32_pdm_array_rx #(.N_CH(12),.MICS_PER_LINE(2)) dut
    (.clk_i(clk),.rst_n_i(rst),.en_i(en),.pdm_din_i(data),.pdm_clk_o(pclk),
     .audio_vec_o(pcm),.sample_valid_o(valid),.frame_cnt_o(frame),.frozen_o());
  rv32_chan_align #(.N_CH(12)) aligner
    (.clk_i(clk),.rst_n_i(rst),.en_i(en),.audio_vec_i(pcm),.valid_i(valid),
     .gain_q_i({12{16'd16384}}),.audio_vec_o(aligned),.valid_o(aligned_valid));
  always @(posedge clk) begin
    if(!rst || !en) tick<=0; else tick<=tick+1'b1;
  end
  genvar k;
  generate for(k=0;k<6;k=k+1) begin: source
    reg [31:0] a=0,b=0;
    reg abit=0,bbit=0;
    // Different deterministic random streams on every microphone.
    wire clock_a=(MODE==1)?pclk:~pclk;
    wire clock_b=(MODE==1)?~pclk:pclk;
    always @(posedge clock_a or negedge rst or negedge en) begin
      if(!rst || !en) begin a<=32'haf819237^(k*32'h1234567);abit<=0;end
      else begin a<={a[30:0],a[31]^a[21]^a[1]^a[0]};abit<=a[31];end
    end
    always @(posedge clock_b or negedge rst or negedge en) begin
      if(!rst || !en) begin b<=32'h749bed21^(k*32'h7654321);bbit<=0;end
      else begin b<={b[30:0],b[31]^b[21]^b[1]^b[0]};bbit<=b[31];end
    end
    wire low_phase=~pclk;
    wire enable_a=(MODE==1)?pclk:low_phase;
    wire enable_b=(MODE==2)?low_phase:((MODE==1)?low_phase:pclk);
    // Release within t_HZ=30ns, drive/data valid at the specified delay.
    wire da,db;
    assign #(DELAY_NS,DELAY_NS,30) da=(en&&enable_a)?abit:1'bz;
    assign #(DELAY_NS,DELAY_NS,30) db=(en&&enable_b)?((MODE==2)?~abit:bbit):1'bz;
    assign data[k]=da;
    assign data[k]=db;
    pdm_ref_cic ra(.clk_i(clk),.rst_n_i(rst),.en_i(en),
      .bit_i((MODE==1)?bbit:abit),.bit_en_i(en&&tick[3:0]==12),
      .decim_en_i(en&&tick==1020),.sample_en_o(ref_valid[2*k]),
      .sample_o(reference[48*k+:24]));
    pdm_ref_cic rb(.clk_i(clk),.rst_n_i(rst),.en_i(en),
      .bit_i((MODE==1)?abit:bbit),.bit_en_i(en&&tick[3:0]==12),
      .decim_en_i(en&&tick==1020),.sample_en_o(ref_valid[2*k+1]),
      .sample_o(reference[48*k+24+:24]));
  end endgenerate
  always @(negedge clk) begin
    if(!rst || !en) begin cycles=0;frames=0;last_frame_cycle=0;prior_valid=0;end
    else begin
      cycles=cycles+1;
      if(aligned_valid!==prior_valid) $fatal(1,"ALIGN_VALID_SKEW");
      prior_valid=valid;
      if(valid!==(&ref_valid)) $fatal(1,"CHANNEL_VALID_SKEW");
      if(valid) begin
        if(frame!==frames) $fatal(1,"FRAME_INDEX frame=%0d expected=%0d",frame,frames);
        if(frames==0) begin
          if(first_cycle==0) first_cycle=cycles;
          else if(cycles!=first_cycle) $fatal(1,"RESET_FIRST_SAMPLE_CHANGED");
        end else if(cycles-last_frame_cycle!=1024) $fatal(1,"PCM_RATE");
        last_frame_cycle=cycles;frames=frames+1;
        checks=checks+12;
        if((^pcm)===1'bx) unknowns=unknowns+1;
        if(pcm!==reference) mismatches=mismatches+1;
        if(MODE<2 && pcm!==reference) $fatal(1,"PCM_REFERENCE mode=%0d frame=%0d",MODE,frames);
      end
    end
  end
  initial begin
    repeat(8) @(negedge clk);#1;rst=1;en=1;
    repeat(40000) @(negedge clk);
    // Reset at an arbitrary partial group, then restart all 12 channels.
    #1;rst=0;en=0;repeat(11) @(negedge clk);#1;rst=1;en=1;
    repeat(40000) @(negedge clk);
    // Disable at all 16 PDM phases, including between hold and consume.
    for(phase=0;phase<16;phase=phase+1) begin
      repeat(16) @(negedge clk);
      while(tick[3:0]!=phase) @(negedge clk);
      #1;en=0;repeat(3) @(negedge clk);#1;en=1;
      repeat(2100) @(negedge clk);
    end
    #1;en=0;repeat(5) @(negedge clk);#1;
    if(valid || aligned_valid || frame!=0 || pclk) $fatal(1,"DISABLE_STATE");
    if(checks<900) $fatal(1,"VACUOUS");
    if(MODE==2 && unknowns==0) $fatal(1,"LR_CONFLICT_NOT_OBSERVED");
    if(MODE==3 && mismatches==0) $fatal(1,"LATE_DATA_NOT_OBSERVED");
    $display("PDM12_SYNC_PASS mode=%0d delay_ns=%0d checks=%0d mismatches=%0d unknowns=%0d first_cycle=%0d",MODE,DELAY_NS,checks,mismatches,unknowns,first_cycle);
    $finish;
  end
endmodule
