// VFFT 执行单元的验证 —— 硬件的 513 条 bin 对着 **固件标量 FFT 的 golden**
// （build/fw_fft_ref.hex）逐位比。
//
// 为什么可以直接拿固件那份 golden
// -------------------------------
// 那份 golden 由 scripts/golden/fw_fft_model.py 生成，已经被 tb_fw_fft.v 在真核上
// 逐位验过。**硬件对同一份 golden**，等于复用了前面所有验证工作 ——
// 也正因如此，硬件的算术一处都不许"改进"（取整方向、标度全照抄 fw_fft.c）。
//
// 灌进去的输入帧取自 build/fft_frame.hex，与固件 make_frame() 一字不差。
`timescale 1ns/1ps

module tb_fft_bfly;

  localparam integer M    = 512;
  localparam integer NBIN = 513;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;
  reg        start, commit;
  reg        inv;                 // instr[30]：本 TB 只跑正变换，恒 0
  reg        is_io, io_sel;
  reg [31:0] scalar;
  wire       stall, done;
  wire [31:0] result;

  rv32_fft_bfly u_dut (
    .clk_i    (clk),
    .rst_n_i  (rst_n),
    .start_i  (start),
    .keep_i   (1'b1),
    .commit_i (commit),
    .inv_i    (inv),
    .is_io_i  (is_io),
    .io_sel_i (io_sel),
    .io_seek_i(1'b0),
    .scalar_i (scalar),
    .stall_o  (stall),
    .done_o   (done),
    .result_o (result)
  );

  reg [31:0] frame [0:M-1];
  reg [15:0] ref_re [0:NBIN-1];
  reg [15:0] ref_im [0:NBIN-1];
  reg [31:0] got;

  integer errors = 0;
  integer i, n_bad, first_bad;
  integer cyc = 0, c_load = 0, c_run = 0, c_pop = 0;

  always @(posedge clk) cyc = cyc + 1;

  task check;
    input            cond;
    input [8*96-1:0] msg;
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s", msg);
      end
    end
  endtask

  // 单拍 PUSH / POP（判据 commit_i，与核那边的接法一致）
  task run_io;
    input        sel;
    input [31:0] dat;
    begin
      @(negedge clk);
      start = 1'b1; is_io = 1'b1; io_sel = sel; scalar = dat; commit = 1'b1;
      #1; got = result;                 // 在下一个 posedge 之前采：指针还没自增
      @(negedge clk);
      start = 1'b0; commit = 1'b0;
    end
  endtask

  task run_fft;
    begin
      @(negedge clk);
      start = 1'b1; is_io = 1'b0; commit = 1'b0;
      @(negedge clk);
      start = 1'b0;
      while (!done) @(negedge clk);
      commit = 1'b1;
      @(negedge clk);
      commit = 1'b0;
    end
  endtask

  initial begin
    $display("=== tb_fft_bfly ===");
    $readmemh("build/fft_frame.hex", frame);
    // fw_fft_ref.hex 是 re/im 交替的 16 位
    begin : rd_ref
      integer k;
      reg [15:0] tmp [0:2*NBIN-1];
      $readmemh("build/fw_fft_ref.hex", tmp);
      for (k = 0; k < NBIN; k = k + 1) begin
        ref_re[k] = tmp[2*k];
        ref_im[k] = tmp[2*k+1];
      end
    end

    start = 0; commit = 0; inv = 0; is_io = 0; io_sel = 0; scalar = 0;
    rst_n = 1'b0;
    repeat (10) @(negedge clk);
    rst_n = 1'b1;

    // ── 灌 512 条复数 ───────────────────────────────────────────────
    c_load = cyc;
    for (i = 0; i < M; i = i + 1) run_io(1'b0, frame[i]);
    c_load = cyc - c_load;

    // ── 跑 FFT ──────────────────────────────────────────────────────
    c_run = cyc;
    run_fft();
    c_run = cyc - c_run;

    // ── 取 513 条 bin，逐位比 ───────────────────────────────────────
    n_bad = 0;  first_bad = -1;
    c_pop = cyc;
    for (i = 0; i < NBIN; i = i + 1) begin
      run_io(1'b1, 32'd0);
      if (got[15:0] !== ref_re[i] || got[31:16] !== ref_im[i]) begin
        n_bad = n_bad + 1;
        if (first_bad < 0) begin
          first_bad = i;
          $display("  首个不符: bin %0d 实测 re=%0d im=%0d 期望 re=%0d im=%0d",
                   i, $signed(got[15:0]), $signed(got[31:16]),
                   $signed(ref_re[i]), $signed(ref_im[i]));
        end
      end
    end
    c_pop = cyc - c_pop;

    $display("  bin 比对: %0d/%0d 条不符", n_bad, NBIN);
    check(n_bad == 0, "513 条 bin 必须与固件 golden 逐位一致");

    $display("");
    $display("  ── 拍数账 ──");
    $display("     装载 512 条 PUSH : %0d 拍", c_load);
    $display("     9 级 + 拆分      : %0d 拍", c_run);
    $display("     取回 513 条 POP  : %0d 拍", c_pop);
    // ⚠ 这个基线是 tb_fw_fft 实测报出来的（`FFT(1024) 标量 = 198905 拍`），
    //   本 TB 只是引用。写死在这里的数有两次对不上过 —— 改任何一边都要同步，
    //   否则两个 TB 会给出互相矛盾的加速比。
    $display("     合计 %0d 拍（标量固件 FFT 实测 198905 拍，出处 tb_fw_fft）",
             c_load + c_run + c_pop);
    $display("     => 不以 TB 搬运拍数代替端到端加速比；含核侧 lw/sw 的结果见固件实测");
    $display("");

    if (errors == 0) begin
      $display("PASS: VFFT 硬件的 513 条 bin 与固件 golden 逐位一致");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #2000000;
    $display("FAIL: timeout");
    $finish;
  end

endmodule
