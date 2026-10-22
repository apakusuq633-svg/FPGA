// 声学扩展单元的单元级验证 —— 四条指令各跑一遍，逐字对定点参照。
//
// 参照由 scripts/golden/fw_acou_model.py 生成（与这里三方一致：模型 / TB / RTL）。
// 这样做的好处是出错时**立刻能分清**是 RTL 错还是参照错 —— 模型秒级出结果，
// 而这个 TB 要跑 512×4 条 PUSH/POP。
//
// 覆盖面：
//   VCMUL  复数乘（含 Q30→Q15 的四舍五入）
//   VSUB   共轭乘（与 VCMUL 共用乘法器，只翻 bi 的符号 —— 这一条最容易写漏）
//   VPHAT  白化 + 限带（4-bit 倒数 LUT，带外必须清 0）
//   VRED2  对偶归约（打包 {ΣIm, ΣRe}）
`timescale 1ns/1ps

module tb_acoustic_ext #(parameter LANES=8);

  // 只放带内：原频谱 bin 6..213（有效 6..209），见 rtl/acoustic/ 头部
  localparam integer CN = 208;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;
  reg        start, commit;
  reg [2:0]  op;
  reg        is_io;
  reg [1:0]  io_sel;
  reg [31:0] scalar;
  wire       stall, done;
  wire [31:0] result;

  rv32_acoustic_ext #(.LANES(LANES)) u_dut (
    .clk_i    (clk),
    .rst_n_i  (rst_n),
    .start_i  (start),
    .keep_i   (1'b1),
    .commit_i (commit),
    .op_i     (op),
    .is_io_i  (is_io),
    .io_sel_i (io_sel),
    .scalar_i (scalar),
    .stall_o  (stall),
    .done_o   (done),
    .result_o (result)
  );

  reg [31:0] vx   [0:CN-1];
  reg [31:0] vy   [0:CN-1];
  reg [31:0] ref_mul [0:CN-1];
  reg [31:0] ref_sub [0:CN-1];
  reg [31:0] ref_phat[0:CN-1];
  reg [31:0] ref_red [0:0];

  integer errors = 0;
  integer i, n_bad, first_bad;
  integer cyc = 0;
  integer c_push = 0, c_mul = 0, c_pop = 0;
  integer c_sub=0, c_phat=0, c_red=0, cyc_before=0;
  reg [31:0] got;

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

  // 计算类：拉 start，等 done，再 commit 回 IDLE
  task run_op;
    input [2:0] o;
    input       io;
    input [1:0] sel;
    input [31:0] dat;
    begin
      @(negedge clk);
      start = 1'b1; op = o; is_io = io; io_sel = sel; scalar = dat;
      @(negedge clk);
      start = 1'b0;
      while (!done) @(negedge clk);
      commit = 1'b1;
      @(negedge clk);
      commit = 1'b0;
    end
  endtask

  // 单拍 PUSH/POP：**一条一拍**。commit 与 start 同拍（核就是那么接的），
  // 所以这里也同拍给 —— 不给的话单元按 io_fire 判据不动作，一条都发不出去。
  task run_io;
    input [1:0] sel;
    input [31:0] dat;
    begin
      @(negedge clk);
      start = 1'b1; is_io = 1'b1; io_sel = sel; scalar = dat; commit = 1'b1;
      // ⚠ 必须**在下一个 posedge 之前**采样：那一拍指针会自增，而 POP 读的是
      //   自增前的地址。放在 negedge 之后采，整条序列就差一格 ——
      //   而差一格的相关序列看着仍然"像相关的样子"。
      #1; got = result;
      @(negedge clk);
      start = 1'b0; commit = 1'b0;
    end
  endtask

  initial begin
    $display("=== tb_acoustic_ext ===");
    $readmemh("build/acou_x.hex", vx);
    $readmemh("build/acou_y.hex", vy);
    $readmemh("build/acou_z_vcmul.hex", ref_mul);
    $readmemh("build/acou_z_vsub.hex", ref_sub);
    $readmemh("build/acou_z_vphat.hex", ref_phat);
    $readmemh("build/acou_red2.hex", ref_red);

    start = 0; commit = 0; op = 0; is_io = 0; io_sel = 0; scalar = 0;
    rst_n = 1'b0;
    repeat (10) @(negedge clk);
    rst_n = 1'b1;

    // ── 装载 X 与 Y（各 CN 条 PUSH，单拍）──────────────────────────
    c_push = cyc;
    for (i = 0; i < CN; i = i + 1) run_io(2'b00, vx[i]);
    for (i = 0; i < CN; i = i + 1) run_io(2'b01, vy[i]);
    c_push = cyc - c_push;

    // ── VCMUL ──────────────────────────────────────────────────────
    c_mul = cyc;
    run_op(3'd0, 1'b0, 2'b00, 32'd0);
    c_mul = cyc - c_mul;
    n_bad = 0;  first_bad = -1;
    c_pop = cyc;
    for (i = 0; i < CN; i = i + 1) begin
      run_io(2'b10, 32'd0);                 // POP（单拍，读数在 run_io 里采）
      if (got !== ref_mul[i]) begin
        n_bad = n_bad + 1;
        if (first_bad < 0) begin
          first_bad = i;
          $display("  首个不符: VCMUL[%0d] 实测 %08x 期望 %08x", i, got, ref_mul[i]);
        end
      end
    end
    c_pop = cyc - c_pop;
    $display("  VCMUL: %0d/%0d 条不符", n_bad, CN);
    check(n_bad == 0, "VCMUL must match the fixed-point reference");

    // ── 拍数账：这是这个设计最要紧的一组数字 ────────────────────────
    $display("");
    $display("  ── 拍数账（%0d 条复数 = 只搬带内那一段）──", CN);
    $display("     装载 X+Y (%0d 次 PUSH)   : %0d 拍", 2*CN, c_push);
    $display("     VCMUL  (%0d 趟 × %0d lane) : %0d 拍", CN/LANES, LANES, c_mul);
    $display("     取回 Z  (%0d 次 POP)     : %0d 拍", CN, c_pop);
    $display("     合计 %.0f 拍，其中**搬运占 %.1f%%**",
             c_push + c_mul + c_pop,
             100.0 * (c_push + c_pop) / (c_push + c_mul + c_pop));
    $display("     旧口径（512 条整段搬 + 3 拍握手）：4676 拍");
    $display("     => 同样搬 %0d 条，%0d 拍 vs %0d 拍，**快 %.2f 倍**",
             2*CN, c_push + c_mul + c_pop, 4676,
             4676.0 / (c_push + c_mul + c_pop));
    $display("     ⚠ 这只是**单元级**口径，没算核侧的 lw/sw（+约 60%%）。");
    $display("        端到端收益要回到固件里量，见 docs/issues/036。");
    $display("");

    // ── VSUB（Z = X·conj(Y)）───────────────────────────────────────
    cyc_before = cyc;
    run_op(3'd2, 1'b0, 2'b00, 32'd0);
    c_sub = cyc - cyc_before;
    n_bad = 0;  first_bad = -1;
    for (i = 0; i < CN; i = i + 1) begin
      run_io(2'b10, 32'd0);
      if (got !== ref_sub[i]) begin
        n_bad = n_bad + 1;
        if (first_bad < 0) begin
          first_bad = i;
          $display("  首个不符: VSUB[%0d] 实测 %08x 期望 %08x", i, got, ref_sub[i]);
        end
      end
    end
    $display("  VSUB:  %0d/%0d 条不符", n_bad, CN);
    check(n_bad == 0, "VSUB must match the fixed-point reference");

    // ── VPHAT（就地白化上面那份 Z）─────────────────────────────────
    cyc_before = cyc;
    run_op(3'd1, 1'b0, 2'b00, 32'd0);
    c_phat = cyc - cyc_before;
    n_bad = 0;  first_bad = -1;
    for (i = 0; i < CN; i = i + 1) begin
      run_io(2'b10, 32'd0);
      if (got !== ref_phat[i]) begin
        n_bad = n_bad + 1;
        if (first_bad < 0) begin
          first_bad = i;
          $display("  首个不符: VPHAT[%0d] 实测 %08x 期望 %08x", i, got, ref_phat[i]);
        end
      end
    end
    $display("  VPHAT: %0d/%0d 条不符", n_bad, CN);
    check(n_bad == 0, "VPHAT must match the fixed-point reference");

    // ── VRED2（对 X 做对偶归约）────────────────────────────────────
    cyc_before = cyc;
    run_op(3'd3, 1'b0, 2'b00, 32'd0);
    c_red = cyc - cyc_before;
    $display("  VRED2: 实测 %08x 期望 %08x", result, ref_red[0]);
    check(result === ref_red[0], "VRED2 must match the fixed-point reference");

    if (errors == 0) begin
      $display("ACOU_LANE_PASS lanes=%0d push=%0d mul=%0d sub=%0d phat=%0d pop=%0d red=%0d", LANES,c_push,c_mul,c_sub,c_phat,c_pop,c_red);
      $display("PASS: 声学扩展四条指令与定点参照逐位一致");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #(CN * 4 * 40 * 10);
    $display("FAIL: timeout");
    $finish;
  end

endmodule
