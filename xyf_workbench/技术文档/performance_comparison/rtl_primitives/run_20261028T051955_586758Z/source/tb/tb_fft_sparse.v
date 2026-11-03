`timescale 1ns/1ps
// Compare the localizer's 64-bin input against a full513 zero-filled inverse,
// and both engines against the firmware scalar C golden. No reset between
// frames: stale FFT output, random RAM contents and DC/Nyquist must not leak.
module tb_fft_sparse;
  localparam integer CASES=12, STRIDE=513, LO=2, COUNT=64;
  reg clk=0; always #5 clk=~clk;
  reg rst=0, inv=0, sparse_pin=0;
  reg [1:0] start=0,commit=0,is_io=0,io_sel=0,seek=0;
  reg [31:0] scalar0=0,scalar1=0;
  wire [1:0] done,ready;
  wire [31:0] result0,result1;
  reg [31:0] got0,got1;
  reg [31:0] vectors[0:CASES*STRIDE-1],golden[0:CASES*STRIDE-1];
  reg [4095:0] vectors_file,golden_file;
  integer case_id,k,n_in,n_out,ticks=0,checks=0,run_ticks=0,mode;
  reg [31:0] word_data,poison;
  rv32_fft_bfly full_input (
    .clk_i(clk),.rst_n_i(rst),.start_i(start[0]),.keep_i(1'b1),
    .commit_i(commit[0]),.inv_i(inv),.sparse_inv_i(sparse_pin),
    .is_io_i(is_io[0]),.io_sel_i(io_sel[0]),.io_seek_i(seek[0]),
    .scalar_i(scalar0),.stall_o(),.done_o(done[0]),
    .result_o(result0),.io_ready_o(ready[0]));
  rv32_fft_bfly #(.INV_BAND_LO(LO),.INV_BAND_COUNT(COUNT)) sparse_input (
    .clk_i(clk),.rst_n_i(rst),.start_i(start[1]),.keep_i(1'b1),
    .commit_i(commit[1]),.inv_i(inv),.sparse_inv_i(sparse_pin),
    .is_io_i(is_io[1]),.io_sel_i(io_sel[1]),.io_seek_i(seek[1]),
    .scalar_i(scalar1),.stall_o(),.done_o(done[1]),
    .result_o(result1),.io_ready_o(ready[1]));
  always @(posedge clk) ticks<=ticks+1;

  task io_word(input [1:0] mask,input select_pop,input seek_only,input [31:0] data0,input [31:0] data1);
    begin
      @(negedge clk);
      if((ready&mask)!==mask)$fatal(1,"IO attempted before idle");
      start=mask;commit=mask;is_io=mask;io_sel={2{select_pop}};seek={2{seek_only}};
      scalar0=data0;scalar1=data1;
      #1;got0=result0;got1=result1;
      @(negedge clk);start=0;commit=0;
    end
  endtask
  task seek_both(input [31:0] pointer);
    begin
      io_word(3,1,1,pointer,pointer);
      if(got0!==0||got1!==0)$fatal(1,"SEEK unexpectedly returned a POP value");
    end
  endtask
  task transform(input use_sparse);
    integer begin_tick;
    begin
      @(negedge clk);is_io=0;start=3;commit=0;
      sparse_pin=use_sparse&&!$test$plusargs("DISABLE_SPARSE");begin_tick=ticks;
      @(negedge clk);start=0;
      // The RUN instruction must latch ownership/mode; its input can change
      // immediately when another instruction is decoded on the following cycle.
      sparse_pin=!use_sparse;
      while(done!==3 && ticks-begin_tick<4000) @(negedge clk);
      if(done!==3)$fatal(1,"FFT completion timeout case=%0d",case_id);
      run_ticks=ticks-begin_tick;
      commit=3;@(negedge clk);commit=0;
    end
  endtask
  initial begin
    if(!$value$plusargs("INPUT=%s",vectors_file)||!$value$plusargs("GOLDEN=%s",golden_file))
      $fatal(1,"missing FFT vectors");
    $readmemh(vectors_file,vectors);$readmemh(golden_file,golden);
    repeat(5)@(negedge clk);rst=1;
    for(case_id=0;case_id<CASES;case_id=case_id+1)begin
      mode=case_id%3;inv=mode!=2;
      if(mode==0)begin
        seek_both(0);
        for(k=0;k<STRIDE;k=k+1)begin
          poison=(32'hd3279b51*(k+1))^(32'h81160107*(case_id+1));
          if(k==0)poison=32'h7fff8000;
          if(k==512)poison=32'h80007fff;
          io_word(3,0,0,poison,poison);
        end
        seek_both(0);
        // Only the full reference engine receives zeros outside the passband.
        for(k=0;k<STRIDE;k=k+1)io_word(1,0,0,vectors[case_id*STRIDE+k],0);
        io_word(2,1,1,0,LO);
        for(k=LO;k<LO+COUNT;k=k+1)io_word(2,0,0,0,vectors[case_id*STRIDE+k]);
        transform(1);
      end else begin
        n_in=mode==2?512:513;
        seek_both(0);
        for(k=0;k<n_in;k=k+1)begin
          word_data=vectors[case_id*STRIDE+k];
          io_word(3,0,0,word_data,word_data);
        end
        // Generic inverse must use every bin with sparse_inv_i=0; a forward
        // transform must use every input even if sparse_inv_i is asserted.
        transform(mode==2);
      end
      n_out=mode==2?513:512;
      for(k=0;k<n_out;k=k+1)begin
        io_word(3,1,0,0,0);
        if(got0!==golden[case_id*STRIDE+k])
          $fatal(1,"full/golden case=%0d mode=%0d word=%0d got=%08x expected=%08x",case_id,mode,k,got0,golden[case_id*STRIDE+k]);
        if(got1!==got0)
          $fatal(1,"sparse/full case=%0d mode=%0d word=%0d sparse=%08x full=%08x",case_id,mode,k,got1,got0);
        checks=checks+1;
      end
      $display("FFT_SPARSE_CASE_PASS case=%0d mode=%0d words=%0d run_cycles=%0d",case_id,mode,n_out,run_ticks);
    end
    $display("FFT_SPARSE_PASS cases=%0d compared_words=%0d generic_inverse=1 forward=1 dirty_dc_nyquist=1 run_mode_latched=1",CASES,checks);
    $finish;
  end
  initial begin #3000000;$fatal(1,"test timeout");end
endmodule
