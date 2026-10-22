// GSC 的 7 路参考**交织成一条流**后，能不能让 SIMD-MAC 阵列当普通 FIR 算？
// 设计见 docs/gsc_vec_design.md，索引恒等式见 build/check_interleave_map.py。
//
// ── 本 TB 补的是恒等式**证不到**的那半 ──────────────────────────────────────
// Python 那步只验了索引。这里验**真 RTL 的寻址**：
//   · PUSH 之后写指针 nq 到底停在哪（推完 7 路后是 7N+7，不是 7N+6）
//   · bank/word 的映射、跨趟的 borrow、加法树
//   · 15 趟（len=14）能不能真的跑完 120 抽头
//
// ── 期望值用闭式，不用查表 ─────────────────────────────────────────────────
//   h[j][n] = n + 10j ，W[j][k] = j+1
//   ⇒ y(N) = Σ_j (j+1)·Σ_k ((N−k) + 10j)
//          = (16N−120)·Σ(j+1) + 160·Σj(j+1) = 28(16N−120) + 160·112 = 448N + 14560
//
// ⚠⚠ **W 必须随 j 变，不能是常数。** 第一版取 W[j][k]=1，期望值就成了
//   Σ_j Σ_k h[j][N−k] —— 它对 **j 的置换不变**，于是"把 ref 顺序搞反"这种错误
//   照样算出正确答案（实测：错位重排给出 4648 = 期望值，判据完全失效）。
//   **对称的期望值查不出对称的错误** —— 与 docs/measurements.md §8 是同一类。
`timescale 1ns/1ps

module tb_gsc_vec_map;

  localparam integer NR = 7;        // 参考路数
  localparam integer LT = 16;       // 每路抽头数
  localparam integer NS = 20;       // 推 20 个 GSC 样点
  localparam integer NT = 120;      // 系数抽头数：8 的倍数，>= 113
  localparam integer NPASS = 15;    // NT/8

  reg clk = 1'b0, rst_n = 1'b0;
  reg        start = 1'b0, commit = 1'b0;
  reg  [1:0] op = 2'b0;
  reg  [5:0] len = 6'b0;
  reg [31:0] scalar = 32'b0;
  reg        acc = 1'b0, coef = 1'b0, data = 1'b0;
  reg  [1:0] ch = 2'b0;
  reg [15:0] xin = 16'b0;

  wire        stall, done;
  wire [31:0] result;
  wire [5:0]  norm_sh;
  wire [15:0] n_x;
  wire [39:0] lane0_acc;

  rv32_vec_unit u_dut (
    .clk_i (clk), .rst_n_i (rst_n),
    .start_i (start), .keep_i (1'b1), .commit_i (commit),
    .op_i (op), .len_i (len), .scalar_i (scalar),
    .acc_i (acc), .wsel_i (coef), .data_i (data), .ch_i (ch), .xin_i (xin),
    .coef_we_i (1'b0), .coef_re_i (1'b0), .coef_src_i (1'b0), .coef_ch_i (1'b0),
    .coef_idx_i (9'b0), .coef_wdata_i (16'b0), .coef_rdata_o (),
    .stall_o (stall), .done_o (done), .result_o (result),
    .norm_sh_o (norm_sh), .n_x_o (n_x), .lane0_acc_o (lane0_acc)
  );

  always #5 clk = ~clk;

  integer errors = 0, cyc = 0, k, j, N, t, exp;
  always @(posedge clk) cyc = cyc + 1;

  task check; input cond; input [8*88-1:0] what;
    begin
      if (!cond) begin errors = errors + 1; $display("  FAIL: %0s", what); end
    end
  endtask

  // tap t 落在 bank (t mod 8)、word (W0_BASE + t/8)。展开成 case：
  // generate 块的层次下标必须是常量，变量下标 iverilog 直接报错（见 tb_vec_unit）。
  task poke_w; input integer bank; input integer word; input [23:0] val;
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

  task issue; input [1:0] o;
    begin
      @(negedge clk); op = o; start = 1'b1;
      @(negedge clk); start = 1'b0;
      while (!done) @(negedge clk);
      commit = 1'b1; @(negedge clk); commit = 1'b0;
    end
  endtask

  // 交织流的位置：X[7n + j]
  function integer pos_of; input integer n; input integer j;
    begin pos_of = NR * n + j; end
  endfunction

  integer cyc_push0, cyc_run0;

  initial begin
    $display("=== tb_gsc_vec_map ===");
    repeat (4) @(negedge clk); rst_n = 1'b1; repeat (4) @(negedge clk);

    // ── 全部 120 抽头先清零（不初始化的话 BRAM 是 X，加法树整条变 X）──────
    for (t = 0; t < NT; t = t + 1) poke_w(t % 8, t / 8, 24'h000000);

    // ── 交织重排： t = (6−j) + 7k ──────────────────────────────────────────
    // 推导：RTL 的 FIR 是 Σ_t w[t]·x(nn − t)，而 nn = line_n − 1
    //   （rv32_vec_unit.v:173）。推完 NR*NS 次后 nn = 7*(NS−1)+6 = 139，
    //   要取到 h[j][N−k] = x(7(N−k)+j) ⇒ t = 139 − 7(N−k) − j = (6−j) + 7k。
    // 系数存 Q15 值 (j+1)：存储 = (j+1) << 8。
    for (j = 0; j < NR; j = j + 1)
      for (k = 0; k < LT; k = k + 1)
        poke_w(((6 - j) + NR * k) % 8, ((6 - j) + NR * k) / 8, (j + 1) << 8);

    // 抽头 112..119 必须还是 0 —— 它们不是任何 (j,k) 的落点
    check(u_dut.g_lane[0].u_cbank.mem_q[14] === 24'h000000, "tap 112 must stay zero");

    // ── 推 NS 个 GSC 样点，每样点 7 路交织 ────────────────────────────────
    cyc_push0 = cyc;
    for (N = 0; N < NS; N = N + 1)
      for (j = 0; j < NR; j = j + 1) begin
        data = 1'b0; ch = 2'b0;                      // x 线（mix 交织流）
        xin  = N + 10 * j;                           // h[j][n] = n + 10j（n 是 GSC 样点号）
                                                     // ⚠ 不是 pos_of(N,j) —— 那是交织位置，两者不同
        issue(2'd0);                                 // OP_PUSH
      end
    check(n_x === (NR * NS), "n_x must advance to 7*NS after all pushes");

    // ── 逐个 N 跑 VRED，比对闭式 112N + 2520 ─────────────────────────────
    // ⚠ 只能在**推完该样点的第 7 路之后**跑 —— nq 才等于 7N+7。
    //   这里全部推完再跑，取的是最后一个完整窗口 N = NS-1；中间那几个窗口
    //   要复现得改推法，本 TB 只验"窗口对不对"，不验"能不能交错推/算"。
    acc = 1'b0; len = NPASS - 1; coef = 1'b0; data = 1'b0; ch = 2'b0;
    cyc_run0 = cyc;
    issue(2'd1);                                     // OP_VRED
    $display("  推 %0d 次 + 跑 %0d 趟：本次 VRED 用 %0d 拍（含握手）",
             NR * NS, NPASS, cyc - cyc_run0);
    $display("  全程 %0d 拍 / %0d 个 GSC 样点 = %0d 拍/样点（只含阵列侧）",
             cyc - cyc_push0, NS, (cyc - cyc_push0) / NS);

    // 最后一个窗口：nq = 7*(NS-1)+7 = 7*NS，取 t 使 x(nq-t) = h[j][NS-1-k]
    // ⇒ 期望 y = Σ_j Σ_k ((NS-1-k) + 10j) = 112*(NS-1) + 2520
    N = NS - 1;
    exp = 448 * N + 14560;
    $display("  result = %0d   闭式期望 448*%0d+14560 = %0d", result, N, exp);
    check(result === exp,
          "interleaved 7-ref FIR must equal the closed form 448N+14560");

    // ── 负例对照：把 ref 0 与 ref 6 的系数对调，**必须算错** ──────────────
    // ⚠ 用"整体挪一格"当负例是**无效**的 —— 那只是把 Σ_j 的求和顺序换了，
    //   而期望值对 j 对称时它照样对（第一版就栽在这里，实测给出 4648 = 期望值）。
    //   对调两路才会真的改变加权和，因为 W 随 j 变。
    // 没有这一步，上面的 OK 分不清"映射对"和"检查是死的"（docs/measurements.md §8）。
    for (t = 0; t < NT; t = t + 1) poke_w(t % 8, t / 8, 24'h000000);
    for (j = 0; j < NR; j = j + 1)
      for (k = 0; k < LT; k = k + 1)
        // 权重换成 (6−j)+1：j=0 拿 7、j=6 拿 1，正好对调
        poke_w(((6 - j) + NR * k) % 8, ((6 - j) + NR * k) / 8, (6 - j + 1) << 8);
    issue(2'd1);
    check(result !== exp,
          "negative control: swapped ref weights MUST fail (else this TB is dead)");
    $display("  负例对照：ref 0/6 对调后给出 %0d（期望仍是 %0d ⇒ 检查是活的）",
             result, exp);

    // ── VUPD 的索引也要在真 RTL 上验（固件的更新走的就是它）──────────────
    // 闭式：系数全 0、样本全取 X0、g = G ⇒ 每个抽头 ΔC = (G·X0) >> **15**
    //   ⚠⚠ 是 **15 不是 16** —— `rv32_vec_unit.v:280` 写的是 `gmul >>> 15`
    //      （注释说"取高 16 位"，但那是 [30:15]，别按注释改成 >>16，差一倍步长）。
    //   ⇒ VRED = NT·((G·X0)>>15)·X0
    // 取 X0 = 256、G = 256 ⇒ ΔC = 65536>>15 = 2 ⇒ 120·2·256 = 61440
    // 取 G = 512        ⇒ ΔC = 4      ⇒ 120·4·256 = 122880
    for (t = 0; t < NT; t = t + 1) poke_w(t % 8, t / 8, 24'h000000);
    for (k = 0; k < 4 * NT; k = k + 1) begin
      xin = 16'd256; data = 1'b0; ch = 2'b0;
      issue(2'd0);
    end
    scalar = 32'd256; acc = 1'b0; len = NPASS - 1;
    issue(2'd2);                                     // OP_VUPD with g = 256
    issue(2'd1);                                     // OP_VRED
    $display("  VUPD g=256: result = %0d   闭式期望 %0d", result, NT * 2 * 256);
    check(result === (NT * 2 * 256),
          "VUPD must land tap t on x(nn-t): sum of 120 taps of (2 * 256)");

    // 负例对照：**重新清零**再换个 g。不重零的话系数是上一轮的 2，结果会是 3 倍不是 2 倍。
    for (t = 0; t < NT; t = t + 1) poke_w(t % 8, t / 8, 24'h000000);
    scalar = 32'd512;
    issue(2'd2);                                     // VUPD，g = 512 ⇒ ΔC = 4
    issue(2'd1);
    $display("  VUPD g=512: result = %0d   闭式期望 %0d", result, NT * 4 * 256);
    check(result === (NT * 4 * 256),
          "negative control: doubling g must double the accumulated weights");

    // ── x′ 延迟线（tgt / oth 两条）在真 RTL 上也要能读 ────────────────────
    // 固件的 e_t 走 x′[0]、e_o 走 x′[1]。实测固件里 e_t 对、e_o 是 **X**
    // ⇒ 怀疑 x′ 线的"有效长度零历史"没盖住。这里逐条线单测。
    // 闭式：系数全 0 → VUPD g=256 让每抽头 ΔC=2；x′ 线全推 256
    //   ⇒ VRED = NT·2·256 = 61440（与 x 线同式）
    for (t = 0; t < NT; t = t + 1) poke_w(t % 8, t / 8, 24'h000000);
    for (k = 0; k < 4 * NT; k = k + 1) begin
      xin = 16'd256; data = 1'b1; ch = 2'd0;         // x′[0]
      issue(2'd0);
    end
    scalar = 32'd256;
    issue(2'd2);                                     // VUPD on x′[0]
    data = 1'b1; ch = 2'd0;
    issue(2'd1);                                     // VRED on x′[0]
    $display("  x'[0] 线: result = %0d   闭式期望 %0d", result, NT * 2 * 256);
    check(result === (NT * 2 * 256), "x'[0] delay line must read back (tgt path)");

    // ⚠⚠ **用 ch=2（x′[2]）而不是 ch=1**：`rv32_vec_unit.v:186` 的
    //    `c_waddr = (ch3_q[0] ? W1_BASE : W0_BASE) + p3_q` 说明 **ch[0] 选的是 w 系数 bank**。
    //    ch=1 → x′[1] 配 **W1**，而 W1 从没被 poke 过 ⇒ 读出来是 X。
    //    GSC 的三条滤波必须共用同一套 W，所以都要落在 W0 ⇒ 只能用 ch=0/2。
    //    （第一版这里写的是 ch=1，实测给 x —— 是**测试选错了 bank**，不是 RTL 坏。）
    for (t = 0; t < NT; t = t + 1) poke_w(t % 8, t / 8, 24'h000000);
    for (k = 0; k < 4 * NT; k = k + 1) begin
      xin = 16'd256; data = 1'b1; ch = 2'd2;         // x′[2]（同 W0）
      issue(2'd0);
    end
    scalar = 32'd256;
    data = 1'b1; ch = 2'd2;
    issue(2'd2);                                     // VUPD on x′[2]
    issue(2'd1);                                     // VRED on x′[2]
    $display("  x'[2] 线(ch=2, W0): result = %0d   闭式期望 %0d", result, NT * 2 * 256);
    check(result === (NT * 2 * 256),
          "x'[2] with ch=2 must use W0 and read back (oth path)");

    if (errors == 0) $display("PASS: tb_gsc_vec_map 全部通过");
    else             $display("FAIL: tb_gsc_vec_map %0d 处不符", errors);
    $finish;
  end

endmodule
