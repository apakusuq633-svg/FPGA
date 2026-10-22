// SRP 空间扫描的验收测试（README §23 / §24 / §25）。
//
// 对照方式：**逐位精确**。向量与参照都由 scripts/golden/gen_srp_vectors.py 生成，
// 那份参照是用**量化后的 16 位 R**、按 RTL 的同一条算术（向下取整的插值 +
// int32 回绕累加）算出来的。所以 RTL 与参照之间只该有实现差别，不该有精度差别。
//
// 四段：
//   1. 装载 LUT 与 R，启动，等 done（验证每格每对 4 拍及末尾提交）；
//   2. 读出 1024 个累加器值与参照**逐条**比，必须**完全相等**；
//   3. 峰值位置与声源真值的一致性（算法层面）；
//   4. 反证：把 LUT 的小数位清零（等价于关掉插值）再跑一遍，
//      P 必须**明显不同** —— 否则第 2 段的"相等"证明不了插值路径是活的。
//      （这条直接对应 fixed_model.py 实测的「无插值劣化 3.65×」）
`timescale 1ns/1ps

module tb_srp_scan;

  localparam integer N_PAIR = 28;
  localparam integer N_GRID = 1024;
  localparam integer IDX_W  = 10;
  localparam integer FRAC_W = 4;
  localparam integer DW     = 16;
  localparam integer LUT_W  = IDX_W + FRAC_W;
  localparam integer MAXC   = 400000;

  reg clk = 1'b0;
  always #12.5 clk = ~clk;

  reg rst_n = 1'b0;
  reg en    = 1'b0;

  reg                    start;
  wire                   busy, done;
  reg                    lut_we;
  reg  [14:0]            lut_addr;
  reg  [LUT_W-1:0]       lut_data;
  reg                    r_we;
  reg  [14:0]            r_addr;
  reg  signed [DW-1:0]   r_data;
  reg  [IDX_W-1:0]       p_addr;
  wire signed [31:0]     p_data;
  wire [31:0]            cyc_cnt;

  rv32_srp_scan #(
    .N_PAIR(N_PAIR), .N_GRID(N_GRID), .IDX_W(IDX_W),
    .FRAC_W(FRAC_W), .DW(DW)
  ) u_dut (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .start_i (start), .busy_o (busy), .done_o (done),
    .lut_we_i (lut_we), .lut_addr_i (lut_addr), .lut_data_i (lut_data),
    .r_we_i (r_we), .r_addr_i (r_addr), .r_data_i (r_data),
    .p_addr_i (p_addr), .p_data_o (p_data),
    .cycle_cnt_o (cyc_cnt)
  );

  integer errors = 0;

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

  integer ref_mem [0:N_GRID-1];
  integer got_mem [0:N_GRID-1];
  integer i, k, mismatch, first_bad;
  reg [31:0] raw;
  integer cyc0, cyc1, per_grid;
  integer pk_ref, pk_got;

  task run_scan;
    begin
      @(negedge clk);
      start = 1'b1;
      @(posedge clk);
      @(negedge clk); start = 1'b0;
      i = 0;
      while (!done && (i < MAXC)) begin
        @(posedge clk); i = i + 1;
      end
      check(done === 1'b1, "scan must finish inside MAXC cycles");
      @(posedge clk);
    end
  endtask

  task read_p;
    begin
      for (k = 0; k < N_GRID; k = k + 1) begin
        @(negedge clk); p_addr = k[IDX_W-1:0];
        @(posedge clk); #1;
        got_mem[k] = $signed(p_data);
      end
      @(negedge clk); p_addr = 10'd0;
    end
  endtask

  initial begin
    start = 0; lut_we = 0; r_we = 0; p_addr = 0;
    lut_addr = 0; lut_data = 0; r_addr = 0; r_data = 0;

    $readmemh("build/srp_lut.hex", u_dut.lut_mem);
    $readmemh("build/srp_r.hex",   u_dut.r_mem);
    $readmemh("build/srp_p_ref.hex", ref_mem);

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    en    = 1'b1;
    repeat (4) @(posedge clk);

    $display("=== tb_srp_scan: %0d pairs x %0d grid ===", N_PAIR, N_GRID);

    // ── 段 1：跑一遍 ────────────────────────────────────────────────
    $display("[1] run");
    cyc0 = cyc_cnt;
    run_scan;
    cyc1 = cyc_cnt;
    per_grid = (cyc1 - cyc0) / (N_PAIR * N_GRID);
    $display("     cycles = %0d  ->  %0d cycles/(pair,grid)", cyc1 - cyc0, per_grid);
    check(per_grid == 4, "must be 4 cycles per (pair,grid)");

    // ── 段 2：逐条比对 ──────────────────────────────────────────────
    $display("[2] accumulator vs reference (bit-exact)");
    read_p;
    mismatch = 0; first_bad = -1;
    for (k = 0; k < N_GRID; k = k + 1) begin
      if (got_mem[k] !== ref_mem[k]) begin
        mismatch = mismatch + 1;
        if (first_bad < 0) begin
          first_bad = k;
          $display("     first mismatch @grid %0d : got %0d  ref %0d",
                   k, got_mem[k], ref_mem[k]);
        end
      end
    end
    $display("     mismatches = %0d / %0d", mismatch, N_GRID);
    check(mismatch == 0, "every accumulator value must match the reference exactly");

    // ── 段 3：峰值位置 ──────────────────────────────────────────────
    $display("[3] peak location");
    pk_ref = 0;
    for (k = 1; k < N_GRID; k = k + 1) if (ref_mem[k] > ref_mem[pk_ref]) pk_ref = k;
    pk_got = 0;
    for (k = 1; k < N_GRID; k = k + 1) if (got_mem[k] > got_mem[pk_got]) pk_got = k;
    $display("     ref peak grid = %0d,  dut peak grid = %0d", pk_ref, pk_got);
    check(pk_got == pk_ref, "peak grid index must match the reference");

    // ── 段 4：反证 —— 关掉插值，P 必须明显不同 ──────────────────────
    $display("[4] negative control: zero the fractional weights (interp OFF)");
    for (i = 0; i < N_PAIR * N_GRID; i = i + 1)
      u_dut.lut_mem[i] = u_dut.lut_mem[i] & ~((1 << FRAC_W) - 1);

    run_scan;
    read_p;
    begin : neg_blk
      integer ndiff;
      real    relchg;
      integer sum_a, sum_b;
      ndiff = 0; sum_a = 0; sum_b = 0;
      for (k = 0; k < N_GRID; k = k + 1) begin
        if (got_mem[k] !== ref_mem[k]) ndiff = ndiff + 1;
        sum_a = sum_a + (ref_mem[k] > 0 ? ref_mem[k] : -ref_mem[k]);
        sum_b = sum_b + (got_mem[k] > 0 ? got_mem[k] : -got_mem[k]);
      end
      relchg = (sum_b - sum_a) * 100.0 / (sum_a + 1);
      $display("     with interp OFF: %0d/%0d values differ, sum |P| changed %+.2f%%",
               ndiff, N_GRID, relchg);
      check(ndiff > N_GRID / 4,
            "interp OFF must change a large fraction of the map (else interp is dead)");
    end

    repeat (50) @(posedge clk);
    if (errors == 0) begin
      $display("PASS: SRP scan, bit-exact vs golden -- %0d cycles", cyc1 - cyc0);
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #200_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
