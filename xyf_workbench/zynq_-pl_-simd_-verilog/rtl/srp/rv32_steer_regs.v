// 波束转向控制器的 SoC 寄存器外壳（包住 rtl/srp/rv32_steer.v）。
// 核走 MMIO 页 0xA000，PS 走 AXI 窗口 0x600 —— 与 SRP/XSPEC 同一条规矩：
// **同一组寄存器**的两个端口，不是两份硬件。
//
// ── 这个壳干的活：箭头的「策略」那一半 ─────────────────────────────────────
// rv32_steer 只算几何（格号 → 8 路 comp）。**什么时候把波束转过去**是策略：
//   §26.5.2 迟滞  EMPTY→CANDIDATE→ACTIVE→HOLD→RELEASE→EMPTY
//                 θ̂ 抖一下不能推着波束摆；短暂跳走进 HOLD，不立刻释放
//   §26.5.1 渐变  换向不许瞬切（会爆音），按步长分帧走完
// 两者都放在这里，是因为固件那侧放不下：DTCM 只剩 300 B `.text` / 16 B `.bss`。
//
// ── 寄存器表（7 位字地址，核 mmio_offset[8:2] / PS reg_off[8:2] 同一编号）──
//   0 CTRL    W/R [0] START(w1自清) [1] EN(电平,复位=1) [2] CLR_DONE [3] CLR_WERR
//   1 STATUS  R   [0] BUSY [1] DONE(粘滞) [2] EN [3] WERR(粘滞) [4] LOCKED
//                 [7:5] state [15:8] committed 格号
//   2 ADDR    W/R [16:15] SEL(0=LUT 1=COMP,2/3=保留) [14:0] IDX
//   3 WDATA   W   写 LUT@IDX 然后 IDX++；被拒时 IDX 不动
//   4 RDATA   R   读 COMP@IDX 然后 IDX++；**只对 SEL=COMP 有效**
//   5 TARGET  W/R 定位格号。**写它就触发一次更新**（与门铃/CTRL.START 等价）
//   6 CFG     W/R [7:0] RAMP_STEP(Q8, 0=立即) [15:8] HOLD_FRAMES [23:16] CAND_FRAMES
//   7 VERSION W/R 哑寄存器（就地自检）
//
// ⚠ CTRL 是**整体写**：写 0x1（只置 START）会把 EN 清成 0、启动被吞。
//   **要启动就写 0x3**（START|EN）。同 rv32_srp_regs / rv32_xsp_regs。
//
// ⚠ core_wr_i/core_rd_i/ps_wr_i/ps_rd_i 必须是**恰好一拍**的脉冲
//   （核侧由 rv32_soc 的 `& ~mmio_ack_q` 保证）。本壳的 ADDR/WDATA/RDATA 是自增窗口，
//   多走一步不报错、只是后面每个字都错位 —— 同 rv32_srp_regs.v:14-19。
module rv32_steer_regs #(
  parameter integer N_GRID = 256,
  parameter integer GRID_W = 16,
  parameter integer IDX_W  = 10,
  parameter integer FRAC_W = 4,
  parameter integer N_MIC  = 8,
  // 迟滞的"同一区域"判据：格号切比雪夫距离 ≤ CELL_TOL 算同一片
  parameter integer CELL_TOL = 2
) (
  input               clk_i,
  input               rst_n_i,
  input               core_start_i,
  input               core_wr_i,
  input               core_rd_i,
  input  [6:0]        core_addr_i,
  input  [31:0]       core_wdata_i,
  output [31:0]       core_rdata_o,
  input               ps_wr_i,
  input               ps_rd_i,
  input  [6:0]        ps_addr_i,
  input  [31:0]       ps_wdata_i,
  output [31:0]       ps_rdata_o,
  output              busy_o,
  output [N_MIC*32-1:0] comp_o,
  output locked_o,
  input link_start_i,input [IDX_W-1:0] link_target_i,
  output [IDX_W-1:0] committed_grid_o
);

  localparam integer LUT_W = IDX_W + FRAC_W;
  localparam integer N_LUT = N_MIC * N_GRID;

  localparam [6:0] A_CTRL = 7'h00, A_STATUS = 7'h01, A_ADDR = 7'h02, A_WDATA = 7'h03,
                   A_RDATA = 7'h04, A_TARGET = 7'h05, A_CFG = 7'h06, A_VER = 7'h07;
  localparam [1:0] S_LUT = 2'd0, S_COMP = 2'd1;

  localparam [2:0] H_EMPTY = 3'd0, H_CAND = 3'd1, H_ACTIVE = 3'd2,
                   H_HOLD  = 3'd3, H_REL = 3'd4;

  // ── 两个端口合成一条（核与 PS 不会同拍访问）────────────────────────────
  wire        wr    = core_wr_i | ps_wr_i;
  wire [6:0]  waddr = core_wr_i ? core_addr_i : ps_addr_i;
  wire [31:0] wdata = core_wr_i ? core_wdata_i : ps_wdata_i;
  wire        rd    = core_rd_i | ps_rd_i;
  wire [6:0]  raddr = core_rd_i ? core_addr_i : ps_addr_i;

  // ── 寄存器 ──────────────────────────────────────────────────────────────
  reg        en_q, done_q, werr_q, locked_q;
  reg [1:0]  sel_q;
  reg [14:0] idx_q;
  reg [15:0] dummy_q;
  reg        idx_chg_q;
  reg [IDX_W-1:0] target_q, committed_q;
  reg [7:0]  ramp_step_q, hold_fr_q, cand_fr_q;

  // ── 迟滞状态机 ──────────────────────────────────────────────────────────
  reg [2:0]       hstate_q;
  reg [IDX_W-1:0] cand_q;
  reg [7:0]       cand_cnt_q, away_cnt_q;

  localparam integer AXIS_W = $clog2(GRID_W);
  function [AXIS_W-1:0] ad4; input [AXIS_W-1:0] a; input [AXIS_W-1:0] b;
    begin ad4 = (a > b) ? (a - b) : (b - a); end
  endfunction

  // 1 = 超出"同一区域"
  function far; input [IDX_W-1:0] p; input [IDX_W-1:0] q;
    reg [AXIS_W-1:0] dx, dy;
    begin
      dx = ad4(p % GRID_W, q % GRID_W);
      dy = ad4(p / GRID_W, q / GRID_W);
      far = (dx > CELL_TOL) || (dy > CELL_TOL);
    end
  endfunction

  // ── 被包的几何核 ────────────────────────────────────────────────────────
  wire               g_busy, g_done;
  wire               lut_we;
  wire [3:0]         g_comp_idx;
  wire signed [31:0] g_comp_data;

  rv32_steer #(
    .N_GRID (N_GRID), .IDX_W (IDX_W), .FRAC_W (FRAC_W), .N_MIC (N_MIC)
  ) u_geo (
    .clk_i      (clk_i),
    .rst_n_i    (rst_n_i),
    .en_i       (en_q),
    .start_i    (geo_start),
    .target_i   (target_q),
    .busy_o     (g_busy),
    .done_o     (g_done),
    .lut_we_i   (lut_we),
    .lut_addr_i (idx_q),
    .lut_data_i (wdata[LUT_W-1:0]),
    .comp_idx_i (g_comp_idx),
    .comp_data_o(g_comp_data)
  );

  // ── 转向状态 ────────────────────────────────────────────────────────────
  reg signed [31:0] comp_out   [0:N_MIC-1];   // 渐变后的值 —— DAS 用的就是它
  assign locked_o = locked_q;
  assign committed_grid_o=committed_q;
  genvar mic;
  generate for (mic=0; mic<N_MIC; mic=mic+1) begin : g_comp_out
    assign comp_o[mic*32 +: 32] = comp_out[mic];
  end endgenerate
  reg signed [31:0] comp_tgt   [0:N_MIC-1];   // 本段渐变的目标
  reg signed [31:0] ramp_start [0:N_MIC-1];   // 本段渐变的起点
  reg signed [31:0] geo_q      [0:N_MIC-1];   // 本帧几何核的输出
  reg signed [31:0] comp_rd_q;
  reg signed [31:0] step_q;                   // 本段每帧步长（Q16 样点）

  // 几何核的 comp 读口下标 —— 由更新时序逐路推进（0..N_MIC-1）。
  // ⚠ 忘记驱动它是**静默失效**：悬空 → 读到 X，comp 全 0，而"全 0"看着像个合法值。
  assign g_comp_idx = m_q[3:0];

  // ⚠ 下标要**取模**，不能直接 `comp_out[idx_q[3:0]]`：idx_q 是 15 位而数组只有
  //   N_MIC 条，越界读在仿真里给 X（不是报错）。N_MIC 是 2 的幂 ⇒ 取模是免费的。
  always @(posedge clk_i) comp_rd_q <= comp_out[idx_q % N_MIC];

  // ── 访存窗口（自增、被拒不动 —— 同 rv32_srp_regs）──────────────────────
  wire do_wdata    = wr & (waddr == A_WDATA);
  wire wdata_lut   = do_wdata & (sel_q == S_LUT);
  wire reject_w    = wdata_lut & (seq_q != Q_IDLE);
  wire reject_wbad = do_wdata & (sel_q != S_LUT);
  assign lut_we    = wdata_lut & (seq_q == Q_IDLE);

  wire do_rdata      = rd & (raddr == A_RDATA);
  wire reject_rbad   = do_rdata & (sel_q != S_COMP);
  wire reject_rstale = do_rdata & idx_chg_q;

  wire [14:0] len_m1   = (sel_q == S_COMP) ? (N_MIC - 1) : (N_LUT - 1);
  wire [14:0] idx_next = (idx_q >= len_m1) ? 15'd0 : (idx_q + 15'd1);
  wire        wdata_ok = do_wdata & ~(reject_w | reject_wbad);
  wire        rdata_ok = do_rdata & ~(reject_rbad | reject_rstale);
  wire        idx_step = wdata_ok | rdata_ok;

  // ── 一次更新的时序：几何 → 取 comp → 迟滞 → (算步长) → 渐变 ─────────────
  localparam [2:0] Q_IDLE = 3'd0, Q_GEO = 3'd1, Q_GW = 3'd2, Q_RD = 3'd3,
                   Q_CAP  = 3'd4, Q_FSM = 3'd5, Q_RAMPW = 3'd6, Q_STEP = 3'd7;
  reg [2:0] seq_q;
  reg [3:0] m_q;
  reg       geo_start;

  wire trig = (link_start_i===1'b1) | (wr & (waddr == A_CTRL) & wdata[0])
            | (wr & (waddr == A_TARGET))
            | core_start_i;

  // 步长 = 最大那一路的落差 × RAMP_STEP / 256（一次乘法，不在逐路里）
  //
  // ⚠⚠ **落差取自 `geo_q − comp_out`，不是 `comp_tgt − ramp_start`**，而且中间
  //   压了一级寄存器（`gap_max_q`）。这不是为了省逻辑，是**关键路径**：
  //   原来这条链是「ramp_start_reg → 8 路相减/取绝对值 → 3 级 32 位比较树 →
  //   32×8 乘法 → 移位 → step_q」全挤在一拍里，实测 24.774 ns / 28 级逻辑 /
  //   16 个 CARRY4，**是全设计 WNS 的约束**（slack +0.011 ns）。
  //
  //   为什么可以换源：`comp_tgt`/`ramp_start` 是**在 Q_FSM 那拍**从
  //   `geo_q`/`comp_out` 装进去的（见 Q_FSM 分支里那一对非阻塞赋值），
  //   而 Q_STEP 在它的**下一拍**。所以「geo_q/comp_out 在 Q_FSM 拍的值」
  //   与「comp_tgt/ramp_start 在 Q_STEP 拍的值」**逐位相同** ⇒ 把比较树挪到
  //   寄存器之前，算式一个数都没变，只是它现在跑在 Q_FSM 那拍、结果在
  //   Q_STEP 那拍用。**下游状态机一拍没多、也没少**（Q_FSM→Q_STEP→Q_RAMPW）。
  //   `geo_q` 更早（Q_CAP 那八拍里）就落定了，`comp_out` 在 Q_RAMPW 才动 ——
  //   两者在 Q_FSM 拍都是稳定的。
  //
  //   改完两半各自还有余量：前一半 = 相减+abs+3 级比较（从 geo_q/comp_out 起），
  //   后一半 = 32×8 乘法+移位（从 gap_max_q 起）。
  function signed [31:0] ab32; input signed [31:0] v;
    begin ab32 = (v < 0) ? -v : v; end
  endfunction
  wire signed [31:0] gm [0:N_MIC-1];
  genvar gi;
  generate
    for (gi = 0; gi < N_MIC; gi = gi + 1) begin : g_gap
      assign gm[gi] = ab32(geo_q[gi] - comp_out[gi]);
    end
  endgenerate
  function signed [31:0] max32; input signed [31:0] a; input signed [31:0] b;
    begin max32 = (a > b) ? a : b; end
  endfunction
  wire signed [31:0] gap_tree [1:2*N_MIC-1];
  wire [N_MIC-1:0] changed;
  generate for (gi=0; gi<N_MIC; gi=gi+1) begin : g_tree_leaf
    assign gap_tree[N_MIC+gi] = gm[gi];
    assign changed[gi] = geo_q[gi] !== comp_tgt[gi];
  end
  for (gi=1; gi<N_MIC; gi=gi+1) begin : g_tree_node
    assign gap_tree[gi] = max32(gap_tree[2*gi], gap_tree[2*gi+1]);
  end endgenerate
  wire signed [31:0] gap_max = gap_tree[1];
  reg  signed [31:0] gap_max_q;          // Q_FSM 那拍算，Q_STEP 那拍用
  wire signed [63:0] step_mul = gap_max_q * $signed({1'b0, ramp_step_q});
  wire signed [31:0] step_w   = step_mul >>> 8;

  // ⚠ 带复位。它每拍都被覆盖，理论上不初始化也能自愈 —— 但本仓被 X 传播
  //   坑过一次（issues/084：一个没复位的 BRAM 读回 X，经一个三元式污染了 PC，
  //   整核零退休冻结）。这里 X 会经 step_q 进 comp_out，同样"不报错只算错"。
  always @(posedge clk_i or negedge rst_n_i)
    if (!rst_n_i) gap_max_q <= 32'sd0;
    else          gap_max_q <= gap_max;

  integer i;
  reg signed [31:0] gap_i;
  reg [2:0]         hnext;
  reg [IDX_W-1:0] committed_next;
  reg link_transaction,apply_geometry;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      en_q <= 1'b1; done_q <= 1'b0; werr_q <= 1'b0; locked_q <= 1'b0;
      sel_q <= S_LUT; idx_q <= 15'd0; idx_chg_q <= 1'b0; dummy_q <= 16'd0;
      target_q <= {IDX_W{1'b0}}; committed_q <= {IDX_W{1'b0}};
      ramp_step_q <= 8'd51; hold_fr_q <= 8'd5; cand_fr_q <= 8'd3;
      hstate_q <= H_EMPTY; cand_q <= {IDX_W{1'b0}};
      cand_cnt_q <= 8'd0; away_cnt_q <= 8'd0;
      seq_q <= Q_IDLE; m_q <= 4'd0; geo_start <= 1'b0;
      step_q <= 32'sd0;
      link_transaction<=0;apply_geometry<=0;
      for (i = 0; i < N_MIC; i = i + 1) begin
        comp_out[i] <= 32'sd0; comp_tgt[i] <= 32'sd0;
        ramp_start[i] <= 32'sd0; geo_q[i] <= 32'sd0;
      end
    end else begin
      geo_start <= 1'b0;
      idx_chg_q <= idx_step | (wr & (waddr == A_ADDR));

      // ── 寄存器写 ───────────────────────────────────────────────────────
      if (wr) begin
        if (waddr == A_CTRL) begin
          en_q <= wdata[1];
          if (wdata[2]) done_q <= 1'b0;
          if (wdata[3]) werr_q <= 1'b0;
        end
        if (waddr == A_ADDR) begin sel_q <= wdata[16:15]; idx_q <= wdata[14:0]; end
        if (waddr == A_TARGET) target_q <= wdata[IDX_W-1:0];
        if (waddr == A_CFG) begin
          ramp_step_q <= wdata[7:0];
          hold_fr_q   <= wdata[15:8];
          cand_fr_q   <= wdata[23:16];
        end
        if (waddr == A_VER) dummy_q <= wdata[15:0];
      end
      if(link_start_i===1'b1)target_q<=link_target_i;
      if (idx_step) idx_q <= idx_next;

      // ── 更新时序 ───────────────────────────────────────────────────────
      case (seq_q)
        Q_IDLE: begin
          if (trig && en_q) begin
            seq_q <= Q_GEO; geo_start <= 1'b1;
            link_transaction<=link_start_i===1'b1;
          end
        end

        Q_GEO: seq_q <= Q_GW;

        Q_GW: if (g_done) begin m_q <= 4'd0; seq_q <= Q_RD; end

        Q_RD:  seq_q <= Q_CAP;

        Q_CAP: begin
          geo_q[m_q] <= g_comp_data;
          if (m_q == N_MIC - 1) seq_q <= Q_FSM;
          else begin m_q <= m_q + 4'd1; seq_q <= Q_RD; end
        end

        // ── §26.5.2 迟滞 ─────────────────────────────────────────────────
        Q_FSM: begin
          hnext = hstate_q;
          committed_next=committed_q;
          case (hstate_q)
            H_EMPTY: begin
              cand_q <= target_q; cand_cnt_q <= 8'd1; hnext = H_CAND;
            end
            H_CAND: begin
              if (!far(target_q, cand_q)) begin
                cand_q <= target_q;
                if (cand_cnt_q + 8'd1 >= cand_fr_q) begin
                  committed_q <= target_q;committed_next=target_q; hnext = H_ACTIVE;
                end else cand_cnt_q <= cand_cnt_q + 8'd1;
              end else begin
                cand_q <= target_q; cand_cnt_q <= 8'd1;   // 换地方了，重新数
              end
            end
            H_ACTIVE: begin
              if (!far(target_q, committed_q))begin committed_q <= target_q;committed_next=target_q;end
              else begin away_cnt_q <= 8'd1; hnext = H_HOLD; end
            end
            H_HOLD: begin
              // 短暂跳走进 HOLD，**不立即释放**
              if (!far(target_q, committed_q)) begin
                away_cnt_q <= 8'd0; hnext = H_ACTIVE;
              end else if (away_cnt_q + 8'd1 >= hold_fr_q) begin
                hnext = H_REL;
              end else away_cnt_q <= away_cnt_q + 8'd1;
            end
            H_REL: begin
              committed_q <= {IDX_W{1'b0}};
              committed_next=0;
              cand_q <= target_q; cand_cnt_q <= 8'd1; hnext = H_CAND;
            end
            default: hnext = H_EMPTY;
          endcase
          hstate_q <= hnext;
          locked_q <= (hnext == H_ACTIVE) || (hnext == H_HOLD);

          // 只有"已锁定到本格"才换渐变目标；否则保持上一段不动
          apply_geometry<=committed_next==target_q;
          if ((link_transaction?committed_next:committed_q) == target_q) begin
            if (|changed) begin
              for (i = 0; i < N_MIC; i = i + 1) begin
                comp_tgt[i]   <= geo_q[i];
                ramp_start[i] <= comp_out[i];
              end
              seq_q <= Q_STEP;          // 新的一段：先算步长（此时值已落定）
            end else seq_q <= Q_RAMPW;
          end else seq_q <= Q_RAMPW;
        end

        // 步长在 comp_tgt / ramp_start **落定之后**才算 ——
        // 写在同一个 always 里紧跟赋值的话，读到的是上一拍的值（踩过）。
        Q_STEP: begin
          step_q <= (ramp_step_q == 8'd0) ? 32'sd0 : step_w;
          seq_q  <= Q_RAMPW;
        end

        // 本帧的渐变步进
        Q_RAMPW: begin
          for (i = 0; i < N_MIC; i = i + 1) begin
            // Linked transactions publish a complete geometric vector. The DAS
            // then owns sample-by-sample smoothing and its transition metadata.
            if(link_transaction)begin
              if(apply_geometry)comp_out[i]<=geo_q[i];
            end else begin
            gap_i = comp_tgt[i] - comp_out[i];
            if (step_q == 32'sd0)            comp_out[i] <= comp_tgt[i];
            else if (gap_i >  step_q)        comp_out[i] <= comp_out[i] + step_q;
            else if (gap_i < -step_q)        comp_out[i] <= comp_out[i] - step_q;
            else                             comp_out[i] <= comp_tgt[i];
            end
          end
          done_q <= 1'b1;
          seq_q  <= Q_IDLE;
        end

        default: seq_q <= Q_IDLE;
      endcase

      if (reject_w | reject_wbad | reject_rbad | reject_rstale |
          (trig & ~en_q) | (trig & (seq_q != Q_IDLE))) werr_q <= 1'b1;
    end
  end

  assign busy_o = (seq_q != Q_IDLE);

  // ── 读回 ────────────────────────────────────────────────────────────────
  reg [31:0] steer_rdata_c;
  always @(*) begin
    steer_rdata_c = 32'd0;
    case (raddr)
      A_CTRL:   steer_rdata_c = {28'd0, en_q};
      // [0]BUSY [1]DONE [2]EN [3]WERR [4]LOCKED [7:5]state [15:8]committed
      A_STATUS: steer_rdata_c = {{(24-IDX_W){1'b0}}, committed_q, hstate_q,
                                 locked_q, werr_q, en_q, done_q, busy_o};
      A_ADDR:   steer_rdata_c = {15'd0, sel_q, idx_q};
      A_TARGET: steer_rdata_c = {{(32-IDX_W){1'b0}}, target_q};
      A_CFG:    steer_rdata_c = {8'd0, cand_fr_q, hold_fr_q, ramp_step_q};
      A_VER:    steer_rdata_c = {16'd0, dummy_q};
      A_RDATA:  steer_rdata_c = (reject_rbad | reject_rstale) ? 32'd0 : comp_rd_q;
      default:  steer_rdata_c = 32'd0;
    endcase
  end

  assign core_rdata_o = steer_rdata_c;
  assign ps_rdata_o   = steer_rdata_c;

endmodule
