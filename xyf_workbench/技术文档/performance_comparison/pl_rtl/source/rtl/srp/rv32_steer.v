// 波束转向几何核 —— 「定位的那一格」→「8 路对齐补偿 comp_m」（Q16 样点）。
//
//     comp_m = (τmax − τ_m) · 65536        τ_m = 格点到第 m 个麦的传播延迟
//
// ── 不用重算几何：comp 从 7 对延迟推出来 ────────────────────────────────────
// fw_srp.c 的约定是 τ_ij = τ_i − τ_j。于是（推导见 gen_steer_vectors.py 头部）
//
//     comp_m = τ_{0m} − min_j τ_{0j}          m = 0..7，τ_{00} ≡ 0
//
// 所以本模块**没有 isqrt、没有除法**，只有 8 次查表 + 一次求最小 + 8 次相减。
// 恒等式已在真几何上逐点验过（256 格，最大差 0 Q16 LSB）。
//
// ── 存的是**有符号** τ，不是 SRP 那种绕回的无符号 idx ───────────────────────
// rv32_srp_scan 的 LUT 存 `idx = floor(τ) mod NFFT`（无符号）——它只拿 idx 当
// 相关序列下标，绕回无所谓。转向要拿 τ 做**减法**，绕回就毁了。
// 所以这里存 `idx = τ_q16 >> 16`（算术右移，可负，IDX_W 位补码）+ 4 位小数。
//
// ⚠ 还原式把 τ 截到 1/16 样点（向下取整）。参照必须走**同一条还原**
//   （gen_steer_vectors.py 是拿还原后的值算 comp 的），否则比的是截断误差。
//
// ── 存储：读口/写口各自独立成块，且都不带异步复位 ───────────────────────────
// ⚠ 写口放进带 `negedge rst_n_i` 的块 ⇒ BRAM 推断失败 ⇒ 退回触发器+多路选择
//   ⇒ place 装不下。这条踩过两次（issues/060 / 080），别再犯。
module rv32_steer #(
  parameter integer N_GRID = 256,
  parameter integer IDX_W  = 10,
  parameter integer FRAC_W = 4,
  parameter integer N_MIC  = 8
) (
  input                       clk_i,
  input                       rst_n_i,
  input                       en_i,
  input                       start_i,
  input  [IDX_W-1:0]          target_i,      // 定位报出的格号
  output reg                  busy_o,
  output reg                  done_o,
  // LUT 装载：地址 = m*N_GRID + g，数据 = {idx[IDX_W-1:0], frac[FRAC_W-1:0]}
  // m = 0..N_MIC-1，第 0 行恒为 0（τ_00 ≡ 0）
  input                       lut_we_i,
  // ⚠ 地址宽度必须与外壳给的**逐位对齐**：外壳那边 idx_q 是 15 位，
  //   若这里写成 [15:0] 而接 `idx_q[15:0]`，那位不存在的位就是 X ⇒
  //   写入落进带 X 的地址、读回全 X（"合法值"里最坏的一种：看着有数）。
  input  [14:0]               lut_addr_i,
  input  [IDX_W+FRAC_W-1:0]   lut_data_i,
  // comp 读口（同步读，晚一拍），供外壳搬运
  input  [3:0]                comp_idx_i,
  output signed [31:0]        comp_data_o
);

  localparam integer LUT_W = IDX_W + FRAC_W;
  localparam integer N_LUT = N_MIC * N_GRID;         // 行号即 m（0..N_MIC-1）

  reg [LUT_W-1:0]   lut_mem [0:N_LUT-1];
  reg [LUT_W-1:0]   lut_r;
  reg signed [31:0] comp_mem [0:N_MIC-1];
  reg signed [31:0] comp_rd_q;

  assign comp_data_o = comp_rd_q;

  // ── 三条存储访问各自独立成块（BRAM 推断的前提，见头部）────────────────────
  // 读口：地址在几何流水里推进
  reg [14:0] lut_addr_rd;
  always @(posedge clk_i) lut_r <= lut_mem[lut_addr_rd];

  // 写口：装载期用，**不带异步复位**
  always @(posedge clk_i) begin
    if (lut_we_i) lut_mem[lut_addr_i] <= lut_data_i;
  end

  // comp 读口。⚠ 下标取模：comp_idx_i 是 4 位而 comp_mem 只有 N_MIC 条，
  //   越界读给 X 而不报错（N_MIC 是 2 的幂 ⇒ 取模免费）。
  always @(posedge clk_i) comp_rd_q <= comp_mem[comp_idx_i % N_MIC];

  // ── 几何流水：每个 start 走一趟 ─────────────────────────────────────────
  reg [2:0]          st_q;
  localparam integer MIC_W = $clog2(N_MIC);
  reg [MIC_W-1:0] m_q;
  reg [IDX_W-1:0]    base_q;                    // 本趟的 target（不变）
  reg signed [31:0]  tau_q  [0:N_MIC-1];
  reg signed [31:0]  tmin_q;

  localparam [2:0] S_IDLE = 3'd0, S_WAIT = 3'd1, S_CAP = 3'd2, S_SUB = 3'd3,
                   S_FIN  = 3'd4;

  // 还原：(signed(idx) << 16) + (frac << 12)。
  // ⚠⚠ **必须先符号扩展到 32 位再移位**。写成 `$signed(idx_s) <<< 16` 会错：
  //   移位表达式的宽度由左操作数决定（10 位），16 位移全部被移出 ⇒ idx 项恒 0，
  //   只剩 frac 项。症状是 comp 里含着一个"看着像下标的东西"
  //   （实测 ch1 读出 0x03FEE000 = 打包值 0x3FEE << 12），极难一眼认出。
  wire signed [IDX_W-1:0] idx_s = lut_r[LUT_W-1:FRAC_W];
  wire signed [31:0]      idx_w = {{(32-IDX_W){idx_s[IDX_W-1]}}, idx_s};
  wire        [31:0]      frac_w = {{(32-FRAC_W){1'b0}}, lut_r[FRAC_W-1:0]};
  wire signed [31:0]      tau_w = (idx_w <<< 16) + $signed(frac_w <<< 12);

  // ⚠ 必须拿**刚读出的 tau_w** 比，不能拿 tau_q[m_q] ——
  //   后者正被这一拍覆盖，比的是上一个格/上一路的值（第一版就是这么错的）。
  wire signed [31:0] tmin_n = (tau_w < tmin_q) ? tau_w : tmin_q;

  // 下一路的 LUT 地址：m 行、base 列
  wire [14:0] addr_next = (m_q + 1'b1) * N_GRID + {{(15-IDX_W){1'b0}}, base_q};

  integer i;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      st_q <= S_IDLE; busy_o <= 1'b0; done_o <= 1'b0;
      m_q <= 0; lut_addr_rd <= 15'd0; base_q <= {IDX_W{1'b0}};
      tmin_q <= 32'sd0;
      for (i = 0; i < N_MIC; i = i + 1) begin
        tau_q[i]    <= 32'sd0;
        comp_mem[i] <= 32'sd0;
      end
    end else if (!en_i) begin
      st_q <= S_IDLE; busy_o <= 1'b0; done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;

      case (st_q)
        S_IDLE: begin
          busy_o <= 1'b0;
          if (start_i) begin
            busy_o      <= 1'b1;
            base_q      <= target_i;
            m_q         <= 0;
            lut_addr_rd <= {{(15-IDX_W){1'b0}}, target_i};   // 第 0 行 = τ_00 = 0
            tmin_q      <= 32'sd0;                           // τ_00 是首个候选
            st_q        <= S_WAIT;
          end
        end

        // lut_r 要到这拍末才有效 ⇒ 下一拍再捕获
        S_WAIT: st_q <= S_CAP;

        S_CAP: begin
          tau_q[m_q] <= tau_w;
          tmin_q     <= tmin_n;
          if (m_q == N_MIC - 1) begin
            st_q <= S_SUB;
          end else begin
            m_q         <= m_q + 1'b1;
            lut_addr_rd <= addr_next;
            st_q        <= S_WAIT;
          end
        end

        // tau_q / tmin_q 在这拍都已落定 ⇒ 8 路并行相减
        S_SUB: begin
          for (i = 0; i < N_MIC; i = i + 1) comp_mem[i] <= tau_q[i] - tmin_q;
          st_q <= S_FIN;
        end

        S_FIN: begin
          busy_o <= 1'b0;
          done_o <= 1'b1;
          st_q   <= S_IDLE;
        end

        default: st_q <= S_IDLE;
      endcase
    end
  end

endmodule
