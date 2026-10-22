// VFFT-inv（核内逆变换）与满幅正变换的验证。
//
// 为什么单独一个 TB
// -----------------
// tb_fft_bfly 只跑正变换、只用一个中等幅度的帧。这一份补两个缺口：
//
//   ① 逆变换（指令的 instr[30] = 1）以前**只以标量形式存在**，硬件那一条
//      是 2026-10-07 才加的 —— 它需要自己的逐位判据。
//      灌 **513** 条 ψ、出 **512** 条，与正变换（512 进 513 出）不一样。
//
//   ② 满幅帧。拆分 / 反向拆分那一段的中间和是 (zk + zm) / (pr + qr)，
//      两个操作数同号时能到 65534 —— 超过 int16。RTL 原来把中间和写在
//      16 位上下文里（**先溢出再移位**），C 那边是 int32_t。中等幅度的帧
//      两个操作数不会同时越过 16384，所以那个错一直没被抓住（见 issues/087）。
//      这里的满幅帧就是把它顶出来的。
//
// golden 由 scripts/golden/fw_ifft_host.c 用**同一份 C 源码**在 host 上算出，
// 所以"硬件 == golden"就是"硬件 == 标量固件"。
`timescale 1ns/1ps

module tb_fft_ifft;

  localparam integer M    = 512;
  localparam integer NBIN = 513;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;
  reg        start, commit, inv;
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

  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  // in_word 最大 513 条（逆变换），ref_word 最大 513 条（正变换）
  reg [31:0] in_word  [0:NBIN-1];
  reg [31:0] ref_word [0:NBIN-1];
  reg [31:0] got;

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

  task run_io;
    input        sel;
    input [31:0] dat;
    begin
      @(negedge clk);
      start = 1'b1; is_io = 1'b1; io_sel = sel; scalar = dat; commit = 1'b1;
      #1; got = result;                 // 下一个 posedge 之前采：指针还没自增
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

  // n_in 条进、n_out 条出；mode_inv 选正/逆变换
  task run_case;
    input        mode_inv;
    input integer n_in;
    input integer n_out;
    input [8*64-1:0] name;
    integer i, n_bad, first_bad;
    reg [31:0] c0, c1, c2;
    begin
      $display("  ── %0s（%0d 进 / %0d 出，inv=%0d）──", name, n_in, n_out, mode_inv);
      inv = mode_inv;

      c0 = cyc;
      for (i = 0; i < n_in; i = i + 1) run_io(1'b0, in_word[i]);
      c1 = cyc;
      run_fft();
      c2 = cyc;

      n_bad = 0; first_bad = -1;
      for (i = 0; i < n_out; i = i + 1) begin
        run_io(1'b1, 32'd0);
        if (got !== ref_word[i]) begin
          n_bad = n_bad + 1;
          if (first_bad < 0) begin
            first_bad = i;
            $display("     首个不符: 第 %0d 条 实测 %08x 期望 %08x", i, got, ref_word[i]);
          end
        end
      end
      $display("     比对 %0d/%0d 条不符；装载 %0d 拍、运算 %0d 拍、取回 %0d 拍",
               n_bad, n_out, c1 - c0, c2 - c1, cyc - c2);
      check(n_bad == 0, "必须与 host 侧 C 算出的 golden 逐位一致");
    end
  endtask

  initial begin
    $display("=== tb_fft_ifft ===");
    start = 0; commit = 0; inv = 0; is_io = 0; io_sel = 0; scalar = 0;
    rst_n = 1'b0;
    repeat (10) @(negedge clk);
    rst_n = 1'b1;

    // ── ① 满幅帧的正变换：512 进、513 出 ────────────────────────────
    $readmemh("build/fft_frame_wide.hex",  in_word, 0, M-1);
    $readmemh("build/fw_fft_wide_ref.hex", ref_word);
    run_case(1'b0, M, NBIN, "正变换·满幅帧");

    // ── ② 逆变换（常规幅度）：513 进、512 出 ────────────────────────
    $readmemh("build/fw_ifft_psi.hex",     in_word);
    $readmemh("build/fw_ifft_ref.hex",     ref_word, 0, M-1);
    run_case(1'b1, NBIN, M, "逆变换·常规 ψ");

    // ── ③ 逆变换（满幅 ψ）──────────────────────────────────────────
    $readmemh("build/fw_ifft_psi_wide.hex", in_word);
    $readmemh("build/fw_ifft_ref_wide.hex", ref_word, 0, M-1);
    run_case(1'b1, NBIN, M, "逆变换·满幅 ψ");

    $display("");
    if (errors == 0) begin
      $display("PASS: VFFT-inv 与满幅正变换都与 host 侧 C golden 逐位一致");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #4000000;
    $display("FAIL: timeout");
    $finish;
  end

endmodule
