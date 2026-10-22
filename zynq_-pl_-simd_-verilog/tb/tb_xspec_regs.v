// 互谱 + PHAT 外壳（rv32_xsp_regs）的验收 —— README §20/§21。
//
// 被包住的 rv32_xspec_phat 是**纯流式**块（没有 start/done、没有存储），
// 所以这一层真正要证的是外壳补上的那三样：缓冲、推流 FSM、状态。
//
//   1. 经窗口灌 XI / XJ（各 513 条，{im,re} 打包，靠 ADDR/WDATA 自增）
//   2. START → 轮询 DONE（推流 513 拍 + 3 拍尾巴）
//   3. **inband_cnt 必须正好等于 205** —— 这是白送的自检量：块里那个带内计数器
//      碰到 bin 0 清零，限带是 BIN_LO=5..BIN_HI=209 ⇒ 满帧 = 209−5+1 = 205。
//      不是 205 就说明**限带掩码没在起作用**，而那条掩码正是 docs/issues/027
//      用一整份档案换来的（全带白化 40 dB 混响下定位 0.85 → 5.32 cm）。
//   4. 带外 bin 的 Ψ **恰好为 0**（不是"很小"），带内不为 0 且 |Ψ| ≈ 2^14
//   5. 带内 Ψ 与 TB 自算的 G = X_i·conj(X_j) **共线**（叉积相对量小）
//   6. 反证三条：SEL=3 / RDATA 去读 XI / BUSY 期间写缓冲 ⇒ 都要置 WERR
//
// 与 tb_xspec_phat 的分工：那边测块本身的 3 拍延迟与限带算术（直接驱端口），
// 这边测**经寄存器窗口**能不能把同样的东西推出去、收回来。
`timescale 1ns/1ps

module tb_xspec_regs;

  localparam integer NB     = 513;
  localparam integer AW     = 10;
  localparam integer BIN_LO = 5;
  localparam integer BIN_HI = 209;
  localparam integer INBAND = BIN_HI - BIN_LO + 1;   // 205
  localparam integer MAXC   = 20000;

  localparam [6:0] A_CTRL = 7'h00, A_STATUS = 7'h01, A_ADDR = 7'h02,
                   A_WDATA = 7'h03, A_RDATA = 7'h04, A_VER = 7'h05;
  localparam [1:0] S_XI = 2'd0, S_XJ = 2'd1, S_PSI = 2'd2;

  reg clk = 1'b0;
  always #12.5 clk = ~clk;

  reg         rst_n = 1'b0;
  reg         core_start = 1'b0;
  reg         core_wr = 1'b0, core_rd = 1'b0;
  reg  [6:0]  core_addr = 7'd0;
  reg  [31:0] core_wdata = 32'd0;
  wire [31:0] core_rdata;
  reg         ps_wr = 1'b0, ps_rd = 1'b0;
  reg  [6:0]  ps_addr = 7'd0;
  reg  [31:0] ps_wdata = 32'd0;
  wire [31:0] ps_rdata;
  wire        busy;

  rv32_xsp_regs #(.DW(16), .NB(NB), .BIN_LO(BIN_LO), .BIN_HI(BIN_HI)) u_dut (
    .clk_i        (clk),
    .rst_n_i      (rst_n),
    .core_start_i (core_start),
    .core_wr_i    (core_wr),
    .core_rd_i    (core_rd),
    .core_addr_i  (core_addr),
    .core_wdata_i (core_wdata),
    .core_rdata_o (core_rdata),
    .ps_wr_i      (ps_wr),
    .ps_rd_i      (ps_rd),
    .ps_addr_i    (ps_addr),
    .ps_wdata_i   (ps_wdata),
    .ps_rdata_o   (ps_rdata),
    .busy_o       (busy)
  );

  // ADDR 打包：IDX 低位、SEL 紧挨其上（rv32_xsp_regs.v 的 [11:10]/[9:0]）。
  function [31:0] ad;
    input [1:0] s;
    input [9:0] ix;
    begin
      ad = {20'd0, s, ix};
    end
  endfunction

  integer errors = 0;

  task check;
    input            cond;
    input [8*88-1:0] msg;
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s  (t=%0t)", msg, $time);
      end
    end
  endtask

  task core_write;
    input [6:0]  a;
    input [31:0] d;
    begin
      @(negedge clk); core_wr = 1'b1; core_addr = a; core_wdata = d;
      @(negedge clk); core_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  task core_read;
    input  [6:0]  a;
    output [31:0] d;
    begin
      @(negedge clk); core_rd = 1'b1; core_addr = a;
      #1; d = core_rdata;        // 译码要一个时间步才传播过来（见 tb_srp_regs 的注释）
      @(negedge clk); core_rd = 1'b0;
      @(negedge clk);
    end
  endtask

  // ── 测试数据：确定性的非零值，逐 bin 变化 ─────────────────────────────────
  // 取小幅度整数，既保证 |G| ≠ 0（否则带内也会输出 0，判据就失效），
  // 也保证前导零逻辑落在正常范围。
  reg signed [15:0] ar_t, ai_t, br_t, bi_t;
  integer k, i, mism, nz_out, nz_in, bad_mag, bad_coll;
  reg [31:0] wd, r32;
  integer    psi_re [0:NB-1];
  integer    psi_im [0:NB-1];
  integer    gre    [0:NB-1];
  integer    gim    [0:NB-1];
  // ⚠ 共线判据必须用 real：|G| 能到 1.6e7、|Ψ|≈16384 ⇒ 叉积 ~2.6e11，
  //   32 位 integer 直接溢出；而拿它跟 `16384*|G|²` 比又会因为右边太大
  //   变成**恒真判据**（本项目最恨的那种"永远通过"的空判据）。
  //   TB 里用 real 是允许的 —— docs/issues/040 禁的是**可综合 RTL** 里的 real。
  real       mag, gmag, rel, crossr, ref2r;

  task gen_inputs;
    input integer idx;
    begin
      // 与 bin 号相关但互不相同；避开 0
      ar_t = (idx * 37 + 101) % 4096 + 1;
      ai_t = (idx * 53 + 211) % 4096 + 1;
      br_t = (idx * 29 + 307) % 4096 + 1;
      bi_t = (idx * 61 + 401) % 4096 + 1;
    end
  endtask

  initial begin
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    $display("=== tb_xspec_regs: %0d bins, in-band %0d..%0d ===", NB, BIN_LO, BIN_HI);

    // ── 段 1：经窗口灌 XI 与 XJ ──────────────────────────────────────────
    $display("[1] load XI / XJ through the window");
    core_write(A_ADDR, ad(S_XI, 10'd0));
    for (i = 0; i < NB; i = i + 1) begin
      gen_inputs(i);
      core_write(A_WDATA, {ai_t, ar_t});
    end
    core_write(A_ADDR, ad(S_XJ, 10'd0));
    for (i = 0; i < NB; i = i + 1) begin
      gen_inputs(i);
      core_write(A_WDATA, {bi_t, br_t});
      // TB 自留一份 G = X_i·conj(X_j)，供段 5 判共线
      gre[i] = ar_t * br_t + ai_t * bi_t;
      gim[i] = ai_t * br_t - ar_t * bi_t;
    end

    // ── 段 2：反证 —— 窗口上的三种非法访问 ───────────────────────────────
    $display("[2] negative controls on the window");
    core_write(A_CTRL, 32'h0000_0002);                 // EN=1、清 DONE/WERR
    core_write(A_ADDR, ad(S_XI, 10'd0));
    core_read (A_RDATA, wd);
    core_read (A_STATUS, r32);
    $display("     RDATA with SEL=XI -> data=%08x WERR=%0d", wd, r32[3]);
    check(wd == 32'd0,    "RDATA of XI must return 0 (inputs have no read port)");
    check(r32[3] == 1'b1, "RDATA of XI must raise WERR");

    core_write(A_CTRL, 32'h0000_000A);                 // 清 WERR
    core_write(A_ADDR, ad(2'd3, 10'd0));          // SEL=3 保留值
    core_write(A_WDATA, 32'hDEAD_BEEF);
    core_read (A_STATUS, r32);
    check(r32[3] == 1'b1, "reserved SEL=3 on write must raise WERR");

    // ── 段 3：启动并轮询 ────────────────────────────────────────────────
    $display("[3] start and poll DONE");
    core_write(A_CTRL, 32'h0000_000B);                 // START|EN|CLR_WERR
    core_read (A_STATUS, r32);
    check(r32[0] == 1'b1, "BUSY must be set right after start");
    i = 0;
    core_read(A_STATUS, r32);
    while ((r32[1] !== 1'b1) && (i < MAXC)) begin
      core_read(A_STATUS, r32); i = i + 1;
    end
    check(r32[1] === 1'b1, "stream must finish (DONE) inside MAXC polls");
    $display("     inband_cnt = %0d  (must be %0d)", r32[31:16], INBAND);
    check(r32[31:16] === INBAND[15:0],
          "inband_cnt must equal BIN_HI-BIN_LO+1 -- else the band mask is dead");

    // ── 段 4：回读 Ψ，带外必须**恰好**为 0 ──────────────────────────────
    $display("[4] read Psi back; out-of-band must be exactly zero");
    core_write(A_ADDR, ad(S_PSI, 10'd0));
    for (k = 0; k < NB; k = k + 1) begin
      core_read(A_RDATA, wd);
      psi_re[k] = $signed(wd[15:0]);
      psi_im[k] = $signed(wd[31:16]);
    end
    nz_out = 0; nz_in = 0;
    for (k = 0; k < NB; k = k + 1) begin
      if ((k >= BIN_LO) && (k <= BIN_HI)) begin
        if ((psi_re[k] != 0) || (psi_im[k] != 0)) nz_in = nz_in + 1;
      end else begin
        if ((psi_re[k] != 0) || (psi_im[k] != 0)) nz_out = nz_out + 1;
      end
    end
    $display("     out-of-band nonzero = %0d / %0d ; in-band nonzero = %0d / %0d",
             nz_out, NB - INBAND, nz_in, INBAND);
    check(nz_out == 0,       "every out-of-band bin must be exactly zero");
    check(nz_in == INBAND,   "every in-band bin must be non-zero");

    // ── 段 5：带内 |Ψ| ≈ 2^14，且与 G 共线 ──────────────────────────────
    $display("[5] in-band magnitude and collinearity");
    bad_mag = 0; bad_coll = 0;
    for (k = BIN_LO; k <= BIN_HI; k = k + 1) begin
      mag  = $sqrt(1.0*psi_re[k]*psi_re[k] + 1.0*psi_im[k]*psi_im[k]);
      gmag = $sqrt(1.0*gre[k]*gre[k] + 1.0*gim[k]*gim[k]);
      // 幅值近似（α-max-β-min，误差 < 4%）+ Q2.14 取整 ⇒ 给 ±20% 的带宽
      ref2r = 16384.0;
      if ((mag < ref2r*0.80) || (mag > ref2r*1.20)) bad_mag = bad_mag + 1;
      // 共线：|Ψ × G| / (|Ψ||G|) = |sin θ| 要小。浮点比较，避免整数溢出。
      crossr = 1.0*psi_re[k]*gim[k] - 1.0*psi_im[k]*gre[k];
      if (crossr < 0.0) crossr = -crossr;
      rel = crossr / (mag * gmag + 1.0);
      if (rel > 0.08) bad_coll = bad_coll + 1;
    end
    $display("     worst-case collinearity is checked at |sin theta| <= 0.08");
    $display("     |Psi| out of band = %0d bins ; collinearity = %0d bins",
             bad_mag, bad_coll);
    check(bad_mag  == 0, "in-band |Psi| must be ~2^14 (unit magnitude in Q2.14)");
    check(bad_coll == 0, "in-band Psi must be collinear with G = Xi*conj(Xj)");

    // ── 段 6：反证 —— BUSY 期间写缓冲必须被拒 ──────────────────────────
    $display("[6] negative control: writing the buffers while BUSY is refused");
    core_write(A_CTRL, 32'h0000_000B);                 // 再启动一次
    core_write(A_ADDR, ad(S_XI, 10'd0));
    core_write(A_WDATA, 32'h0000_1234);
    core_read (A_STATUS, r32);
    $display("     WERR while busy = %0d, BUSY = %0d", r32[3], r32[0]);
    check(r32[0] === 1'b1, "must still be busy when the write was attempted");
    check(r32[3] == 1'b1,  "a write to the buffers while BUSY must raise WERR");

    core_write(A_VER, 32'h0000_5AA5);
    core_read (A_VER, r32);
    check(r32[15:0] === 16'h5AA5, "VERSION is a dummy register: write must read back");

    repeat (20) @(posedge clk);
    if (errors == 0) begin
      $display("PASS: xspec_regs -- %0d bins streamed through the window", NB);
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #20_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
