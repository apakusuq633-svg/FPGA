// 波束转向控制器寄存器壳 rv32_steer_regs 的验收（箭头在 RTL 里的落点）。
//
// 五段：
//   1. **逐格逐路**：写完 TARGET 后从 COMP 窗口读回 8 路，对着参照逐位比。
//   2. **迟滞（§26.5.2）**：单帧跳变不得推动 committed；持续移位必须释放并跟过去。
//   3. **渐变（§26.5.1）**：RAMP_STEP=0 一帧到位；RAMP_STEP=51 必须**分帧**走完、
//      且中间值既不等于起点也不等于终点（否则"渐变"是假的）。
//   4. **反证**：SEL=LUT 读 RDATA、SEL=COMP 写 WDATA —— 都必须报 WERR，
//      不能"看着成功、其实写到了别处"。
//   5. VERSION 就地回读自检。
//
// ⚠ 采样时刻（issues/078）：RDATA 走的是同步读，设完 ADDR 要等一拍再采。
// ⚠ 脉冲 vs 电平（issues/079）：core_wr_i / core_rd_i 必须是**恰好一拍**。
`timescale 1ns/1ps

module tb_steer_regs;

  localparam integer N_GRID = 256;
  localparam integer GRID_W = 16;
  localparam integer IDX_W  = 10;
  localparam integer FRAC_W = 4;
  localparam integer N_MIC  = 8;
  localparam integer N_LUT  = N_MIC * N_GRID;

  localparam [6:0] A_CTRL = 7'h00, A_STATUS = 7'h01, A_ADDR = 7'h02,
                   A_WDATA = 7'h03, A_RDATA = 7'h04, A_TARGET = 7'h05,
                   A_CFG = 7'h06, A_VER = 7'h07;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg         rst_n = 1'b0;
  reg         c_wr = 1'b0, c_rd = 1'b0, c_start = 1'b0;
  reg  [6:0]  c_addr = 7'd0;
  reg  [31:0] c_wdata = 32'd0;
  wire [31:0] c_rdata;
  wire        busy;

  rv32_steer_regs #(
    .N_GRID (N_GRID), .GRID_W (GRID_W), .IDX_W (IDX_W),
    .FRAC_W (FRAC_W), .N_MIC (N_MIC), .CELL_TOL (2)
  ) u_dut (
    .clk_i (clk), .rst_n_i (rst_n),
    .core_start_i (c_start),
    .core_wr_i (c_wr), .core_rd_i (c_rd), .core_addr_i (c_addr),
    .core_wdata_i (c_wdata), .core_rdata_o (c_rdata),
    .ps_wr_i (1'b0), .ps_rd_i (1'b0), .ps_addr_i (7'd0), .ps_wdata_i (32'd0),
    .ps_rdata_o (), .busy_o (busy)
  );

  reg [13:0] lut_img [0:N_LUT-1];
  reg [31:0] comp_ref [0:N_GRID*N_MIC-1];

  integer errors = 0;
  integer i, g, m, k;
  reg [31:0] rv;

  task check;
    input            cond;
    input [8*96-1:0] msg;
    begin
      if (!cond) begin errors = errors + 1; $display("  FAIL: %0s", msg); end
    end
  endtask

  // 访问时序照抄 tb_srp_regs（那边是逐条读 256 格 P 且通过的）：
  //   ① 每次访问**恰好一拍**；② 两笔之间**多隔一拍**（末尾那次 @(negedge clk)）；
  //   ③ 组合值在**请求拍**采（#1），不是等下一个 posedge。
  // ⚠ 少了 ② 的话，前一笔被接受的读会把 idx_chg_q 置起，下一笔必被判 stale，
  //   于是"每次读都返回 0"—— 而 0 看着像个合法值（这一版就是这么栽的）。
  task wr_reg;
    input [6:0]  a;
    input [31:0] d;
    begin
      @(negedge clk); c_addr = a; c_wdata = d; c_wr = 1'b1;
      #1;
      @(negedge clk); c_wr = 1'b0;
      @(negedge clk);
    end
  endtask

  task rd_reg;
    input  [6:0]  a;
    output [31:0] d;
    begin
      @(negedge clk); c_addr = a; c_rd = 1'b1;
      #1; d = c_rdata;
      @(negedge clk); c_rd = 1'b0;
      @(negedge clk);
    end
  endtask

  // 触发一帧更新并等它跑完（几何 19 拍 + 8 路回读 + 迟滞/渐变）
  // ⚠ 等待计数必须用**任务自己的**变量。用外面那个共用的 k 的话，任务返回时
  //   会把调用方 for 循环的 k 冲成"等了多少拍"（~45），于是
  //   `for (k=0;k<14;k=k+1) frame(...)` **只跑一轮** —— 而现象是
  //   "帧数喂够了却还锁不上"，看着像 FSM 坏了。
  task frame;
    input [IDX_W-1:0] tgt;
    integer w;
    begin
      wr_reg(A_TARGET, {22'd0, tgt});
      w = 0;
      while ((busy === 1'b1 || w < 3) && w < 300) begin @(posedge clk); w = w + 1; end
      repeat (2) @(posedge clk);
    end
  endtask

  // 读回 8 路 comp
  reg [31:0] cg [0:N_MIC-1];
  task read_all_comp;
    begin
      wr_reg(A_ADDR, {15'd0, 2'd1, 15'd0});          // SEL=COMP, IDX=0
      for (m = 0; m < N_MIC; m = m + 1) rd_reg(A_RDATA, cg[m]);
    end
  endtask

  reg [31:0] st;
  task read_status; begin rd_reg(A_STATUS, st); end endtask

  initial begin
    $display("=== tb_steer_regs: 定位格号 -> 转向补偿（带迟滞与渐变）===");
    $readmemh("build/steer_lut.hex", lut_img);
    $readmemh("build/steer_comp_ref.hex", comp_ref);

    rst_n = 1'b0;
    repeat (6) @(posedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    // ── 装 LUT（SEL=LUT，2048 条自增写）──────────────────────────────────
    wr_reg(A_ADDR, {15'd0, 2'd0, 15'd0});
    for (i = 0; i < N_LUT; i = i + 1) wr_reg(A_WDATA, {18'd0, lut_img[i]});
    $display("  LUT 装载 %0d 条", N_LUT);

    // VERSION 就地自检
    wr_reg(A_VER, 32'h0000_A5A5);
    rd_reg(A_VER, rv);
    check(rv[15:0] === 16'hA5A5, "VERSION must read back what was written");
    $display("[5] VERSION 回读 0x%04x", rv[15:0]);

    // ── 段 1：逐格逐路 ───────────────────────────────────────────────────
    // RAMP_STEP=0 ⇒ 一帧到位，comp 直接等于几何核的输出
    // CFG 布局：[23:16]=CAND [15:8]=HOLD [7:0]=RAMP
    wr_reg(A_CFG, 32'h0001_0500);            // CAND=1, HOLD=5, RAMP=0
    // 逐格穷举几何的正确性由 tb_steer 负责（那边直接驱动几何核）。
    // 这里验的是**壳**：窗口搬运 + 迟滞是否把正确的 comp 送到读口。
    // ⚠ 每个格点要喂够帧数：目标离上次锁定处"远"时，FSM 必须走
    //   ACTIVE→HOLD(5 帧)→RELEASE→CANDIDATE→ACTIVE，约 9 帧才切过去。
    //   只喂 2 帧的话读到的是**上一格**的 comp（合法值，所以不报错）。
    $display("[1] 抽代表格点，从窗口读回 8 路对照参照（RAMP_STEP=0）");
    for (g = 0; g < N_GRID; g = g + 17) begin
      for (k = 0; k < 14; k = k + 1) frame(g[IDX_W-1:0]);
      read_all_comp;
      for (m = 0; m < N_MIC; m = m + 1) begin
        if (cg[m] !== comp_ref[g*N_MIC + m]) begin
          errors = errors + 1;
          if (errors <= 8)
            $display("  FAIL: grid %0d ch %0d got=0x%08x exp=0x%08x",
                     g, m, cg[m], comp_ref[g*N_MIC + m]);
        end
      end
    end
    if (errors == 0) $display("    16 个代表格 x %0d 路：0 错", N_MIC);


    // ── 段 2：迟滞 ───────────────────────────────────────────────────────
    $display("[2] 迟滞（§26.5.2）");
    // 先在格 100 稳定锁住
    for (k = 0; k < 14; k = k + 1) frame(10'd100);
    read_status;
    check(st[15:8] === 8'd100, "committed must be grid 100 after a stable run");
    check(st[7:5] === 3'd2, "state must be ACTIVE after a stable run");
    $display("    稳定后 committed=%0d state=%0d", st[15:8], st[7:5]);

    // 单帧跳变到远处（格 0，切比雪夫距离 > CELL_TOL）
    frame(10'd0);
    read_status;
    check(st[15:8] === 8'd100, "a single-frame excursion must NOT move committed");
    check(st[7:5] === 3'd3, "a single-frame excursion must enter HOLD, not RELEASE");
    $display("    单帧跳变后 committed=%0d state=%0d（应为 100 / HOLD=3）",
             st[15:8], st[7:5]);

    // 回到原处 —— 应回 ACTIVE
    frame(10'd100);
    read_status;
    check(st[7:5] === 3'd2, "returning must go back to ACTIVE");
    $display("    回到原处后 state=%0d（应为 ACTIVE=2）", st[7:5]);

    // 持续移位 —— 必须 RELEASE 并重新锁定到新位置
    for (k = 0; k < 12; k = k + 1) frame(10'd0);
    read_status;
    check(st[15:8] === 8'd0, "a sustained move must re-lock onto the new grid");
    check(st[7:5] === 3'd2, "must end ACTIVE on the new grid");
    $display("    持续移位后 committed=%0d state=%0d（应为 0 / ACTIVE）",
             st[15:8], st[7:5]);

    // ── 段 4：反证 —— 非法访问必须报 WERR，不能静默落到别处 ──────────────
    $display("[4] 反证：非法访问必须报 WERR");
    wr_reg(A_CTRL, 32'h0000_0008);           // CLR_WERR
    wr_reg(A_ADDR, {15'd0, 2'd0, 15'd0});    // SEL=LUT
    rd_reg(A_RDATA, rv);                     // LUT 没有读口 ⇒ 必须拒
    read_status;
    check(st[3] === 1'b1, "reading RDATA with SEL=LUT must raise WERR");
    $display("    SEL=LUT 读 RDATA -> WERR=%0d（应 1）", st[3]);

    wr_reg(A_CTRL, 32'h0000_0008);           // CLR_WERR
    wr_reg(A_ADDR, {15'd0, 2'd1, 15'd0});    // SEL=COMP
    wr_reg(A_WDATA, 32'hDEAD_BEEF);          // COMP 是只读的 ⇒ 必须拒
    read_status;
    check(st[3] === 1'b1, "writing WDATA with SEL=COMP must raise WERR");
    $display("    SEL=COMP 写 WDATA -> WERR=%0d（应 1）", st[3]);

    // ── 段 3：渐变 ───────────────────────────────────────────────────────
    $display("[3] 渐变（§26.5.1）");
    begin : ramp_chk
      reg [31:0] geo0 [0:N_MIC-1];
      reg [31:0] c_imm [0:N_MIC-1];
      integer part, idx;

      // 先取"一帧到位"的基准：RAMP_STEP=0
      wr_reg(A_CFG, 32'h0001_0500);          // CAND=1 HOLD=5 RAMP=0
      frame(10'd0); frame(10'd0); frame(10'd0); frame(10'd0);
      read_all_comp;
      for (m = 0; m < N_MIC; m = m + 1) c_imm[m] = cg[m];

      // 复位整个壳，改成 RAMP_STEP=51（20%），从头看这一段
      rst_n = 1'b0; repeat (6) @(posedge clk); rst_n = 1'b1;
      repeat (2) @(posedge clk);
      wr_reg(A_ADDR, {15'd0, 2'd0, 15'd0});
      for (i = 0; i < N_LUT; i = i + 1) wr_reg(A_WDATA, {18'd0, lut_img[i]});
      wr_reg(A_CFG, 32'h0001_0533);          // CAND=1 HOLD=5 RAMP=51

      // 喂到锁定，然后逐帧看 comp 是不是"走在半路上"
      part = 0;
      for (k = 0; k < 12; k = k + 1) begin
        frame(10'd0);
        read_all_comp;
        for (m = 0; m < N_MIC; m = m + 1) begin
          if (cg[m] !== 32'd0 && cg[m] !== c_imm[m]) part = part + 1;
        end
      end
      check(part > 0, "RAMP_STEP=51 must produce intermediate comp values (no instant jump)");
      $display("    渐变途中出现「既非起点也非终点」的样点：%0d 个", part);

      // 走够帧数后必须**精确**落到目标（差 1 LSB 都不行）
      for (k = 0; k < 8; k = k + 1) frame(10'd0);
      read_all_comp;
      check(cg[0] === c_imm[0] && cg[3] === c_imm[3] && cg[7] === c_imm[7],
            "after enough frames the ramp must land exactly on the target");
      $display("    走满后 comp[0]=%0d（目标 %0d）", cg[0], c_imm[0]);
    end

    repeat (5) @(posedge clk);
    if (errors == 0) $display("PASS: tb_steer_regs 全部通过");
    else             $display("FAIL: tb_steer_regs %0d 处不符", errors);
    $finish;
  end

  initial begin
    #20_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
