// 互谱 + PHAT 归一化的验收测试（README §20 / §21）。
//
// 验的是 PHAT 的两个**不变量**，避开 atan2：
//
//   ① 幅度：  Ψ 是单位幅度，Q2.14 下 |Ψ|² = pr² + pi² 应当 ≈ 16384²
//   ② 共线：  Ψ 与 G 同相位 → pr·im − pi·re ≈ 0
//
// 加上第三条，这条是 docs/issues/027 的修法，必须**恰好**成立：
//
//   ③ 带外：  bin < BIN_LO 或 bin > BIN_HI 时 Ψ **恒等于 0**，一位不差
//
// 六段，每段先证明观测有效再断言：
//   1. 停用时无输出；
//   2. 延迟固定（输出比输入恰好晚 3 拍）；
//   3. 带内幅度 ≈ 1；
//   4. 带内共线（相位正确）；
//   5. 带外恰好为 0，且带内计数正确；
//   6. 反证：另一份 BIN_LO/BIN_HI 不同的 DUT，边界必须跟着移动；
//      并且把一份的 mask 关掉（BIN_LO=0/BIN_HI=511），带外就不再是 0 ——
//      证明第 5 段测到的 0 确实来自 mask，不是数据本来就是 0。
`timescale 1ns/1ps

module tb_xspec_phat;

  localparam integer DW      = 16;
  localparam integer LUT_BITS = 4;
  localparam integer BIN_LO  = 5;
  localparam integer BIN_HI  = 209;
  localparam integer LAT     = 3;         // 流水线级数

  reg clk = 1'b0;
  always #12.5 clk = ~clk;

  reg rst_n = 1'b0;
  reg en    = 1'b0;

  reg               in_valid;
  reg [9:0]         bin_in;
  reg signed [DW-1:0] ar, ai, br, bi;

  wire              out_valid;
  wire [9:0]        bin_out;
  wire signed [15:0] pr, pi;
  wire [15:0]       inband_cnt;

  rv32_xspec_phat #(
    .DW(DW), .LUT_BITS(LUT_BITS), .BIN_LO(BIN_LO), .BIN_HI(BIN_HI)
  ) u_dut (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .in_valid_i (in_valid), .bin_i (bin_in),
    .ar_i (ar), .ai_i (ai), .br_i (br), .bi_i (bi),
    .out_valid_o (out_valid), .bin_o (bin_out), .pr_o (pr), .pi_o (pi),
    .inband_cnt_o (inband_cnt)
  );

  // 第二份：mask 全开（BIN_LO=0 / BIN_HI=511），用于第 6 段反证
  wire [9:0]        bin_out2;
  wire signed [15:0] pr2, pi2;
  rv32_xspec_phat #(
    .DW(DW), .LUT_BITS(LUT_BITS), .BIN_LO(0), .BIN_HI(511)
  ) u_dut_nomask (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .in_valid_i (in_valid), .bin_i (bin_in),
    .ar_i (ar), .ai_i (ai), .br_i (br), .bi_i (bi),
    .out_valid_o (), .bin_o (bin_out2), .pr_o (pr2), .pi_o (pi2),
    .inband_cnt_o ()
  );

  // 第三份：频带挪走（BIN_LO=300 / BIN_HI=400），验证边界确实跟着参数走
  wire signed [15:0] pr3, pi3;
  rv32_xspec_phat #(
    .DW(DW), .LUT_BITS(LUT_BITS), .BIN_LO(300), .BIN_HI(400)
  ) u_dut_shift (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .in_valid_i (in_valid), .bin_i (bin_in),
    .ar_i (ar), .ai_i (ai), .br_i (br), .bi_i (bi),
    .out_valid_o (), .bin_o (), .pr_o (pr3), .pi_o (pi3),
    .inband_cnt_o ()
  );

  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  task check;
    input            cond;
    input [8*96-1:0] msg;
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s  (t=%0t)", msg, $time);
      end
    end
  endtask

  // ── 一拍的激励 → 等 LAT 拍 → 返回输出 ──────────────────────────────────
  integer ov_re, ov_im;      // 主 DUT
  integer ov2_re, ov2_im;    // mask 全开
  integer ov3_re, ov3_im;    // 频带挪走
  integer in_re, in_im;      // 输入 G 的真值
  integer expect_mag2;

  task drive_and_capture;
    input [9:0]          b;
    input signed [DW-1:0] a_r, a_i, bb_r, bb_i;
    integer k;
    begin
      @(negedge clk);
      bin_in  = b;
      ar = a_r; ai = a_i; br = bb_r; bi = bb_i;
      in_valid = 1'b1;
      @(posedge clk);              // 这一拍进入级 1
      @(negedge clk);
      in_valid = 1'b0;
      // 真值 G = X_i · conj(X_j)
      in_re = $signed(a_r) * $signed(bb_r) + $signed(a_i) * $signed(bb_i);
      in_im = $signed(a_i) * $signed(bb_r) - $signed(a_r) * $signed(bb_i);
      for (k = 0; k < LAT - 1; k = k + 1) @(posedge clk);
      #1;
      ov_re  = $signed(pr);   ov_im  = $signed(pi);
      ov2_re = $signed(pr2);  ov2_im = $signed(pi2);
      ov3_re = $signed(pr3);  ov3_im = $signed(pi3);
      @(posedge clk);
    end
  endtask

  integer i, b;
  real    mag2, cross, relerr;
  integer n_in, n_out, n_zero, n_nz;

  initial begin
    in_valid = 1'b0; bin_in = 10'd0;
    ar = 0; ai = 0; br = 0; bi = 0;

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    $display("=== tb_xspec_phat: DW=%0d LUT=%0d band=[%0d,%0d] ===",
             DW, LUT_BITS, BIN_LO, BIN_HI);

    // ── 段 1：停用 ──────────────────────────────────────────────────
    $display("[1] disabled: no output");
    en = 1'b0; in_valid = 1'b1; bin_in = 10'd100;
    ar = 1000; ai = -500; br = 700; bi = 300;
    repeat (20) @(posedge clk);
    check(out_valid === 1'b0, "disabled: out_valid must stay 0");
    in_valid = 1'b0;
    en = 1'b1;
    repeat (4) @(posedge clk);

    // ── 段 2：固定延迟 ──────────────────────────────────────────────
    $display("[2] fixed latency = %0d cycles", LAT);
    begin : lat_blk
      integer seen;
      seen = 0;
      @(negedge clk);
      bin_in = 10'd100; ar = 1000; ai = -500; br = 700; bi = 300;
      in_valid = 1'b1;
      // i=1 就是**输入被采样**的那一拍，必须从它开始数，
      // 否则数出来会比真实流水线深度少 1（第一版 TB 就栽在这里）。
      @(posedge clk); #1;
      check(out_valid === 1'b0, "no output on the input cycle itself");
      @(negedge clk); in_valid = 1'b0;
      for (i = 2; i <= LAT + 3; i = i + 1) begin
        @(posedge clk); #1;
        if (out_valid && (bin_out == 10'd100) && (seen == 0)) begin
          seen = 1;
          check(i == LAT, "output must appear exactly LAT cycles later");
          $display("     latency measured = %0d cycles", i);
        end
      end
      check(seen == 1, "output must be seen");
      @(posedge clk);
    end

    // ── 段 3+4：带内幅度与共线 ──────────────────────────────────────
    $display("[3/4] in-band: |Psi| ~ 1 and collinear with G");
    begin : inband_blk
      integer cases [0:5];
      integer j;
      cases[0] = 5;  cases[1] = 6;  cases[2] = 17;
      cases[3] = 79; cases[4] = 120; cases[5] = 209;
      for (j = 0; j < 6; j = j + 1) begin
        b = cases[j];
        drive_and_capture(b[9:0], 16'sd12345, -16'sd6789,
                          16'sd4321, 16'sd9876);
        mag2  = (ov_re * 1.0) * ov_re + (ov_im * 1.0) * ov_im;
        // Q2.14 下 |Psi| = 1 → 值 = 16384
        relerr = (mag2 - 16384.0 * 16384.0) / (16384.0 * 16384.0) * 100.0;
        cross = (ov_re * 1.0) * in_im - (ov_im * 1.0) * in_re;
        $display("     bin=%3d  |Psi|^2=%.4e  relerr=%+6.2f%%  cross=%.3e",
                 b, mag2, relerr, cross);
        check((relerr < 8.0) && (relerr > -8.0),
              "in-band |Psi| must be ~1 (Q2.14 -> 16384)");
        // 共线：cross 相对 |G|*|Psi| 要小
        begin : coll
          real gmag, scale, crev;
          gmag  = $sqrt(in_re * 1.0 * in_re + in_im * 1.0 * in_im);
          scale = gmag * 16384.0;
          crev  = (scale > 0.0) ? (cross / scale) : 0.0;
          if (crev < 0.0) crev = -crev;
          check(crev < 0.08, "Psi must be collinear with G (phase preserved)");
        end
      end
    end

    // ── 段 5：带外恰好为 0 ──────────────────────────────────────────
    $display("[5] out-of-band: Psi must be EXACTLY 0");
    n_zero = 0; n_nz = 0;
    for (b = 0; b < 260; b = b + 1) begin
      drive_and_capture(b[9:0], 16'sd12345, -16'sd6789, 16'sd4321, 16'sd9876);
      if ((b >= BIN_LO) && (b <= BIN_HI)) begin
        if ((ov_re == 0) && (ov_im == 0)) n_zero = n_zero + 1;
      end else begin
        if ((ov_re != 0) || (ov_im != 0)) n_nz = n_nz + 1;
      end
    end
    $display("     in-band bins that came out ZERO : %0d (must be 0)", n_zero);
    $display("     out-of-band bins that came out NZ: %0d (must be 0)", n_nz);
    check(n_zero == 0, "no in-band bin may be zeroed");
    check(n_nz == 0,   "every out-of-band bin must be exactly zero");
    check(inband_cnt == (BIN_HI - BIN_LO + 1),
          "in-band counter must equal BIN_HI-BIN_LO+1");

    // ── 段 6：反证 ──────────────────────────────────────────────────
    $display("[6] negative control: mask really is what zeroes the band");
    // ① 全开 mask 的那份，在 bin=BIN_LO-1 处**不应**为 0
    drive_and_capture((BIN_LO - 1), 16'sd12345, -16'sd6789,
                      16'sd4321, 16'sd9876);
    $display("     bin=%0d : masked DUT = (%0d,%0d)   unmasked DUT = (%0d,%0d)",
             BIN_LO - 1, ov_re, ov_im, ov2_re, ov2_im);
    check((ov_re == 0) && (ov_im == 0), "masked DUT must zero this bin");
    check((ov2_re != 0) || (ov2_im != 0),
          "unmasked DUT must NOT zero it -- else the zeros above prove nothing");

    // ② 频带挪到 [300,400] 的那份，bin=250 处必须为 0，bin=350 处必须非 0
    drive_and_capture(10'd250, 16'sd12345, -16'sd6789, 16'sd4321, 16'sd9876);
    check((ov3_re == 0) && (ov3_im == 0),
          "shifted-band DUT must zero bin 250");
    drive_and_capture(10'd350, 16'sd12345, -16'sd6789, 16'sd4321, 16'sd9876);
    check((ov3_re != 0) || (ov3_im != 0),
          "shifted-band DUT must pass bin 350");

    // ③ 全零输入：|G|=0 不能把倒数路径搞崩
    drive_and_capture(10'd100, 16'sd0, 16'sd0, 16'sd0, 16'sd0);
    check((ov_re == 0) && (ov_im == 0), "all-zero input must give all-zero output");

    repeat (50) @(posedge clk);
    if (errors == 0) begin
      $display("PASS: xspec + PHAT (band-limited) -- %0d cycles", cyc);
      $finish;
    end else begin
      $display("FAIL: %0d error(s) after %0d cycles", errors, cyc);
      $finish;
    end
  end

  initial begin
    #20_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
