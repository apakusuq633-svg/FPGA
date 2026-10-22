// 波束转向几何核 rv32_steer 的逐位验收（「定位那一格 → 8 路补偿」）。
//
// 四段：
//   1. **逐格逐路**：256 个格点 × 8 路 comp，对着 build/steer_comp_ref.hex 逐位比。
//      参照是 gen_steer_vectors.py **用还原后的 τ** 算的（同一条截断），
//      所以这里比的是"实现对不对"，不是"截断误差多大"。
//   2. **反证：LUT 真的被读了吗** —— 改动 LUT 的一个字，输出必须跟着变。
//      不做这一段的话，"输出恰好对"可能来自任何巧合；
//      而 gen_srp_vectors 的教训正是「两边一起错，TB 照样通过」。
//   3. **反证：target 真的被用了吗** —— 两个不同格点的 comp 必须不同。
//      若 target 没接进地址，所有格点会给出同一组 comp，而它们仍是"合法值"。
//   4. 拍数：一趟（8 查表 + 求 min + 相减）应当是个常数，报出来。
//
// ⚠ 同步读的采样时刻：comp_data_o 比 comp_idx_i 晚一拍，
//   所以设完 idx 之后要 `@(posedge clk); #1;` 再采（issues/078 同族）。
`timescale 1ns/1ps

module tb_steer;

  localparam integer N_GRID  = 256;
  localparam integer IDX_W   = 10;
  localparam integer FRAC_W  = 4;
  localparam integer N_MIC   = 8;
  localparam integer N_LUT   = N_MIC * N_GRID;         // 2048 = 8 行 x 256 格
  localparam integer LUT_W   = IDX_W + FRAC_W;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;
  reg en = 1'b0;

  reg                    start = 1'b0;
  reg  [IDX_W-1:0]       target = 10'd0;
  wire                   busy, done;
  reg                    lut_we = 1'b0;
  reg  [15:0]            lut_addr = 16'd0;
  reg  [LUT_W-1:0]       lut_data = 14'd0;
  reg  [3:0]             comp_idx = 4'd0;
  wire signed [31:0]     comp_data;

  rv32_steer #(
    .N_GRID (N_GRID), .IDX_W (IDX_W), .FRAC_W (FRAC_W), .N_MIC (N_MIC)
  ) u_dut (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .start_i (start), .target_i (target),
    .busy_o (busy), .done_o (done),
    .lut_we_i (lut_we), .lut_addr_i (lut_addr), .lut_data_i (lut_data),
    .comp_idx_i (comp_idx), .comp_data_o (comp_data)
  );

  reg [LUT_W-1:0] lut_img [0:N_LUT-1];
  reg [31:0]      comp_ref [0:N_GRID*N_MIC-1];

  integer errors = 0;
  integer i, g, m, cyc, t0, dt;
  reg [31:0] got, exp;

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

  // 设一个 comp 下标，等同步读一拍，取回数据
  task read_comp;
    input  [3:0]  idx;
    output [31:0] v;
    begin
      @(negedge clk); comp_idx = idx;
      @(posedge clk); #1; v = comp_data;
    end
  endtask

  // 跑一个格点，把 8 路 comp 取回 comp_got[0..7]
  reg [31:0] comp_got [0:N_MIC-1];
  task run_target;
    input [IDX_W-1:0] tgt;
    begin
      @(negedge clk); target = tgt; start = 1'b1;
      @(negedge clk); start = 1'b0;
      i = 0;
      while ((done !== 1'b1) && (i < 200)) begin
        @(posedge clk); i = i + 1;
      end
      check(i < 200, "steer block must finish a grid inside 200 cycles");
      for (m = 0; m < N_MIC; m = m + 1) read_comp(m[3:0], comp_got[m]);
    end
  endtask

  initial begin
    $display("=== tb_steer: 定位格号 -> 8 路转向补偿 ===");
    $readmemh("build/steer_lut.hex", lut_img);
    $readmemh("build/steer_comp_ref.hex", comp_ref);

    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;

    // ── 装 LUT ──────────────────────────────────────────────────────────
    @(negedge clk); en = 1'b1;
    for (i = 0; i < N_LUT; i = i + 1) begin
      @(negedge clk);
      lut_we   = 1'b1;
      lut_addr = i[15:0];
      lut_data = lut_img[i];
    end
    @(negedge clk); lut_we = 1'b0;
    $display("  LUT 装载 %0d 条", N_LUT);

    // ── 段 1：逐格逐路 ──────────────────────────────────────────────────
    $display("[1] 256 格 x 8 路 comp，逐位对照参照");
    t0 = 0; dt = 0;
    for (g = 0; g < N_GRID; g = g + 1) begin
      cyc = i;
      run_target(g[IDX_W-1:0]);
      for (m = 0; m < N_MIC; m = m + 1) begin
        got = comp_got[m];
        exp = comp_ref[g*N_MIC + m];
        if (got !== exp) begin
          errors = errors + 1;
          if (errors <= 8)
            $display("  FAIL: grid %0d ch %0d  got=0x%08x exp=0x%08x (%0d vs %0d)",
                     g, m, got, exp, got, exp);
        end
      end
    end
    if (errors == 0) $display("    %0d 格 x %0d 路：0 错", N_GRID, N_MIC);

    // ── 段 4：一趟的拍数 ────────────────────────────────────────────────
    @(negedge clk); target = 10'd5; start = 1'b1;
    t0 = 0;
    @(negedge clk); start = 1'b0;
    while (done !== 1'b1 && t0 < 200) begin @(posedge clk); t0 = t0 + 1; end
    $display("[4] 一趟（8 查表 + 求 min + 8 相减）= %0d 拍", t0);

    // ── 段 3：target 真的接进地址了吗 ───────────────────────────────────
    $display("[3] 反证：不同格点必须给出不同 comp");
    run_target(10'd0);
    begin : cmp_chk
      integer same;
      reg [31:0] c0 [0:N_MIC-1];
      for (m = 0; m < N_MIC; m = m + 1) c0[m] = comp_got[m];
      run_target(N_GRID-1);
      same = 0;
      for (m = 0; m < N_MIC; m = m + 1) if (comp_got[m] === c0[m]) same = same + 1;
      check(same < N_MIC, "different targets must give different comp (target not wired?)");
      $display("    格 0 vs 格 %0d：8 路中 %0d 路相同（应 < 8）", N_GRID-1, same);
    end

    // ── 段 2：反证 —— LUT 真的被读了吗 ──────────────────────────────────
    // 把第 3 路的某个格点条目改掉，输出必须跟着变。
    // 不做这一段的话，「输出恰好对」可能来自任何巧合。
    $display("[2] 反证：改动 LUT 的一个字，输出必须跟着变");
    begin : lut_chk
      reg [31:0] before [0:N_MIC-1];
      reg [LUT_W-1:0] orig;
      integer changed;
      run_target(10'd16);
      for (m = 0; m < N_MIC; m = m + 1) before[m] = comp_got[m];

      // 行 3（m=3）、列 16 的条目加 1 个整数样点
      orig = lut_img[3*N_GRID + 16];
      @(negedge clk);
      lut_we = 1'b1; lut_addr = 3*N_GRID + 16;
      lut_data = lut_img[3*N_GRID + 16] + 14'd16;   // +1 样点 = idx+1
      @(negedge clk); lut_we = 1'b0;

      run_target(10'd16);
      changed = 0;
      for (m = 0; m < N_MIC; m = m + 1) if (comp_got[m] !== before[m]) changed = changed + 1;
      check(changed >= 1, "editing one LUT word must change at least one comp output");
      $display("    改 1 个字后：8 路中 %0d 路变了（应 >= 1）", changed);

      // 还原，别把后面搞脏
      @(negedge clk);
      lut_we = 1'b1; lut_addr = 3*N_GRID + 16; lut_data = orig;
      @(negedge clk); lut_we = 1'b0;
    end

    repeat (5) @(posedge clk);
    if (errors == 0) $display("PASS: tb_steer 全部通过");
    else             $display("FAIL: tb_steer %0d 处不符", errors);
    $finish;
  end

  initial begin
    #5_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
