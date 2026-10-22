// 向量单元的功能测试：抽头映射、多趟归约、握手。
//
// **重点验两件事，因为它们是唯一会静默错的**：
//   1. x(n-1) —— 延迟线索引的 borrow 条件错一格时，读出来的是 x(n) 或 x(n-2)，
//      滤波器照样"收敛"，只是收敛到错的东西上；
//   2. x(n-8) —— 跨趟（j=1）时那个 borrow 才真正起作用，j=0 单趟测不到。
// 所以下面 t2 专门测 x(n-1)，t3 专门测 x(n-8)。
//
// w 预装用层次引用直接捅进 bank 存储（和 tb_rv32_soc 捅 ITCM 是同一个做法）——
// 这个版本还没有 PS 侧的预装窗口，那是后面的事。
`timescale 1ns/1ps

module tb_vec_unit;

  localparam integer CAW = 8, DAW = 9;
  localparam [7:0] W0_BASE = 8'd0;

  reg         clk;
  reg         rst_n;
  reg         start;
  reg  [1:0]  op;
  reg  [5:0]  len;
  reg  [31:0] scalar;
  reg         acc;
  reg         coef;
  reg         data;
  // ch 现在是 2 位（4 条 x′ 线，2×2 MIMO 的 filtered-x 需要）。
  // 本 TB 只测 channel 0，但**必须按端口位宽接**——拿 1 位接 2 位端口是 z→x，
  // 而 verify.ps1 把 iverilog 的这条警告当失败（它是在抓真实的悬空端口）。
  reg [1:0]   ch;
  reg  [15:0] xin;
  reg         commit;

  wire        stall;
  wire        done;
  wire [31:0] result;
  wire [5:0]  norm_sh;
  wire [15:0] n_x;
  wire [39:0] lane0_acc;

  reg [31:0] errors;
  integer    cycle_count;

  rv32_vec_unit u_dut (
    .clk_i (clk), .rst_n_i (rst_n),
    .start_i (start), .keep_i (1'b1), .commit_i (commit),
    .op_i (op), .len_i (len), .scalar_i (scalar),
    .acc_i (acc), .wsel_i (coef), .data_i (data), .ch_i (ch), .xin_i (xin),
    // PS 侧预装口：本 TB 直接捅 bank，不走这条口，但输入必须显式接死（漏接是 z→x，
    // 而写使能就是拿 coef_we_i 选的）。
    .coef_we_i (1'b0), .coef_re_i (1'b0), .coef_src_i (1'b0), .coef_ch_i (1'b0),
    .coef_idx_i (9'b0), .coef_wdata_i (16'b0), .coef_rdata_o (),
    .stall_o (stall), .done_o (done), .result_o (result),
    .norm_sh_o (norm_sh), .n_x_o (n_x), .lane0_acc_o (lane0_acc)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycle_count = cycle_count + 1;

  task check;
    input            cond;
    input [8*72-1:0] what;
    begin
      if (!cond) begin
        $display("ERROR: %0s", what);
        errors = errors + 1;
      end
    end
  endtask

  // 直接往系数 bank 里捅一个系数。val 是 Q15+8 小数位的存储格式（即 Q15<<8）。
  // generate 块的层次下标必须是常量，所以这里展开成 case —— 用变量下标 iverilog 直接
  // 报 "Scope index expression is not constant"。
  task poke_w;
    input integer bank;
    input integer word;
    input [23:0]  val;
    begin
      case (bank)
        0: u_dut.g_lane[0].u_cbank.mem_q[word] = val;
        1: u_dut.g_lane[1].u_cbank.mem_q[word] = val;
        2: u_dut.g_lane[2].u_cbank.mem_q[word] = val;
        3: u_dut.g_lane[3].u_cbank.mem_q[word] = val;
        4: u_dut.g_lane[4].u_cbank.mem_q[word] = val;
        5: u_dut.g_lane[5].u_cbank.mem_q[word] = val;
        6: u_dut.g_lane[6].u_cbank.mem_q[word] = val;
        7: u_dut.g_lane[7].u_cbank.mem_q[word] = val;
        default: ;
      endcase
    end
  endtask

  // 发一条指令并等它做完。
  task issue;
    input [1:0] o;
    begin
      @(negedge clk);
      op = o; start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      // 等 done
      while (!done) @(negedge clk);
      commit = 1'b1;
      @(negedge clk);
      commit = 1'b0;
    end
  endtask

  integer k;
  reg [31:0] got;

  initial begin
    clk = 1'b0; rst_n = 1'b0;
    start = 1'b0; op = 2'b0; len = 6'b0; scalar = 32'b0;
    acc = 1'b0; coef = 1'b0; data = 1'b0; ch = 2'b0; xin = 16'b0;
    commit = 1'b0;
    errors = 32'b0; cycle_count = 0;

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    // ── 先把 8 个系数 bank 全清零 ────────────────────────────────────────
    // **不能省**：BRAM 未写的字是 X，而未初始化的 bank 会让整条加法树变 X。
    // 只捅 w[0]/w[1] 的话 bank 2~7 全是 X，结果就是 result=x —— 而 X 在 === 比较下
    // 既不等于期望值也不报"未初始化"，只表现为"算错了"。
    for (k = 0; k < 8; k = k + 1) begin
      poke_w(k, W0_BASE + 0, 24'h000000);
      poke_w(k, W0_BASE + 1, 24'h000000);
    end

    // ── 预装系数：w[0] = 0.5，w[1] = 0.25（Q15）──────────────────────────
    // 存储格式 = Q15 << 8。0.5 -> 0x4000 -> 0x400000；0.25 -> 0x2000 -> 0x200000
    poke_w(0, W0_BASE + 0, 24'h400000);
    poke_w(1, W0_BASE + 0, 24'h200000);

    // ── PUSH 8 个样本进 x 线：x(0..7) = 100,200,...,800 ──────────────────
    for (k = 0; k < 8; k = k + 1) begin
      xin = 100 * (k + 1);
      data = 1'b0; ch = 2'b0;
      issue(2'd0);                       // OP_PUSH
    end
    check(n_x === 16'd8, "PUSH x8: n_x must advance to 8");

    // ── t1：y = w0*x(n) + w1*x(n-1) = 0.5*800 + 0.25*700 = 575 ──────────
    // Q30 = 575 * 32768 = 18841600
    coef = 1'b0; data = 1'b0; ch = 2'b0; acc = 1'b0; len = 6'd0;
    issue(2'd1);                          // OP_VRED
    got = result;
    check(got === 32'd18841600, "t1: w0*x(n) + w1*x(n-1) must equal 575 in Q30");

    // ── t2：只留 w1，y 必须是 x(n-1) 而不是 x(n) ────────────────────────
    // 0.25 * 700 = 175  -> Q30 = 5734400
    poke_w(0, W0_BASE + 0, 24'h000000);
    poke_w(1, W0_BASE + 0, 24'h200000);
    acc = 1'b0; len = 6'd0;
    issue(2'd1);
    got = result;
    check(got === 32'd5734400, "t2: w1 must pick x(n-1), not x(n) -- borrow off-by-one");

    // ── t3：跨趟。push 到 16 个样本，w[8]=0.5，len=1（2 趟）看 x(n-8) ──
    for (k = 0; k < 8; k = k + 1) begin
      xin = 100 * (k + 9);                // x(8..15) = 900,...,1600
      data = 1'b0; ch = 2'b0;
      issue(2'd0);
    end
    check(n_x === 16'd16, "PUSH to 16: n_x must be 16");

    poke_w(0, W0_BASE + 0, 24'h000000);
    poke_w(1, W0_BASE + 0, 24'h000000);
    poke_w(0, W0_BASE + 1, 24'h400000);   // w[8] = 0.5（bank 0，word 1）
    acc = 1'b0; len = 6'd1;               // 2 趟
    issue(2'd1);
    got = result;
    // x(n-8) = x(15-8) = x(7) = 800；0.5*800 = 400 -> Q30 = 13107200
    check(got === 32'd13107200, "t3: tap 8 must pick x(n-8) -- cross-pass borrow");

    // ── t4：多趟累加（acc=1）──────────────────────────────────────────────
    // 先算一次 tap8，再在 acc=1 下再算一次同样的东西，结果应翻倍。
    scalar = 32'b0;
    check(result === 32'd13107200, "t4 pre: baseline still tap 8");
    acc = 1'b1; len = 6'd1;
    issue(2'd1);
    check(result === 32'd26214400, "t4: acc=1 must accumulate onto the previous value");

    // Soft reset must invalidate history without clearing physical BRAM.
    @(negedge clk); rst_n=0; @(negedge clk); rst_n=1;
    acc=0; len=1; issue(2'd1);
    check(result === 0,"reset history masks stale/uninitialised RAM");
    xin=16'h8000; issue(2'd0); len=0; issue(2'd3);
    check(result === 32'd32768,"sum abs(-32768) must be positive 32768");
    // Both accumulator narrowing and weight update saturate, never wrap sign.
    for(k=0;k<8;k=k+1) begin
      poke_w(k,0,24'h7fff00); xin=16'h7fff; data=0; issue(2'd0);
    end
    issue(2'd1); check(result === 32'h7fffffff,"positive VRED overflow saturates");
    data=1;
    for(k=0;k<8;k=k+1) begin xin=16'h7fff; issue(2'd0); end
    scalar=32'h7fff; issue(2'd2);
    check(u_dut.g_lane[0].u_cbank.mem_q[0] === 24'h7fffff,"positive VUPD overflow saturates");
    for(k=0;k<8;k=k+1) begin
      poke_w(k,0,24'h800000); xin=16'h8000; issue(2'd0);
    end
    issue(2'd2);
    check(u_dut.g_lane[0].u_cbank.mem_q[0] === 24'h800000,"negative VUPD overflow saturates");

    if (errors == 0) begin
      $display("PASS: vector unit (taps, cross-pass borrow, accumulate) -- %0d cycles",
               cycle_count);
    end else begin
      $display("FAIL: %0d error(s) after %0d cycles", errors, cycle_count);
    end
    $finish;
  end

  always @(posedge clk) begin
    if (cycle_count > 20000) begin
      $display("FAIL: vec unit TB timed out after %0d cycles", cycle_count);
      $finish;
    end
  end

endmodule
