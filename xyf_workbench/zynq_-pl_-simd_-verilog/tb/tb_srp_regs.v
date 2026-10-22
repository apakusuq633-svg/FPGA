// SRP 加速器外壳（rv32_srp_regs）的验收 —— README §23/§24/§25。
//
// 测的是**寄存器窗口这一层**，不是扫描算术（那个归 tb_srp_scan）：
//   1. 经窗口灌 LUT 与 R（ADDR 选数组、WDATA 自增）→ CTRL 启动 → 轮询 DONE
//      → 经 RDATA 自增回读 P，与参照**逐条逐位**相等
//   2. **PS 侧口**再读一遍同一批 P，两侧必须同值（同一组寄存器，两个端口）
//   3. 反证三条（都是"不报错只算错"的形状，所以必须让它们**可见**）：
//      a. BUSY 期间写 R ⇒ WERR 置位，且 R 的内容**没变**
//      b. RDATA 去读 LUT ⇒ WERR 置位、返回 0（LUT/R 在块里没有读口）
//      c. SEL=3（保留值）写 ⇒ WERR 置位
//
// 规模取 **SoC 里实际例化的那一档**（4 对 × 16×16，R 行长 1024），
// 向量由 scripts/golden/gen_srp_vectors.py --pairs 4 --grid-w 16 --out-prefix srp4x256 生成。
// 全尺寸（28 对 × 1024 格）的算术覆盖在 tb_srp_scan。
//
// 访问时序：每次访问**恰好一拍**、两笔之间**隔一拍**（核侧由 rv32_soc 的
// `& ~mmio_ack_q` 保证，PS 侧 AXI 本来就是 2 拍/笔）。下面 core_read/core_write
// 就是照着这个节奏写的 —— 时序不对的话 P 的同步读口会读到上一格的旧值。
`timescale 1ns/1ps

module tb_srp_regs;

  localparam integer N_PAIR = 4;
  localparam integer N_GRID = 256;
  localparam integer R_LEN  = 1024;
  localparam integer IDX_W  = 10;
  localparam integer FRAC_W = 4;
  localparam integer LUT_W  = IDX_W + FRAC_W;
  localparam integer NLUT   = N_PAIR * N_GRID;      // 1024
  localparam integer NRE    = N_PAIR * R_LEN;       // 4096
  localparam integer MAXC   = 200000;

  localparam [6:0] A_CTRL = 7'h00, A_STATUS = 7'h01, A_ADDR = 7'h02, A_WDATA = 7'h03,
                   A_RDATA = 7'h04, A_CYCLES = 7'h05, A_RUNCYC = 7'h06, A_VER = 7'h07;
  localparam [1:0] S_LUT = 2'd0, S_R = 2'd1, S_P = 2'd2;

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

  rv32_srp_regs #(
    .N_PAIR (N_PAIR), .N_GRID (N_GRID), .R_LEN (R_LEN),
    .IDX_W  (IDX_W),  .FRAC_W (FRAC_W), .DW (16)
  ) u_dut (
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

  // ── 核侧访问：恰好一拍 + 隔一拍（照 rv32_soc 的 MMIO 隔拍应答）────────────
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
      // ⚠ 必须 #1 再采：core_addr/core_rd 与这个赋值在**同一时刻**变，
      //   而读译码是另一个 always 进程，同一时间步里还没重算 ——
      //   不加延迟采到的是**上一笔**的值。症状是"读什么都是上一个寄存器的数"。
      #1; d = core_rdata;                // 请求拍的组合值（核就是这么采的）
      @(negedge clk); core_rd = 1'b0;
      @(negedge clk);
    end
  endtask

  // PS 侧访问：AXI 本来就是单拍脉冲 + 2 拍/笔
  task ps_write;
    input [6:0]  a;
    input [31:0] d;
    begin
      @(negedge clk); ps_wr = 1'b1; ps_addr = a; ps_wdata = d;
      @(negedge clk); ps_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  task ps_read;
    input  [6:0]  a;
    output [31:0] d;
    begin
      @(negedge clk); ps_rd = 1'b1; ps_addr = a;
      #1; d = ps_rdata;                  // 同上：译码要一个时间步才传播过来
      @(negedge clk); ps_rd = 1'b0;
      @(negedge clk);
    end
  endtask

  // LUT/R 都用"写 ADDR 选数组 → 连续写 WDATA"，靠窗口自增走完全程
  integer i, k, mism;

  // ADDR 的打包：IDX 在低位、SEL 紧挨其上（与 rv32_srp_regs.v 的 [16:15]/[14:0] 同布局）。
  // 别用 {14'd0, sel, 15'd0} 之类的随手拼接 —— SEL 会落到 [16:15] 之外，
  // 截断到 32 位后静默变 0，于是所有写都进 LUT。
  function [31:0] ad;
    input [1:0]  s;
    input [14:0] ix;
    begin
      ad = {15'd0, s, ix};
    end
  endfunction
  integer ref_p [0:N_GRID-1];
  integer got_p [0:N_GRID-1];
  integer got_ps [0:N_GRID-1];
  reg [31:0] r32;
  reg [15:0] lut_ref [0:NLUT-1];
  reg [15:0] r_ref   [0:NRE-1];
  reg [15:0] r_snap  [0:3];        // 反证 a 用：被拒写入前后各取 4 条
  reg [31:0] wd;

  initial begin
    $readmemh("build/srp4x256_lut.hex",   lut_ref);
    $readmemh("build/srp4x256_r.hex",     r_ref);
    $readmemh("build/srp4x256_p_ref.hex", ref_p);

    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    $display("=== tb_srp_regs: %0d pairs x %0d grid, R_LEN %0d ===",
             N_PAIR, N_GRID, R_LEN);

    // ── 段 1：灌 LUT ────────────────────────────────────────────────────
    $display("[1] load LUT via the ADDR/WDATA window (auto-increment)");
    core_write(A_ADDR, ad(S_LUT, 15'd0));
    for (i = 0; i < NLUT; i = i + 1)
      core_write(A_WDATA, {16'd0, lut_ref[i][LUT_W-1:0]});
    // 窗口位选不回读，直接看块里的存储（TB 有权看内部，同 tb_srp_scan）
    mism = 0;
    for (i = 0; i < NLUT; i = i + 1)
      if (u_dut.u_scan.lut_mem[i] !== lut_ref[i][LUT_W-1:0]) mism = mism + 1;
    $display("     LUT mismatches = %0d / %0d", mism, NLUT);
    check(mism == 0, "LUT loaded through the window must match the vector file");

    // ── 段 2：灌 R ──────────────────────────────────────────────────────
    $display("[2] load R via the window (SEL=R, 4096 entries)");
    core_write(A_ADDR, ad(S_R, 15'd0));
    for (i = 0; i < NRE; i = i + 1)
      core_write(A_WDATA, {16'd0, r_ref[i]});
    mism = 0;
    for (i = 0; i < NRE; i = i + 1)
      if (u_dut.u_scan.r_mem[i] !== $signed(r_ref[i])) mism = mism + 1;
    $display("     R mismatches = %0d / %0d", mism, NRE);
    check(mism == 0, "R loaded through the window must match the vector file");

    // ── 段 3：反证 b/c —— 两个"静默错"形状必须变成可见的 WERR ─────────────
    $display("[3] negative controls on the window");
    core_write(A_CTRL, 32'h0000_0002);              // EN=1, 清 DONE
    core_write(A_ADDR, ad(S_LUT, 15'd0));      // SEL=LUT
    core_read (A_RDATA, wd);
    core_read (A_STATUS, r32);
    $display("     read LUT via RDATA -> data=%08x WERR=%0d", wd, r32[3]);
    check(wd == 32'd0,   "RDATA of LUT must return 0 (LUT has no read port)");
    check(r32[3] == 1'b1, "RDATA of LUT must raise the sticky WERR");

    core_write(A_CTRL, 32'h0000_000A);              // 清 DONE + 清 WERR（bit3）
    core_write(A_ADDR, ad(2'd3, 15'd0));       // SEL=3 保留值
    core_write(A_WDATA, 32'hDEAD_BEEF);
    core_read (A_STATUS, r32);
    $display("     write SEL=3 -> WERR=%0d", r32[3]);
    check(r32[3] == 1'b1, "reserved SEL=3 on write must raise WERR");

    // ── 段 4：启动并轮询 ────────────────────────────────────────────────
    $display("[4] start (CTRL = START|EN) and poll DONE");
    core_write(A_CTRL, 32'h0000_000B);              // START|EN|CLR_WERR
    core_read (A_STATUS, r32);
    check(r32[0] == 1'b1, "BUSY must be set right after start");
    i = 0;
    core_read(A_STATUS, r32);
    while ((r32[1] !== 1'b1) && (i < MAXC)) begin
      core_read(A_STATUS, r32); i = i + 1;
    end
    check(r32[1] === 1'b1, "scan must finish (DONE) inside MAXC polls");
    core_read(A_RUNCYC, r32);
    $display("     RUN_CYCLES = %0d  (expect 4*pair*grid+1 = %0d + overhead)",
             r32, 4 * N_PAIR * N_GRID + 1);
    check(r32 >= 4 * N_PAIR * N_GRID + 1, "RUN_CYCLES must cover scan and final RAM write");

    // ── 段 5：经核侧窗口回读 P，与参照逐条比 ────────────────────────────
    $display("[5] read P through the window, bit-exact vs reference");
    core_write(A_ADDR, ad(S_P, 15'd0));
    for (k = 0; k < N_GRID; k = k + 1) begin
      core_read(A_RDATA, wd);
      got_p[k] = $signed(wd);
    end
    mism = 0;
    for (k = 0; k < N_GRID; k = k + 1)
      if (got_p[k] !== ref_p[k]) begin
        mism = mism + 1;
        if (mism == 1)
          $display("     first mismatch @grid %0d: got %0d ref %0d", k, got_p[k], ref_p[k]);
      end
    $display("     P mismatches = %0d / %0d", mism, N_GRID);
    check(mism == 0, "P read back through the window must match the reference exactly");

    // ── 段 6：同一批 P 从 PS 侧口再读一遍，两侧必须同值 ──────────────────
    $display("[6] read the same P through the PS-side port");
    ps_write(7'h02, ad(S_P, 15'd0));
    for (k = 0; k < N_GRID; k = k + 1) begin
      ps_read(7'h04, wd);
      got_ps[k] = $signed(wd);
    end
    mism = 0;
    for (k = 0; k < N_GRID; k = k + 1)
      if (got_ps[k] !== got_p[k]) mism = mism + 1;
    $display("     core-vs-PS mismatches = %0d / %0d", mism, N_GRID);
    check(mism == 0, "both ports must read the same register file");

    // ── 段 7：反证 a —— BUSY 期间写 R 必须被拒且数据不变 ─────────────────
    $display("[7] negative control: writing R while BUSY must be refused");
    for (i = 0; i < 4; i = i + 1) r_snap[i] = u_dut.u_scan.r_mem[i];
    // ⚠ CTRL 是整体写：0xA = bit1|bit3（EN + CLR_WERR）**没有 START**，
    //   写成 0xA 的话扫描根本不会启动，后面"BUSY 期间写被拒"就成了空判据。
    //   要启动就得把 bit0 也置上 ⇒ 0xB。
    core_write(A_CTRL, 32'h0000_000B);              // START|EN|CLR_WERR
    core_write(A_ADDR, ad(S_R, 15'd0));
    core_write(A_WDATA, 32'h0000_1234);             // BUSY 期间写
    core_read (A_STATUS, r32);
    $display("     WERR while busy = %0d, BUSY = %0d", r32[3], r32[0]);
    check(r32[0] === 1'b1, "must still be busy when the write was attempted");
    check(r32[3] == 1'b1, "a write to R while BUSY must raise WERR");
    mism = 0;
    for (i = 0; i < 4; i = i + 1)
      if (u_dut.u_scan.r_mem[i] !== r_snap[i]) mism = mism + 1;
    check(mism == 0, "the refused write must not have changed R");

    // ── 段 8：哑寄存器自检 ──────────────────────────────────────────────
    core_write(A_VER, 32'h0000_A55A);
    core_read (A_VER, r32);
    check(r32[15:0] === 16'hA55A, "VERSION is a dummy register: write must read back");

    repeat (20) @(posedge clk);
    if (errors == 0) begin
      $display("PASS: srp_regs window, P bit-exact -- %0d pairs x %0d grid",
               N_PAIR, N_GRID);
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #50_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
