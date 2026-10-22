`timescale 1ns/1ps
module tb_das_stream;
  parameter ACTIVE_CHANNELS=8;
  localparam CHANNELS=ACTIVE_CHANNELS==4 ? 8 : ACTIVE_CHANNELS;
  reg clk_i=0; always #5 clk_i=~clk_i;
  reg rst_n_i=0;
  reg [CHANNELS*24-1:0] pcm=0;
  reg valid=0, wr=0, rd=0;
  reg [4:0] addr=0;
  reg [31:0] wdata=0;
  wire [31:0] rdata;
  wire av, ar, ad;
  wire [15:0] ax, ay;
  reg [CHANNELS*32-1:0] comp=0;
  reg locked=0, steer_busy=0;
  reg cw=0;
  reg [8:0] ci=0;
  reg [15:0] cd=0;
  reg halted=1;
  wire ireq; wire [31:0] ia;
  reg [31:0] iq=0; reg ir=0;
  // Run a scalar loop concurrently with audio; the test below also injects OP-V.
  always @(posedge clk_i) begin
    ir<=ireq;
    case (ia[4:2])
      0: iq<=32'h00108093;
      1: iq<=32'h0000800b;
      2: iq<=32'hff9ff06f;
      default: iq<=32'h00000013;
    endcase
  end
  rv32_core #(.AUDIO_STREAM(1)) core (
    .clk_i(clk_i),.rst_n_i(rst_n_i),.halt_i(halted),.test_en_i(1'b0),
    .imem_req_o(ireq),.imem_addr_o(ia),.imem_ready_i(ir),.imem_rdata_i(iq),
    .dmem_ready_i(1'b1),.dmem_rdata_i(32'b0),
    .coef_we_i(cw),.coef_re_i(1'b0),.coef_src_i(1'b0),.coef_ch_i(1'b1),
    .coef_idx_i(ci),.coef_wdata_i(cd),
    .audio_valid_i(av),.audio_sample_i(ax),.audio_ready_o(ar),
    .audio_done_o(ad),.audio_result_o(ay)
  );
  rv32_das_stream #(.ACTIVE_CHANNELS(ACTIVE_CHANNELS)) beam (
    .clk_i(clk_i),.rst_n_i(rst_n_i),.pcm_i(pcm),.valid_i(valid),
    .steer_comp_i(comp),.steer_locked_i(locked),.steer_busy_i(steer_busy),
    .cfg_wr_i(wr),.cfg_rd_i(rd),.cfg_addr_i(addr),.cfg_wdata_i(wdata),
    .cfg_rdata_o(rdata),.fir_valid_o(av),.fir_sample_o(ax),
    .fir_ready_i(ar),.fir_done_i(ad),.fir_result_i(ay)
  );
  reg signed [15:0] coeff[0:31];
  integer history[0:CHANNELS-1][0:63];
  integer fh[0:31];
  integer n,m,k,j,di,fr,a,b,ds,fy,s,head,fhead,got,ticks,max_ticks=0;
  integer delays[0:CHANNELS-1];
  reg [31:0] rng=32'hc0ffee;
  task write_reg;
    input [4:0] a; input [31:0] v;
    begin @(negedge clk_i); addr=a; wdata=v; wr=1;
      @(negedge clk_i); wr=0;
    end
  endtask
  task output_read;
    begin @(negedge clk_i); addr=3; rd=1; #1; got=rdata;
      @(negedge clk_i); rd=0;
    end
  endtask
  initial begin
    $readmemh("build/fw_fir_coeff.hex",coeff);
    for(m=0;m<CHANNELS;m=m+1) for(k=0;k<64;k=k+1) history[m][k]=0;
    for(k=0;k<32;k=k+1) fh[k]=0;
    repeat(4) @(negedge clk_i); rst_n_i=1;
    for(k=0;k<32;k=k+1) begin
      @(negedge clk_i); ci=k; cd=coeff[k]; cw=1;
    end
    @(negedge clk_i); cw=0;
    for(m=0;m<CHANNELS;m=m+1) begin
      delays[m]=m*65536+m*4096;
      write_reg(m<8 ? 8+m : 24+m-8,delays[m]);
    end
    write_reg(0,1);
    head=0; fhead=0;
    for(n=0;n<1200;n=n+1) begin
      if(n==300) halted=0;
      if(n==600) begin
        // Atomic auto steering replaces manual delays only when not busy.
        for(m=0;m<CHANNELS;m=m+1) begin
          delays[m]=(62-m)*65536+4096*m;
          comp[m*32 +: 32]=delays[m];
        end
        locked=1; write_reg(0,5);
      end
      if(n==650) steer_busy=1;
      if(n==658) steer_busy=0;
      s=0;
      for(m=0;m<CHANNELS;m=m+1) begin
        rng=rng*1664525+1013904223;
        j=$signed(rng[31:16]);
        if(n==100) j=32767;
        if(n==101) j=-32768;
        history[m][head]=j;
        pcm[m*24 +: 24]=j*256;
        di=delays[m]>>16; fr=(delays[m]>>12)&15;
        a=n>=di ? history[m][(head-di)&63] : 0;
        b=n>=di+1 ? history[m][(head-di-1)&63] : 0;
        if(m<ACTIVE_CHANNELS) s=s+a+(((b-a)*fr)>>>4);
      end
      ds=s+ACTIVE_CHANNELS/2;
      ds=ds<0 ? -((-ds+ACTIVE_CHANNELS-1)/ACTIVE_CHANNELS) : ds/ACTIVE_CHANNELS;
      fh[fhead]=ds; s=0;
      for(k=0;k<32;k=k+1) s=s+$signed(coeff[k])*fh[(fhead-k)&31];
      fy=s>>>15;
      if(fy>32767) fy=32767;
      if(fy< -32768) fy=-32768;
      @(negedge clk_i); valid=1;
      @(negedge clk_i); valid=0;
      ticks=0;
      while(!ad && ticks<1024) begin @(negedge clk_i); ticks=ticks+1; end
      if(ticks>=1024) $fatal(1,"audio deadline missed n=%0d",n);
      if(ticks>max_ticks) max_ticks=ticks;
      repeat(3) @(negedge clk_i);
      output_read;
      if($signed(got[15:0])!==ds || $signed(got[31:16])!==fy)
        $fatal(1,"n=%0d DAS got=%0d want=%0d FIR got=%0d want=%0d",n,$signed(got[15:0]),ds,$signed(got[31:16]),fy);
      head=(head+1)&63; fhead=(fhead+1)&31;
      repeat(1024-ticks-8) @(negedge clk_i);
    end
    addr=4; #1; if(rdata!=0) $fatal(1,"unexpected drop");
    addr=1; #1; if(rdata[2]) $fatal(1,"unexpected error");
    write_reg(8,32'h00400000);
    addr=1; #1; if(!rdata[2]) $fatal(1,"invalid delay not rejected");
    // No consumer: a full output queue must count every discarded sample.
    for(n=0;n<260;n=n+1) begin
      @(negedge clk_i); valid=1;
      @(negedge clk_i); valid=0;
      repeat(1023) @(negedge clk_i);
    end
    addr=4; #1; if(rdata!=4) $fatal(1,"FIFO overflow count got=%0d want=4",rdata);
    for(n=0;n<256;n=n+1) output_read;
    output_read;
    addr=1; #1; if(!rdata[2]) $fatal(1,"empty read not rejected");
    $display("DAS_STREAM_PASS samples=1200 max_cycles=%0d budget=1024 core_push_concurrent=1 fifo_overflow=4",max_ticks);
    $finish;
  end
  initial begin #20000000; $fatal(1,"timeout"); end
endmodule
