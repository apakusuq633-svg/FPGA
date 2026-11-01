// 互谱 + PHAT 归一化 —— README §20 / §21 的 PL 实现。
//
//     G   = X_i · conj(X_j) = (ac + bd) + j(bc − ad)
//     |G| ≈ max(|re|,|im|) + 0.414·min(|re|,|im|)      ← 免开方，模误差可达+8.24%
//     Ψ   = G / |G| · M(f)                              ← 免除法，LUT 倒数
//
// ── 三条 Stage 0 实测定下来的设计（照着做，别改回去）─────────────────────
//
// 1. **白化必须限带**（`docs/issues/027`）。带外 bin 里只有混响残余和数值噪声，
//    全带白化会把它们抬到与信号同权，在相关域造出**跨对一致的**伪结构 ——
//    28 对求和时不但不抵消，还叠加。实测：全带 PHAT 在 40 dB 混响下把定位误差
//    从 0.85 cm 劣化到 5.32 cm。
//    RTL 代价：`mask` 就是 bin 下标的比较，**不用乘法器**。
//
// 2. **倒数用 4-bit LUT 就够**（`fixed_model.py` 扫描）。4/6/8/10 bit 的定位误差
//    完全相同（1.00× float）。所以这里**省掉了除法器和开方器** —— README §21
//    把「除法/开方/归一化」列为 PL 里最难的一块，这条把它化解了。
//
// 3. 幅值用 max+0.414·min；欧氏模误差可达+8.24%，不是系数近似误差。
//    可以用移位加减拼出来，**不用乘法器**。
//
// ── 块浮点 ───────────────────────────────────────────────────────────────
// |G| 的动态范围有 30 多位，固定 Q 格式装不下。所以：
//   ① 先数 |G| 的前导零 → 指数 e
//   ② 取前导 1 之后的 LUT_BITS 位 → 尾数下标
//   ③ 尾数倒数查 LUT（Q1.15，落在 (0.5, 1]）
//   ④ Ψ = G · inv_mant >>> (15 + e + 1)
// 结果 |Ψ| ≈ 1，用 Q2.14 装（[−2, 2)，不会碰到 Q1.15 装不下 1.0 那个坑，
// 见 docs/issues/029）。
module rv32_xspec_phat #(
  parameter integer DW       = 16,      // 输入 bin 的实/虚部宽度
  parameter integer N_BINS   = 513,     // 1024 点 rfft 的 bin 数
  parameter integer LUT_BITS = 4,       // 倒数 LUT 的尾数位数
  // 工作频带（bin 下标）。默认对应 200–8000 Hz @ fs=39062.5 / NFFT=1024。
  // NFFT/fs = 1024/39062.5 = 26.2144 ms → 1 bin = 38.147 Hz
  parameter integer BIN_LO   = 5,       //  200 Hz
  parameter integer BIN_HI   = 209      // 8000 Hz
) (
  input                       clk_i,
  input                       rst_n_i,
  input                       en_i,
  // 输入流：每拍一个 bin，同时给 X_i 与 X_j
  input                       in_valid_i,
  input  [9:0]                bin_i,
  input  signed [DW-1:0]      ar_i, ai_i,     // X_i
  input  signed [DW-1:0]      br_i, bi_i,     // X_j
  // 输出流：PHAT 归一化后的互谱，与输入同拍数、延迟固定
  output                      out_valid_o,
  output [9:0]                bin_o,
  output signed [15:0]        pr_o, pi_o,     // Q2.14
  // 诊断：本帧里有多少个 bin 落在带内（用于验证 mask 真的在起作用）
  output [15:0]               inband_cnt_o
);

  // ── 级 1：复数乘 ──────────────────────────────────────────────────────
  // (a+jb)(c−jd) = (ac + bd) + j(bc − ad)
  reg                  v1_q;
  reg [9:0]            bin1_q;
  reg signed [2*DW:0]  re1_q, im1_q;      // 两个 DW 位乘积之和，多留 1 位

  wire signed [2*DW-1:0] ac = ar_i * br_i;
  wire signed [2*DW-1:0] bd = ai_i * bi_i;
  wire signed [2*DW-1:0] bc = ai_i * br_i;
  wire signed [2*DW-1:0] ad = ar_i * bi_i;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      v1_q <= 1'b0; bin1_q <= 10'b0; re1_q <= 0; im1_q <= 0;
    end else if (!en_i) begin
      v1_q <= 1'b0;
    end else begin
      v1_q   <= in_valid_i;
      bin1_q <= bin_i;
      re1_q  <= ac + bd;
      im1_q  <= bc - ad;
    end
  end

  // ── 级 2：幅值近似 + 前导零 ───────────────────────────────────────────
  // |G| ≈ max + 0.414214·min（"alpha max beta min"），移位加减拼出来，不用乘法器。
  //
  // ⚠ 0.414 的展开别写错：1/2 − 1/8 + 1/32 + 1/128 = 0.4140625 ✓
  //   写成 1/2 − 1/16 + 1/128 = 0.4453125 ✗ —— 偏大 7.5%，
  //   结果 |G| 偏大、倒数偏小、|Ψ| 系统性偏小 **−4.2%**（实测过，不是推的）。
  function [2*DW:0] mag_approx;
    input signed [2*DW:0] re, im;
    reg [2*DW:0] a, b, mn, mx;
    begin
      a  = (re[2*DW] ? -re : re);
      b  = (im[2*DW] ? -im : im);
      mx = (a > b) ? a : b;
      mn = (a > b) ? b : a;
      mag_approx = mx + (mn >> 1) - (mn >> 3) + (mn >> 5) + (mn >> 7);
    end
  endfunction

  function [5:0] lead_zeros;
    input [2*DW:0] v;
    integer k;
    begin
      lead_zeros = 6'd32;
      for (k = 2*DW; k >= 0; k = k - 1) begin
        if (v[k] && lead_zeros == 6'd32) lead_zeros = (2*DW + 1) - k - 1;
      end
    end
  endfunction

  reg                  v2_q;
  reg [9:0]            bin2_q;
  reg signed [2*DW:0]  re2_q, im2_q;
  reg [5:0]            e2_q;              // |G| 的前导零个数
  reg [LUT_BITS-1:0]   midx2_q;           // 尾数下标

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      v2_q <= 1'b0; bin2_q <= 10'b0; re2_q <= 0; im2_q <= 0;
      e2_q <= 6'd32; midx2_q <= 0;
    end else if (!en_i) begin
      v2_q <= 1'b0;
    end else begin
      begin : lvl2
        reg [2*DW:0] m, mn;
        reg [5:0]    lz;
        m  = mag_approx(re1_q, im1_q);
        lz = lead_zeros(m);
        // **先规格化再取固定切片**。直接写 m[(2*DW-1)-lz -: LUT_BITS] 在小信号时
        // 下标会变负（lz 最大到 2*DW），Verilog 下越界位选是未定义的，静默出错。
        // 左移 lz 把 MSB 顶到位置 2*DW，小数位就固定在 [2*DW-1 : 2*DW-LUT_BITS]。
        mn = m << lz;

        v2_q    <= v1_q;
        bin2_q  <= bin1_q;
        re2_q   <= re1_q;
        im2_q   <= im1_q;
        e2_q    <= lz;
        // 尾数下标取**前导 1 之下**的 LUT_BITS 位 —— 不含前导 1 本身。
        // 若含它，等于把尾数当成 [1+idx/2^LUT] 而不是 [1+idx/2^(LUT+1)]，
        // 整体偏一档，倒数就错。|G|=0 时走 0 分支，倒数乘出来仍是 0。
        midx2_q <= (lz >= 6'd32) ? {LUT_BITS{1'b0}}
                                 : mn[(2*DW-1) -: LUT_BITS];
      end
    end
  end

  // ── 级 3：尾数倒数 LUT + 归一化 ───────────────────────────────────────
  // 1/(1 + (i+0.5)/2^LUT_BITS)，Q1.15。取中点比取下端点误差小一半。
  // 整数写法，与原来的实数写法**逐值等价**（已核对 LUT_BITS=1..10 的全部条目，0 处不一致）。
  // 原来用 real + $rtoi：yosys 的前端解析不了 real，会让整条「no latches」检查在这里
  // 中止 —— 52 个文件只读到第 43 个，两个顶层（rv32_soc / rv32_ps_top）从没被查过。
  // 见 docs/issues/040。合成 RTL 里也不该出现 real。
  // 全是正数，整数除法的向零截断与 $rtoi 行为一致。
  // 注意 32768*2^(LUT_BITS+1) 在 LUT_BITS>=15 时溢出 32 位；实用值是 4。
  //
  // ⚠⚠ **这里原来是一个函数里的除法，而它综合成了一个真除法器。**
  //   分子 `32768<<(LUT_BITS+1)` 是常量，但分母 `32 + 2*idx + 1` 随 idx 变
  //   ⇒ Vivado **不认**它是常量除法，直接给了一个 32 位除法器。
  //   实测代价：`midx2_q → pr3_q` 一条路径 **38 个 CARRY4 / 64 级逻辑 /
  //   46.284 ns**（周期只有 25 ns），是本设计（4×256 档位接进 SoC 之后）
  //   **唯一的时序失败族**，80 个失效端点全在它上面。
  //   这块以前从没被综合进网表，所以这个数十年一直没被量到。
  //
  //   修法：同一个公式，改成**在展开期用整型常量算出 2^LUT_BITS 个值**，
  //   运行期只查表（16 条 ⇒ 一个 LUT 级）。数值与原来**逐位相同**
  //   （同一个整数除法、全为正数 ⇒ 截断方向一致）。
  //   ⚠ 改 LUT_BITS 不用动这里 —— 表是按公式现算的，不是手抄的常数。
  function [15:0] inv_lut_calc;
    input integer i;                     // **常量**入参，只为展开期求值
    begin
      inv_lut_calc = (32768 * (1 << (LUT_BITS + 1))) /
                     ((1 << (LUT_BITS + 1)) + 2 * i + 1);
    end
  endfunction

  localparam integer INV_N = (1 << LUT_BITS);
  reg [15:0] inv_tab [0:INV_N-1];
  integer it;
  initial begin
    for (it = 0; it < INV_N; it = it + 1) inv_tab[it] = inv_lut_calc(it);
  end

  reg                  v3_q;
  reg [9:0]            bin3_q;
  reg signed [15:0]    pr3_q, pi3_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      v3_q <= 1'b0; bin3_q <= 10'b0; pr3_q <= 0; pi3_q <= 0;
    end else if (!en_i) begin
      v3_q <= 1'b0;
    end else begin
      begin : lvl3
        reg [15:0]             inv;
        reg signed [2*DW+15:0] pr, pi;
        reg [5:0]              sh;
        reg                    inband;
        inv = inv_tab[midx2_q];          // 查表，不再是除法（见上面的说明）
        // 归一化移位量的推导（错了会静默回绕，别凭感觉改）：
        //   |G| = 2^p · mant,  p = 2*DW − lz,  mant ∈ [1,2)
        //   inv_lut ≈ 2^15 / mant            （Q1.15）
        //   G · inv_lut = 2^(p+15)·(G/|G|)   → 单位幅度，但还差 2^(p+15)
        //   要推到 Q2.14（1.0 = 2^14），所以再右移 (p+15) − 14 = p + 1
        //   sh = p + 1 = (2*DW + 1) − lz
        sh  = (2*DW + 1) - e2_q;
        pr  = re2_q * $signed({1'b0, inv});
        pi  = im2_q * $signed({1'b0, inv});
        inband = (bin2_q >= BIN_LO) && (bin2_q <= BIN_HI);

        v3_q   <= v2_q;
        bin3_q <= bin2_q;
        // 带外直接置零 —— 这就是 docs/issues/027 的修法。
        // p ≤ 2*DW 且 lz ≤ 2*DW ⇒ sh ∈ [1, 2*DW+1]，永远落在 48 位以内，不用钳位。
        pr3_q  <= inband ? (pr >>> sh) : 16'sd0;
        pi3_q  <= inband ? (pi >>> sh) : 16'sd0;
      end
    end
  end

  assign out_valid_o = v3_q;
  assign bin_o       = bin3_q;
  assign pr_o        = pr3_q;
  assign pi_o        = pi3_q;

  // ── 带内 bin 计数（诊断）──────────────────────────────────────────────
  reg [15:0] inband_cnt_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      inband_cnt_q <= 16'b0;
    end else if (!en_i) begin
      inband_cnt_q <= 16'b0;
    end else if (v3_q && (bin3_q == 10'd0)) begin
      inband_cnt_q <= 16'b0;             // 新帧开始
    end else if (v3_q && (bin3_q >= BIN_LO) && (bin3_q <= BIN_HI)) begin
      inband_cnt_q <= inband_cnt_q + 1'b1;
    end
  end

  assign inband_cnt_o = inband_cnt_q;

endmodule
