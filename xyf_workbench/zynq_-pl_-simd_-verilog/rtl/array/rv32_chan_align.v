// 通道对齐 + DC 去除 + 增益校准 —— README §12 / §13 / §14。
//
// 每通道独立，按顺序做三件事：
//
//   1. 通道对齐   把 audio_vec 排成固定的**物理序**（几何序由 PS 侧的
//                 mic_geometry 表映射，禁止写死在这里，见 §7.2 / §11.2）
//   2. DC 去除    一阶高通  y[n] = x[n] − x[n−1] + α·y[n−1]
//   3. 增益校准   y'[n] = g_i · y[n]，g_i 是 Q2.14（**不是 Q1.15**，见下面端口处
//                 的警告与 docs/issues/029），由校准实验定（§14）
//
// ── α 取 1 − 2^−k：零乘法器 ──────────────────────────────────────────────
// 教科书写法是 α = exp(−2π f_c/fs)，那要一个乘法器 ×8 通道。取
//
//     α = 1 − 2^−k
//
// 则 α·y[n−1] = y[n−1] − (y[n−1] >>> k)，**一次减法加一次移位**就够。
// 代价是拐点频率只能取离散值：
//
//     f_c = −ln(1 − 2^−k) · fs / (2π)
//
//   k=9  → α=0.998047 → f_c ≈ 12.2 Hz   ← 默认
//   k=8  → α=0.996094 → f_c ≈ 24.3 Hz
//   k=10 → α=0.999023 → f_c ≈  6.1 Hz
//
// 默认 k=9：要留的最低阶次是 1X（几十 Hz），12 Hz 拐点不影响它，而 DC 和
// 极低频漂移本来就不含故障信息。**实测响应见 tb_chan_align.v 第 2 段。**
//
// ── 位宽 ─────────────────────────────────────────────────────────────────
// 输入 24 位（数字麦原生）。内部 32 位：
//   x[n]−x[n−1] 最大 2^25，y 的反馈与它同量级，32 位留 6 位余量，**不会溢出**。
// 输出默认 24 位并饱和 —— 它决定下游 FFT 的输入宽度（README §38）。
//
// ── ⚠ 已知的直流死区（实测，非推理）───────────────────────────────────────
// `>>>` 是**向 −∞ 取整**（算术移位），不是向零。后果：
//
//   正残差： y ∈ [0, 2^DC_K) 时 y >>> DC_K == 0，反馈项消失 → **卡住不动**
//   负残差： y ∈ (−2^DC_K, 0) 时 y >>> DC_K == −1 → 每拍 +1，**能爬到 0**
//
// 所以恒定输入下残差最终停在 **[0, 2^DC_K)**，DC_K=9 时是 [0, 512)。
// 相对 2^23 满幅是 **−84 dBFS**，而且下游 PHAT 本来就把频带限到 200 Hz 以上
// （README §21，见 docs/issues/027），DC 分量根本进不了相关器。
//
// **所以这里不修**：修它要加「y≠0 时反馈至少 ±1」的比较+选择逻辑 ×8 通道，
// 换来的是一条本来就会被滤掉的分量。实测数字见 tb_chan_align.v 第 2 段。
// （如果哪天 DC 通路真的重要了，改法是给反馈加向零取整：q = y>>>K，
//   qz = (q<<K != y && y<0) ? q+1 : q。）
module rv32_chan_align #(
  parameter integer N_CH   = 8,
  parameter integer IN_W   = 24,
  parameter integer OUT_W  = 24,
  parameter integer DC_K   = 9          // α = 1 − 2^−DC_K
) (
  input                       clk_i,
  input                       rst_n_i,
  input                       en_i,
  input  [N_CH*IN_W-1:0]      audio_vec_i,
  input                       valid_i,
  // 每通道增益，**Q2.14**（1.0 = 16384，范围 [−2, 2)）。
  //
  // ⚠ 不能用 Q1.15：Q1.15 的 1.0 是 32768，而 16 位有符号装不下，
  //   会静默变成 −32768 —— 单位增益直接反相。这个坑是实测抓出来的，见 docs/issues/029。
  // ⚠ 复位值是 0，也就是**增益为 0 = 静音**。PS 必须在使能前写入 16384。
  input  [N_CH*16-1:0]        gain_q_i,
  output [N_CH*OUT_W-1:0]     audio_vec_o,
  output                      valid_o
);

  localparam integer ACC_W = 32;

  wire signed [IN_W-1:0] x_in [0:N_CH-1];
  genvar gi;
  generate
    for (gi = 0; gi < N_CH; gi = gi + 1) begin : g_unpack
      assign x_in[gi] = audio_vec_i[gi*IN_W +: IN_W];
    end
  endgenerate

  reg  signed [IN_W-1:0]  x_prev_q [0:N_CH-1];
  reg  signed [ACC_W-1:0] y_acc_q  [0:N_CH-1];
  reg                     valid_d;

  integer i;

  // 增益支路：Q2.14 乘 → 右移 14 位 → 饱和到 OUT_W
  wire signed [ACC_W+15:0] gprod [0:N_CH-1];
  generate
    for (gi = 0; gi < N_CH; gi = gi + 1) begin : g_gain
      wire signed [15:0] g = gain_q_i[gi*16 +: 16];
      assign gprod[gi] = y_acc_q[gi] * g;
      wire signed [ACC_W+15:0] sh = gprod[gi] >>> 14;
      wire signed [ACC_W+15:0] hi =  ((1 <<< (OUT_W-1)) - 1);
      wire signed [ACC_W+15:0] lo = -((1 <<< (OUT_W-1)));
      assign audio_vec_o[gi*OUT_W +: OUT_W] =
          (sh > hi) ? hi[OUT_W-1:0] :
          (sh < lo) ? lo[OUT_W-1:0] : sh[OUT_W-1:0];
    end
  endgenerate

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      valid_d <= 1'b0;
      for (i = 0; i < N_CH; i = i + 1) begin
        x_prev_q[i] <= {IN_W{1'b0}};
        y_acc_q[i]  <= {ACC_W{1'b0}};
      end
    end else if (!en_i) begin
      valid_d <= 1'b0;
      for (i = 0; i < N_CH; i = i + 1) begin
        x_prev_q[i] <= {IN_W{1'b0}};
        y_acc_q[i]  <= {ACC_W{1'b0}};
      end
    end else begin
      // valid_o 必须与 audio_vec_o 同拍：
      //   本拍末 y_acc_q 更新 → 下一拍组合出 audio_vec_o
      //   本拍末 valid_d 置位 → 下一拍也为 1
      // 两者一起翻，所以直接把 valid_i 打一拍即可。
      valid_d <= valid_i;
      if (valid_i) begin
        for (i = 0; i < N_CH; i = i + 1) begin
          // y[n] = x[n] − x[n−1] + y[n−1] − (y[n−1] >>> DC_K)
          // 乘法结果宽度按 LRM 是 max(L,R)，所以这里**不写乘法**：
          // 反馈项完全由减法和算术右移构成，8 通道零 DSP。
          y_acc_q[i]  <= x_in[i] - x_prev_q[i]
                         + y_acc_q[i] - (y_acc_q[i] >>> DC_K);
          x_prev_q[i] <= x_in[i];
        end
      end
    end
  end

  assign valid_o = valid_d;

endmodule
