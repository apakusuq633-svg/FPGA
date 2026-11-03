// 互谱 + PHAT 归一化的 SoC 寄存器外壳（包住 rtl/gcc/rv32_xspec_phat.v）。
// 核走 MMIO 页 0x9000，PS 走 AXI 窗口 0x500（见 rv32_ps_regs.v）。
//
// ── 为什么外壳比 SRP 那个重 ────────────────────────────────────────────────
// rv32_xspec_phat 是**纯流式**的：每拍进一个 bin（X_i 与 X_j 的实虚部），
// 3 拍后出归一化后的互谱 Ψ。它**没有** start/busy/done，**也没有**任何存储。
// 要用起来，外壳必须自带：
//   ① 三条 513 条 × 32 位的缓冲：XI / XJ（输入，{im,re} 打包）与 Ψ（输出）
//   ② 一个把缓冲推成流的 FSM（每拍一个 bin，推完 513 个再收 3 拍尾巴）
//   ③ 状态与自检：DONE 粘滞、WERR、**inband_cnt**（满帧必须 = 205）
//
// inband_cnt 是白送的自检量：块里本来就有个带内 bin 计数器
// （rv32_xspec_phat.v:204-219，遇到 bin 0 清零），限带是 BIN_LO=5..BIN_HI=209，
// 所以**跑完一整帧它必须正好是 205**。不是 205 就说明限带掩码没在起作用 ——
// 而那条掩码正是 docs/issues/027 用一整份档案换来的结论（全带白化把混响残余
// 抬到同权，40 dB 混响下定位从 0.85 劣化到 5.32 cm）。
//
// ── 寄存器表（7 位字地址）────────────────────────────────────────────────────
//   0 CTRL    W/R  [0] START(w1 自清) [1] EN(电平,复位=1) [2] CLR_DONE [3] CLR_WERR
//   1 STATUS  R    [0] BUSY [1] DONE(粘滞) [2] EN [3] WERR(粘滞) [31:16] inband_cnt
//   2 ADDR    W/R  [11:10] SEL(0=XI 1=XJ 2=Ψ,3=保留) [9:0] IDX(0..512)
//                   **SEL 紧挨在 IDX 上方**，中间不留空洞 —— 见 rv32_srp_regs.v
//                   同一处的注释（放错位会让 SEL 在 32 位截断后静默变 0）。
//   3 WDATA   W    写 {im[31:16],re[15:0]} 到 XI/XJ@IDX 然后 IDX++；拒时 IDX 不动
//   4 RDATA   R    读 Ψ@IDX 后 IDX++；**只对 SEL=Ψ 有效**（XI/XJ 没有读口）
//   5 VERSION W/R  哑寄存器（写回读）
//
// ⚠ **CTRL 是整体写**：写 0x1（只置 START）会把 EN 清成 0，启动被吞掉。
//   **要启动就写 0x3**（START|EN）—— 同 SRP 那个外壳、同 ps_main.c 的 CTRL 注释。
//
// ⚠ 两条访问时序约定与 rv32_srp_regs.v 完全一致（脉冲式访问、读口同步读），
//   那边的头注释写得更细，改这里之前先读那一份。
module rv32_xsp_regs #(
  parameter integer DW     = 16,     // 输入 bin 的实/虚部宽度
  parameter integer NB     = 513,    // 一条流多少个 bin（1024 点 rfft）
  parameter integer BIN_LO = 5,      // 带内下界（200 Hz）
  parameter integer BIN_HI = 209     // 带内上界（8000 Hz）
) (
  input               clk_i,
  input               rst_n_i,
  input               core_start_i,   // 门铃：核的 custom-1 指令，已在核里寄存成一拍
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
  output              busy_o
);

  localparam integer AW = 10;                        // NB = 513 ≤ 1024

  localparam [6:0] A_CTRL = 7'h00, A_STATUS = 7'h01, A_ADDR = 7'h02,
                   A_WDATA = 7'h03, A_RDATA = 7'h04, A_VER = 7'h05;

  localparam [1:0] S_XI = 2'd0, S_XJ = 2'd1, S_PSI = 2'd2;

  localparam [1:0] ST_IDLE = 2'd0, ST_PRE = 2'd1, ST_RUN = 2'd2, ST_DRAIN = 2'd3;

  localparam [AW-1:0] LAST = NB - 1;

  wire        wr    = core_wr_i | ps_wr_i;
  wire [6:0]  waddr = core_wr_i ? core_addr_i : ps_addr_i;
  wire [31:0] wdata = core_wr_i ? core_wdata_i : ps_wdata_i;
  wire        rd    = core_rd_i | ps_rd_i;
  wire [6:0]  raddr = core_rd_i ? core_addr_i : ps_addr_i;

  // ── 缓冲：XI/XJ 一写（host）一读（FSM），Ψ 反过来。都是"一写一读" ⇒ BRAM ────
  // ⚠ 读必须**寄存地址**（同步读），不能写成组合读 `mem[idx]`：
  //   组合读会推断成分布式 RAM —— 513×32 的读多路 ≈ 四千个 LUT，白烧。
  reg [31:0] xi_mem  [0:NB-1];
  reg [31:0] xj_mem  [0:NB-1];
  reg [31:0] psi_mem [0:NB-1];

  // ── 寄存器 ────────────────────────────────────────────────────────────────
  reg        en_q, done_q, werr_q, busy_q;
  reg [1:0]  sel_q;
  reg [AW-1:0] idx_q;
  reg        idx_chg_q;      // 上一拍改过 idx ⇒ 同步读口还是旧地址那一格
  reg [15:0] dummy_q;

  reg [1:0]  st_q;
  reg [AW-1:0] cnt_q;        // 这一拍**正在推**的 bin 号
  reg [AW-1:0] addr_q;       // 这一拍送给存储的预取地址（= 下一拍的 cnt）
  reg [31:0] xi_r_q, xj_r_q; // 同步读出来的数据（对应 addr_q 的上一个值）
  reg [31:0] psi_rd_q;
  reg [2:0]  drain_q;

  // ── 访问合法性 ────────────────────────────────────────────────────────────
  // 忙时写缓冲会把 FSM 正在推的那一帧改掉（推的就是同一块存储），必须挡住。
  wire do_wdata     = wr & (waddr == A_WDATA);
  wire wdata_sel_ok = (sel_q == S_XI) | (sel_q == S_XJ);
  wire reject_w     = do_wdata & (busy_q | ~wdata_sel_ok);
  wire wdata_ok     = do_wdata & ~reject_w;

  wire do_rdata = rd & (raddr == A_RDATA);
  wire reject_r = do_rdata & ((sel_q != S_PSI) | idx_chg_q);
  wire rdata_ok = do_rdata & ~reject_r;

  wire ctrl_start = wr & (waddr == A_CTRL) & wdata[0];
  wire do_start   = ctrl_start | core_start_i;
  wire start_ok   = do_start & ~busy_q;

  wire access_bad = reject_w | reject_r | (do_start & busy_q);

  // 自增：被拒的访问不动 idx（可原地重试）。XI/XJ/Ψ 都是 NB 条。
  wire [AW-1:0] idx_next = (idx_q >= LAST) ? {AW{1'b0}} : (idx_q + 1'b1);
  wire          idx_step = wdata_ok | rdata_ok;

  // ── 存储的读写口：**都必须独立成块、且不带异步复位** ──────────────────────
  // ⚠⚠ BRAM **没有复位端**。把写口放进带 `negedge rst_n_i` 的 always 里，推断
  //   直接失败，三条缓冲退回触发器 + 多路选择：3 × 513 × 32 ≈ 49k 位
  //   ⇒ 实测 `place_design` 报「需要 12439 slices，只有 10934 可用」。
  //   这就是 docs/issues/060 那半句 ——「写口减到 1」只是前半句，后半句是
  //   **「写所在的块不能带异步复位」**。同一个坑在新代码里又踩了一次。
  //   读口同理：必须"地址寄存 + 数据寄存"（同步读），写成组合读再打拍
  //   也会退回分布式 RAM。
  always @(posedge clk_i) begin
    xi_r_q   <= xi_mem[addr_q];
    xj_r_q   <= xj_mem[addr_q];
    psi_rd_q <= psi_mem[idx_q];
  end

  // 写口：host 写 XI/XJ，收数逻辑写 Ψ。与读口分开是"一写一读"的简单双口。
  always @(posedge clk_i) begin
    if (wdata_ok) begin
      if (sel_q == S_XI) xi_mem[idx_q] <= wdata;
      else               xj_mem[idx_q] <= wdata;
    end
    if (out_valid_o) psi_mem[bin_o[AW-1:0]] <= {pi_o, pr_o};
  end

  integer i;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      en_q <= 1'b1; done_q <= 1'b0; werr_q <= 1'b0; busy_q <= 1'b0;
      sel_q <= S_XI; idx_q <= {AW{1'b0}}; idx_chg_q <= 1'b0;
      dummy_q <= 16'd0;
      st_q <= ST_IDLE; cnt_q <= {AW{1'b0}}; addr_q <= {AW{1'b0}}; drain_q <= 3'd0;
    end else begin
      idx_chg_q <= idx_step | (wr & (waddr == A_ADDR));

      if (wr) begin
        if (waddr == A_CTRL) begin
          en_q <= wdata[1];
          if (wdata[2]) done_q <= 1'b0;
          if (wdata[3]) werr_q <= 1'b0;
        end
        if (waddr == A_ADDR) begin
          sel_q <= wdata[AW+1:AW];    // AW=10 ⇒ [11:10]
          idx_q <= wdata[AW-1:0];
        end
        if (waddr == A_VER) dummy_q <= wdata[15:0];
      end

      if (idx_step) idx_q <= idx_next;

      // ⚠ 三条缓冲的读写**不在这里** —— 它们必须待在各自不带异步复位的
      //   always 块里才推断得成 BRAM，见上面那两段的注释。

      // ── 推流 FSM ──────────────────────────────────────────────────────────
      // 时序（改之前先对着这段推一遍，错一拍就是"漏推 bin 0"）：
      //   IDLE  : addr_q<=0, cnt_q<=0
      //   PRE   : 这拍末 xi_r_q = mem[0]（addr_q=0）；同时 addr_q<=1
      //   RUN(k): 推 bin=k（in_valid 组合 = st==RUN），此时 xi_r_q = mem[k]
      //           这拍末 cnt_q<=k+1、addr_q<=k+2 ⇒ 下一拍 xi_r_q = mem[k+1]
      case (st_q)
        ST_IDLE: begin
          busy_q <= 1'b0;
          if (start_ok) begin
            busy_q <= 1'b1;
            cnt_q  <= {AW{1'b0}};
            addr_q <= {AW{1'b0}};
            drain_q <= 3'd0;
            st_q   <= ST_PRE;
          end
        end
        ST_PRE: begin
          addr_q <= {{(AW-1){1'b0}}, 1'b1};
          st_q   <= ST_RUN;
        end
        ST_RUN: begin
          if (cnt_q == LAST) st_q <= ST_DRAIN;
          else begin
            cnt_q  <= cnt_q + 1'b1;
            addr_q <= (cnt_q + 2 > LAST) ? LAST : (cnt_q + 2);
          end
        end
        ST_DRAIN: begin
          drain_q <= drain_q + 3'd1;
          if (drain_q == 3'd4) begin
            drain_q <= 3'd0;
            busy_q  <= 1'b0;
            done_q  <= 1'b1;
            st_q    <= ST_IDLE;
          end
        end
        default: st_q <= ST_IDLE;
      endcase

      if (access_bad) werr_q <= 1'b1;
    end
  end

  // ── 被包的块 ──────────────────────────────────────────────────────────────
  wire        out_valid_o;
  wire [9:0]  bin_o;
  wire signed [15:0] pr_o, pi_o;
  wire [15:0] inband_cnt_o;

  // in_valid 必须是**组合**的：写成寄存器会在启动时丢一拍，bin 0 永远推不出去
  // （推的是 in_valid_q 拉高的那一拍，而那时 cnt_q 已经 +1）。
  wire in_valid = (st_q == ST_RUN) & en_q;

  rv32_xspec_phat #(
    .DW      (DW),
    .N_BINS  (NB),
    .BIN_LO  (BIN_LO),
    .BIN_HI  (BIN_HI)
  ) u_xsp (
    .clk_i        (clk_i),
    .rst_n_i      (rst_n_i),
    .en_i         (en_q),
    .in_valid_i   (in_valid),
    .bin_i        ({{(10-AW){1'b0}}, cnt_q}),
    .ar_i         ($signed(xi_r_q[15:0])),
    .ai_i         ($signed(xi_r_q[31:16])),
    .br_i         ($signed(xj_r_q[15:0])),
    .bi_i         ($signed(xj_r_q[31:16])),
    .out_valid_o  (out_valid_o),
    .bin_o        (bin_o),
    .pr_o         (pr_o),
    .pi_o         (pi_o),
    .inband_cnt_o (inband_cnt_o)
  );

  assign busy_o = busy_q;

  // ── 读回（摊成 always + case，不调 task —— 原因见 rv32_srp_regs.v）────
  reg [31:0] xsp_rdata_c;

  always @(*) begin
    xsp_rdata_c = 32'd0;
    case (raddr)
      A_CTRL:   xsp_rdata_c = {31'd0, en_q};
      A_STATUS: xsp_rdata_c = {inband_cnt_o, 12'd0, werr_q, en_q, done_q, busy_q};
      A_ADDR:   xsp_rdata_c = {20'd0, sel_q, idx_q};   // 与写入口 [11:10]/[9:0] 同布局
      A_RDATA:  xsp_rdata_c = reject_r ? 32'd0 : psi_rd_q;
      A_VER:    xsp_rdata_c = {16'd0, dummy_q};
      default:  xsp_rdata_c = 32'd0;
    endcase
  end

  assign core_rdata_o = xsp_rdata_c;
  assign ps_rdata_o   = xsp_rdata_c;

endmodule
