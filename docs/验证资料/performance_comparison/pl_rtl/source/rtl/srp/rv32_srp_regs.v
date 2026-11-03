// SRP 扫描加速器的 SoC 寄存器外壳（包住 rtl/srp/rv32_srp_scan.v）。
// 核走 MMIO 页 0x8000，PS 走 AXI 窗口 0x400（见 rv32_ps_regs.v）——
// 与音频/ANC/PDM 同一条规矩：**同一组寄存器**的两个端口，不是两份硬件。
//
// ── 为什么要外壳 ──────────────────────────────────────────────────────────
// rv32_srp_scan 给的是裸接口：LUT 与 R 各一个 15 位写口、P 一个 10 位读口、
// 加 start/busy/done。要能被核与 PS 当外设用，缺三样，这里补上：
//   ① 索引窗口 ADDR/WDATA/RDATA + **地址自增**（否则每写一个字要两笔访问）
//   ② 启动的**恰好一次**：门铃指令（core_start_i）与 CTRL.START 两个来源
//   ③ 状态与自检：DONE 粘滞、WERR、RUN_CYCLES（上板要拿它当证据）
//
// ── ⚠ 两条访问时序约定 —— 违反会静默读错，务必读完 ─────────────────────────
//
// 1. **core_wr_i / core_rd_i / ps_wr_i / ps_rd_i 都必须是"恰好一拍"的脉冲。**
//    核侧由 rv32_soc 用 `& ~mmio_ack_q` 保证：MMIO 自 2026-10-04 起是隔拍应答
//    （rv32_soc.v 的 mmio_ack_q），电平会持续两拍。不限定的话每笔自增走两步，
//    而"多走一格"不报错，只是后面每一个字都写错位置。
//    （音频 RX 的读即弹就是被这个坑咬过，见 rv32_soc.v:349-357。）
//    PS 侧本来就是单拍脉冲（rv32_ps_regs.v 的 reg_wr_i/reg_rd_i）。
//
// 2. **P 的读口是同步读**：`p_usr_q <= p_mem[p_addr_i]`（rv32_srp_scan.v:123），
//    比地址晚一拍。本外壳把 idx_q 常连到 p_addr_i，所以 RDATA 在**改过 idx 的
//    下一拍**读到的是上一格的旧值。正常访问不会撞上：核 MMIO 每笔 2 拍、
//    AXI 每笔也是 2 拍，天然隔得开。但万一接上能背靠背每拍读的总线，
//    它就会**静默读错一格** —— 本项目最恨的就是"不报错只算错"，
//    所以这里用 idx_chg_q 把它变成**可见的 WERR + 返回 0**。
//
// ── 寄存器表（7 位字地址，核侧 mmio_offset[8:2] / PS 侧 reg_off[8:2] 同一编号）──
//   0 CTRL      W/R  [0] START(w1 自清) [1] EN(电平,复位=1) [2] CLR_DONE [3] CLR_WERR
//   1 STATUS    R    [0] BUSY [1] DONE(粘滞) [2] EN [3] WERR(粘滞)
//   2 ADDR      W/R  [16:15] SEL(0=LUT 1=R 2=P,3=保留) [ADDR_W-1:0] IDX
//                     **SEL 紧挨在 IDX 上方、中间不留空洞** —— 写成 [17:16] 会
//                     让"拼一个值写进去"的调用方（含 TB）把 SEL 放错位，
//                     而截断到 32 位之后 SEL 静默变 0（所有写落进 LUT）。
//   3 WDATA     W    写 SEL@IDX 然后 IDX++；**被拒时 IDX 不动**（可原地重试）
//   4 RDATA     R    读 SEL@IDX 然后 IDX++；**只对 SEL=P 有效**
//   5 CYCLES    R    扫描块的自由计数器（拍）
//   6 RUN_CYCLES R   上次 start→done 的差 —— 上板量加速器占用就靠它
//   7 VERSION   W/R  哑寄存器（就地自检：写回读）
//
// ⚠ **CTRL 是整体写**（同 ps_main.c 里 CTRL/HALT 那条注释）：写 0x1（只置 START）
//   会把 EN 清成 0，块随即回 IDLE、启动被吞掉。**要启动就写 0x3**（START|EN）。
module rv32_srp_regs #(
  parameter integer N_PAIR = 4,
  parameter integer N_GRID = 256,
  // R 的行长，默认 = N_GRID。**它与 N_GRID 是两件事**：LUT 每格点一条
  // （N_PAIR*N_GRID 条），R 是整条相关序列（N_PAIR*R_LEN 条）。
  // 取值必须 ≥ LUT 里 idx 的最大值，否则会读到下一对的行里去（静默算错）。
  // 详见 rv32_srp_scan.v 的参数表那段。
  parameter integer R_LEN  = N_GRID,
  parameter integer IDX_W  = 10,
  parameter integer FRAC_W = 4,
  parameter integer ADDR_W = 15,
  parameter integer GRID_IDX_W = $clog2(N_GRID),
  parameter integer DW     = 16,
  parameter integer FAST_SCAN = 0, // 4 selects four parallel pair banks.
  parameter integer LOCAL_TRANSFER = 0
) (
  input               clk_i,
  input               rst_n_i,
  // 门铃：核的 custom-1 指令已经把它寄存成恰好一拍（见 rv32_core.v）
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
  input transfer_enable_i,input transfer_r_we_i,
  input [ADDR_W-1:0] transfer_r_addr_i,input [DW-1:0] transfer_r_data_i,
  input [GRID_IDX_W-1:0] transfer_p_addr_i,
  output signed [31:0] transfer_p_data_o,output transfer_done_o
);

  localparam integer LUT_W = IDX_W + FRAC_W;
  // 9-microphone DECIM=16 profile: R_LEN=64, IDX_W=6, FRAC_W=4.
  // LUT writes remain ordinary 32-bit MMIO words; the low ten bits carry Q4
  // ring delays. R and LUT addresses keep their existing ADDR_W-bit ports.
  // Legacy R_LEN=32 / IDX_W=5 profiles and register offsets are unchanged.
  // 三条数组各自的长度（自增回绕用），**LUT 与 R 不是同一个数**。
  localparam integer NELEM = N_PAIR * N_GRID;    // LUT 条数
  localparam integer RELEM = N_PAIR * R_LEN;     // R 条数
  // 15 位够用：全尺寸 28×1024 = 28672、4×1024 = 4096，都 < 32768。
  localparam [ADDR_W-1:0] LEN_LUT = NELEM - 1;
  localparam [ADDR_W-1:0] LEN_R   = RELEM - 1;
  localparam [ADDR_W-1:0] LEN_P   = N_GRID - 1;

  localparam [6:0] A_CTRL = 7'h00, A_STATUS = 7'h01, A_ADDR = 7'h02, A_WDATA = 7'h03,
                   A_RDATA = 7'h04, A_CYCLES = 7'h05, A_RUNCYC = 7'h06, A_VER = 7'h07;

  localparam [1:0] S_LUT = 2'd0, S_R = 2'd1, S_P = 2'd2;

  // ── 两个写/读口合成一条（核与 PS 不会同拍访问）──────────────────────────
  wire        wr    = core_wr_i | ps_wr_i;
  wire [6:0]  waddr = core_wr_i ? core_addr_i : ps_addr_i;
  wire [31:0] wdata = core_wr_i ? core_wdata_i : ps_wdata_i;
  wire        rd    = core_rd_i | ps_rd_i;
  wire [6:0]  raddr = core_rd_i ? core_addr_i : ps_addr_i;

  // ── 寄存器 ────────────────────────────────────────────────────────────────
  reg        en_q, done_q, werr_q;
  reg [1:0]  sel_q;
  reg [ADDR_W-1:0] idx_q;
  reg [31:0] cyc0_q, run_cyc_q, ver_q;
  reg        idx_chg_q;      // 上一拍改过 idx ⇒ p_usr_q 还是旧地址那一格
  reg [15:0] dummy_q;

  // ── 被包的块 ──────────────────────────────────────────────────────────────
  wire        scan_busy, scan_done;
  wire [31:0] scan_cyc;
  wire        lut_we, r_we, scan_start;

  // 启动来源：门铃与 CTRL.START 都是恰好一拍，或起来仍是一拍。
  // 忙的时候忽略（下面的 WERR 会把它报出来），因为块的 start 只在 S_IDLE 被采。
  wire ctrl_start = wr & (waddr == A_CTRL) & wdata[0];
  wire do_start   = ctrl_start | core_start_i;
  assign scan_start = do_start & ~scan_busy;

  // 写 WDATA 的目标由 SEL 选；P 是扫描自己写的，**拒写**（start 会清零它，
  // 外部灌进去也没有意义）。SEL=3 是保留值，必须显式挡掉 ——
  // 不挡的话它落进 default，看着像写成功，实际什么都没写。
  wire do_wdata  = wr & (waddr == A_WDATA);
  wire wdata_lut = do_wdata & (sel_q == S_LUT);
  wire wdata_r   = do_wdata & (sel_q == S_R);
  // 忙时写 LUT/R 会改掉扫描正在读的数据：rv32_srp_scan.v:108-117 是"写口兼读口"，
  // 扫描期读地址固定在 pair*N_GRID+grid，改写它等于中途换掉输入。
  wire transfer_enabled=LOCAL_TRANSFER?transfer_enable_i:1'b0;
  wire reject_w  = (wdata_lut | wdata_r) & (scan_busy|transfer_enabled);
  wire reject_wbad = do_wdata & ((sel_q == S_P) | (sel_q == 2'd3));
  assign lut_we = wdata_lut & ~scan_busy & ~transfer_enabled;
  assign r_we   = wdata_r & ~scan_busy & ~transfer_enabled;

  wire do_rdata = rd & (raddr == A_RDATA);
  // RDATA 只支持 P：LUT 与 R 在块里**没有读口**（只有写口 + 扫描的内部读），
  // 想读回来得再存一份影子，不值当。读它们返回 0 并置 WERR，别让它静默给 0。
  wire reject_rbad = do_rdata & ((sel_q != S_P)|transfer_enabled);
  wire reject_rstale = do_rdata & idx_chg_q;

  wire access_bad = reject_w | reject_wbad | reject_rbad | reject_rstale |
                    (do_start & scan_busy);

  wire wdata_ok = do_wdata & ~(reject_w | reject_wbad);
  wire rdata_ok = do_rdata & ~(reject_rbad | reject_rstale);

  // 自增：按当前 SEL 的数组长度回绕。被拒的访问**不动 idx**（可原地重试，
  // 与 rv32_ps_regs.v:188 的系数窗口同规矩）。
  wire [ADDR_W-1:0] len_m1   = (sel_q == S_P) ? LEN_P :
                         (sel_q == S_R) ? LEN_R : LEN_LUT;
  wire [ADDR_W-1:0] idx_next = (idx_q >= len_m1) ? 0 : (idx_q + 1);
  wire        idx_step = wdata_ok | rdata_ok;

  wire signed [31:0] p_data;
  assign transfer_p_data_o=p_data;
  assign transfer_done_o=scan_done;

  rv32_srp_scan #(
    .N_PAIR (N_PAIR),
    .N_GRID (N_GRID),
    .R_LEN  (R_LEN),
    .IDX_W  (IDX_W),
    .FRAC_W (FRAC_W),
    .ADDR_W (ADDR_W), .GRID_IDX_W(GRID_IDX_W),
    .DW     (DW),.FAST_SCAN(FAST_SCAN)
  ) u_scan (
    .clk_i      (clk_i),
    .rst_n_i    (rst_n_i),
    .en_i       (en_q),
    .start_i    (scan_start),
    .busy_o     (scan_busy),
    .done_o     (scan_done),
    .lut_we_i   (lut_we),
    .lut_addr_i (idx_q),
    .lut_data_i (wdata[LUT_W-1:0]),
    .r_we_i     (transfer_enabled?transfer_r_we_i&&!scan_busy:r_we),
    .r_addr_i   (transfer_enabled?transfer_r_addr_i:idx_q),
    .r_data_i   (transfer_enabled?$signed(transfer_r_data_i):$signed(wdata[DW-1:0])),
    .p_addr_i   (transfer_enabled?transfer_p_addr_i:idx_q[GRID_IDX_W-1:0]),
    .p_data_o   (p_data),
    .cycle_cnt_o(scan_cyc)
  );

  integer i;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      en_q <= 1'b1; done_q <= 1'b0; werr_q <= 1'b0;
      sel_q <= S_LUT; idx_q <= 0; idx_chg_q <= 1'b0;
      cyc0_q <= 32'd0; run_cyc_q <= 32'd0; ver_q <= ADDR_W == 17 ? 32'h0012_0000 : 32'h0001_0000;
      dummy_q <= 16'd0;
    end else begin
      idx_chg_q <= idx_step | (wr & (waddr == A_ADDR));

      if (wr) begin
        if (waddr == A_CTRL) begin
          en_q <= wdata[1];
          if (wdata[2]) done_q <= 1'b0;
          if (wdata[3]) werr_q <= 1'b0;
        end
        if (waddr == A_ADDR) begin
          sel_q <= wdata[ADDR_W+1:ADDR_W];
          idx_q <= wdata[ADDR_W-1:0];      // 与上面 [16:15] 连成一片，无空洞
        end
        if (waddr == A_VER) dummy_q <= wdata[15:0];
      end

      if (idx_step) idx_q <= idx_next;

      // 计时起点打在**被接受**的启动上：被忙挡掉的那次不改 cyc0_q，
      // 否则 RUN_CYCLES 会把上一笔的起点算进去，读出来是个偏大的假数。
      if (scan_start) cyc0_q <= scan_cyc;
      if (scan_done) begin
        done_q    <= 1'b1;
        run_cyc_q <= scan_cyc - cyc0_q;
      end
      if (access_bad) werr_q <= 1'b1;
    end
  end

  assign busy_o = scan_busy;

  // ── 读回 ──────────────────────────────────────────────────────────────────
  // ⚠ 不能写成 `always @(*) 调 task`：task 的 output 实参 + 变址数组读会让
  //   iverilog 的敏感表自激（零时间死循环、TB 一行输出都没有）。
  //   摊成普通 always + case，别调 task。
  reg [31:0] srp_rdata_c;

  always @(*) begin
    srp_rdata_c = 32'd0;
    case (raddr)
      A_CTRL:   srp_rdata_c = {28'd0, en_q};
      // [0] BUSY [1] DONE [2] EN [3] WERR
      A_STATUS: srp_rdata_c = {28'd0, werr_q, en_q, done_q, scan_busy};
      A_ADDR:   srp_rdata_c = {{(30-ADDR_W){1'b0}}, sel_q, idx_q};
      A_CYCLES: srp_rdata_c = scan_cyc;
      A_RUNCYC: srp_rdata_c = run_cyc_q;
      A_VER:    srp_rdata_c = {ADDR_W == 17 ? 16'h0012 : 16'h0000, dummy_q};
      // P 的值：被拒时给 0（同时 WERR 已置位），别让调用方以为读到了真值
      A_RDATA:  srp_rdata_c = (reject_rbad | reject_rstale) ? 32'd0 : p_data;
      default:  srp_rdata_c = 32'd0;
    endcase
  end

  assign core_rdata_o = srp_rdata_c;
  assign ps_rdata_o   = srp_rdata_c;

endmodule
