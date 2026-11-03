// 单通道 PDM 抽取器：1 位 ΣΔ 流 → 24 位 PCM。sinc^3 / D=64。
//
// 结构就是教科书 CIC：
//   ORDER 级积分器（每 PDM 位一次，2.5 MHz）→ 每 DECIM 位取一次
//   → ORDER 级梳状差分（39.0625 kHz，与输入同拍出一样点）
//
// 参数都由 scripts/golden/pdm_decim.py 量出来，不是拍的：
//   ORDER=3   8 kHz 下垂 −1.82 dB，第一混叠带抑制 −37.2 dB，
//             2 阶 ΣΔ 下带内 SNR 93 dB。4 阶只多 39 dB 用不到的余量
//             （真实 PDM 麦模拟本底才 65–70 dB SNR），却要多花 0.61 dB 下垂 ——
//             而 8 kHz 正是故障诊断带的上沿。
//   ACC_W=24  定点回绕实测最小 20 位（= 1+ceil(log2 D^N)），取 24。
//   OFFSET/SHIFT 把 [0, D^N] 的单调输出变双极性并映射到 24 位满刻度，两者都无损。
//
// ⚠ 累加器**必须**允许二进制补码回绕，这不是偷懒是要求：
//   常值输入下积分器本来就无界增长（DC 增益 = D^N），靠梳状级把它差分掉。
//   Hogenauer 的条件只是「末级输出装得下」，中间各级回绕无害 —— 已逐点实测。
//   反过来，把梳状级做成任意精度会让输出发散（全 1 输入下 w=24 时到 ±5e7），
//   这个 bug 会把位宽试验带到完全错误的结论上。
module rv32_pdm_cic #(
  parameter integer ORDER = 3,
  parameter integer DECIM = 64,
  parameter integer ACC_W = 24,
  parameter integer OUT_W = 24
) (
  input                         clk_i,
  input                         rst_n_i,
  input                         en_i,
  input                         bit_i,
  input                         bit_en_i,
  input                         decim_en_i,
  output reg                    sample_en_o,
  output reg signed [OUT_W-1:0] sample_o
);

  localparam integer FULL   = DECIM ** ORDER;         // D^N = 262144
  localparam integer OFFSET = FULL / 2;               // 131072
  localparam integer SHIFT  = (OUT_W - 1) - $clog2(OFFSET);   // 6

  // ── 输入打一拍 ────────────────────────────────────────────────────────
  // 把引脚组合逻辑挡在积分器之外，同时让下面所有逻辑都用同一组 _q 节拍。
  // 代价是整条通路固定延后一个 clk，对通道间一致性没有影响（各通道同样延后）。
  reg bit_q;
  reg bit_en_q, decim_en_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      bit_q <= 1'b0;
      bit_en_q <= 1'b0;
      decim_en_q <= 1'b0;
    end else if (!en_i) begin
      bit_q <= 1'b0;
      bit_en_q <= 1'b0;
      decim_en_q <= 1'b0;
    end else begin
      bit_q <= bit_i;
      bit_en_q <= bit_en_i;
      decim_en_q <= decim_en_i;
    end
  end

  wire signed [ACC_W-1:0] x_in = {{(ACC_W-1){1'b0}}, bit_q};   // 0/1 零扩展进位

  // ── 积分器链 ──────────────────────────────────────────────────────────
  reg signed [ACC_W-1:0] acc [0:ORDER-1];
  integer i;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      for (i = 0; i < ORDER; i = i + 1) acc[i] <= {ACC_W{1'b0}};
    end else if (!en_i) begin
      for (i = 0; i < ORDER; i = i + 1) acc[i] <= {ACC_W{1'b0}};
    end else if (bit_en_q) begin
      // 非阻塞赋值：所有 acc[i] 读到的是本拍开始时的旧值，正是积分器级联的语义
      acc[0] <= acc[0] + x_in;
      for (i = 1; i < ORDER; i = i + 1) acc[i] <= acc[i] + acc[i-1];
    end
  end

  // ── 梳状链（组合，只在 decim_en 那拍写寄存器）──────────────────────────
  reg  signed [ACC_W-1:0] comb_d [0:ORDER-1];
  wire signed [ACC_W-1:0] cw [0:ORDER];

  assign cw[0] = acc[ORDER-1];

  genvar gi;
  generate
    for (gi = 0; gi < ORDER; gi = gi + 1) begin : g_comb
      assign cw[gi+1] = cw[gi] - comb_d[gi];
    end
  endgenerate

  // ── 输出级：居中 + 左移 + 饱和 ────────────────────────────────────────
  // cw[ORDER] ∈ [0, D^N]；减去半刻度变双极性，再左移 SHIFT 到 24 位满刻度。
  // 只有 +D^N/2 这一个点会撞上 24 位正满刻度（8388608 > 8388607），饱和掉 1 LSB。
  localparam integer SW = ACC_W + SHIFT;              // [SW:0] 共 31 位
  localparam signed [SW:0] MAXV = (1 <<< (OUT_W-1)) - 1;
  localparam signed [SW:0] MINV = -(1 <<< (OUT_W-1));

  // cent 显式取到 SW 宽：Verilog 的移位结果宽度 = **左操作数**宽度，
  // 若让 cent 只有 ACC_W+1 位，`cent <<< SHIFT` 就在那个宽度里做，
  // 高位被静默丢掉。当前参数下 25 位恰好装得下（所以 TB 是绿的），
  // 但改 ACC_W/SHIFT 就会静默截断 —— 不留这个雷。
  wire signed [SW:0]        cent = cw[ORDER] - OFFSET;
  wire signed [SW:0]        sh   = cent <<< SHIFT;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      for (i = 0; i < ORDER; i = i + 1) comb_d[i] <= {ACC_W{1'b0}};
      sample_en_o <= 1'b0;
      sample_o <= {OUT_W{1'b0}};
    end else if (!en_i) begin
      for (i = 0; i < ORDER; i = i + 1) comb_d[i] <= {ACC_W{1'b0}};
      sample_en_o <= 1'b0;
      sample_o <= {OUT_W{1'b0}};
    end else begin
      // sample_o 与 sample_en_o 同拍翻：都在 decim_en_q 的下一拍有效
      sample_en_o <= decim_en_q;
      if (decim_en_q) begin
        for (i = 0; i < ORDER; i = i + 1) comb_d[i] <= cw[i];
        sample_o <= (sh > MAXV) ? MAXV[OUT_W-1:0] :
                    (sh < MINV) ? MINV[OUT_W-1:0] : sh[OUT_W-1:0];
      end
    end
  end

endmodule
