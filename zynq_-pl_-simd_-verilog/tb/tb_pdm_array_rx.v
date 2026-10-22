// PDM 麦阵列接收的验收测试。
//
// 配两个行为级模型顶掉物理器件（板子不在仿真里）：
//   · pdm_mic_model  误差反馈 ΣΔ 调制器，NTF=(1-z^-1)^2，输出 1 位流
//   · pdm_ref_cic    64 位**不回绕**的 CIC 参考，与 DUT 的 24 位回绕实现对照
//
// 十段，每段先证明观测有效再断言（本仓库的老规矩）：
//   1. 使能前：pdm_clk 不跳、sample_valid 不响、帧计数不动
//   2. 位精确：16 通道与 64 位参考**逐样点**相等（DUT 的回绕实现 vs 无回绕参考）
//   3. 绝对金标：4 种固定码型的稳态值必须等于 pdm_decim.py 算出的数
//   4. N_CH=8 实例化同样正确（证明 8/16 都是同一个 RTL）
//   5. 逐通道独立：只改一个通道的码型，只有那一个通道变
//   6. ΣΔ 麦 + 1 kHz 正弦：恢复幅度必须落在解析通带下垂允许的范围内
//   7. 冻结检测
//   8. 反证（单线）：采点从低半周期挪到高半周期，结果必须跟着变
//   9. 共线：两个相位各自等于自己的参考；再用一个"采点挪到高半周期"的
//      对照件做反证 —— 它必须读到另一个麦的位流
//  10. 共线缺麦：一个相位悬空 ⇒ 只有那个通道的 frozen 置位
//  11. 反证（共线）：把两个麦占的半周期对调，两个通道的数据必须**互换**
//
// ⚠ 第 9–11 段的激励是**三态**的（tri0 + 谁不驱动谁高阻）。旧版麦模型整周期都
//   在推数据，表达不了"某个半周期是高阻"，于是"采到错的那半会读到下拉"这件事
//   根本无从断言 —— 旧版第 8 段一直是假绿。见 docs/issues/090。
// ⚠ 这里是**理想下拉**模型。真实线缆电容让悬空半周期的 RC ≈ 5 µs ≫ 200 ns，
//   缺麦时那一半**掉不到 0** —— 第 10 段验的是理想判据，真判据待上板量。
// ⚠ `check` 的消息串**必须是 ASCII**：中文串经打包向量 + %0s 会散成方块
//   （docs/issues/048）。注释是中文没问题，只有这条路径不行。
`timescale 1ns/1ps

// ── 误差反馈 ΣΔ 调制器（行为级数字麦）────────────────────────────────────
// NTF = 1 - 2z^-1 + z^-2 = (1-z^-1)^2，STF = 1。
// edge_sel_i: 0 = 数据在 pdm_clk 下降沿更新（IM73D122 的 LR=GND 就是这种），
//             1 = 上升沿（反证用）。
// 用 real 做，不做定点 —— 它是激励源不是被测件，定点误差只会污染判据。
module pdm_mic_model (
  input             clk_i,
  input             rst_n_i,
  input             en_i,
  input             pdm_clk_i,
  input             edge_sel_i,
  input      real   amp_i,        // 满刻度 1.0
  input      real   freq_i,       // Hz
  output reg        dout_o
);
  localparam real FS_PDM = 2.5e6;
  localparam real TWO_PI = 6.283185307179586;

  real   e0, e1, w, u, yi, phase;
  reg    pdm_clk_d;

  wire fall = pdm_clk_d & ~pdm_clk_i;
  wire rise = ~pdm_clk_d & pdm_clk_i;

  always @(posedge clk_i) pdm_clk_d <= pdm_clk_i;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      e0 <= 0.0; e1 <= 0.0; phase <= 0.0; dout_o <= 1'b0;
    end else if (!en_i) begin
      e0 <= 0.0; e1 <= 0.0; phase <= 0.0; dout_o <= 1'b0;
    end else if (edge_sel_i ? rise : fall) begin
      u  = amp_i * $sin(TWO_PI * freq_i * phase);
      w  = u - (2.0 * e0 - 1.0 * e1);     // 减掉 NTF 的反馈项
      yi = (w >= 0.0) ? 1.0 : -1.0;
      e1 = e0;
      e0 = yi - w;
      phase <= phase + 1.0 / FS_PDM;
      dout_o <= (yi > 0.0);
    end
  end
endmodule

// ── 参考 CIC（64 位，不回绕，无饱和）──────────────────────────────────────
// 与 DUT **实现方式不同**：宽位宽 + 不饱和。这样「DUT == 参考」才同时验证了
// 「24 位回绕算术正确」和「输出级居中/移位/饱和正确」两件事。
module pdm_ref_cic #(
  parameter integer ORDER = 3,
  parameter integer DECIM = 64,
  parameter integer OUT_W = 24
) (
  input  clk_i,
  input  rst_n_i,
  input  en_i,
  input  bit_i,
  input  bit_en_i,
  input  decim_en_i,
  output reg sample_en_o,
  output reg signed [OUT_W-1:0] sample_o
);
  localparam integer OFFSET = (DECIM ** ORDER) / 2;
  localparam integer SHIFT  = (OUT_W - 1) - $clog2(OFFSET);
  localparam signed [63:0] MAXV = (1 <<< (OUT_W-1)) - 1;
  localparam signed [63:0] MINV = -(1 <<< (OUT_W-1));

  reg bit_q, ben_q, den_q;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i)      begin bit_q <= 0; ben_q <= 0; den_q <= 0; end
    else if (!en_i)    begin bit_q <= 0; ben_q <= 0; den_q <= 0; end
    else               begin bit_q <= bit_i; ben_q <= bit_en_i; den_q <= decim_en_i; end
  end

  reg signed [63:0] acc  [0:ORDER-1];
  reg signed [63:0] comb [0:ORDER-1];
  reg signed [63:0] cw   [0:ORDER];
  integer i;

  always @(*) begin
    cw[0] = acc[ORDER-1];
    for (i = 0; i < ORDER; i = i + 1) cw[i+1] = cw[i] - comb[i];
  end

  wire signed [63:0] sh = (cw[ORDER] - OFFSET) <<< SHIFT;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i || !en_i) begin
      for (i = 0; i < ORDER; i = i + 1) begin acc[i] <= 0; comb[i] <= 0; end
      sample_en_o <= 1'b0;
      sample_o <= {OUT_W{1'b0}};
    end else begin
      if (ben_q) begin
        acc[0] <= acc[0] + (bit_q ? 1 : 0);
        for (i = 1; i < ORDER; i = i + 1) acc[i] <= acc[i] + acc[i-1];
      end
      sample_en_o <= den_q;
      if (den_q) begin
        for (i = 0; i < ORDER; i = i + 1) comb[i] <= cw[i];
        // 累加器不回绕 ⇒ 中间值全对；但**输出级仍要饱和**：
        // 全 1 码型给出 +8388608，正好越过 24 位正满刻度 8388607。
        // 这是输出映射的一部分，不是回绕问题 —— 金标值由 pdm_decim.py 独立给出。
        if (sh > MAXV)      sample_o <= MAXV[OUT_W-1:0];
        else if (sh < MINV) sample_o <= MINV[OUT_W-1:0];
        else                sample_o <= sh[OUT_W-1:0];
      end
    end
  end
endmodule

// ── TB ────────────────────────────────────────────────────────────────────
module tb_pdm_array_rx;

  parameter integer N_CH        = 8;
  localparam integer N8          = 8;
  localparam integer NL          = N_CH/2;
  localparam integer OUT_W       = 24;
  localparam integer LOSS_FRAMES = 16;      // TB 里取小值，跑得快
  localparam integer MAX_CYCLES  = 600000;

  // 金标：由 scripts/golden/pdm_decim.py 算出，并经「CIC 对 64 周期信号只有
  // 直流分量」这条解析性质独立复核（稳态值 = D^N × 该码型的均值）。两条路一致。
  localparam signed [OUT_W-1:0] G_ALL1 =  24'sd8388607;   // 262144×1.00 上饱和 1 LSB
  localparam signed [OUT_W-1:0] G_ALL0 = -24'sd8388608;   // 0
  localparam signed [OUT_W-1:0] G_ALT  =  24'sd0;         // 262144×0.50
  localparam signed [OUT_W-1:0] G_W64  =  24'sd1572864;   // 262144×38/64=155648 → 居中左移
  localparam [63:0] W64 = 64'h9E3779B97F4A7C15;

  // ── 时钟与复位 ────────────────────────────────────────────────────────
  reg clk = 1'b0;
  always #12.5 clk = ~clk;              // 40 MHz

  reg rst_n = 1'b0;
  reg en    = 1'b0;

  // TB 自己起一个 clkgen 给参考模型，参数与 DUT 的**消费点**一致（tick 12），
  // 否则比的是两个不同相位的抽取器。
  wire pdm_clk4, bit_en4, decim_en4;

  rv32_pdm_clkgen #(.HOLD_TICK(4), .CONSUME_TICK(12)) u_cg4 (
    .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
    .pdm_clk_o(pdm_clk4), .hold_en_o(), .bit_en_o(bit_en4), .decim_en_o(decim_en4)
  );

  // ── 单线位流激励（MICS_PER_LINE = 1 用）────────────────────────────────
  // pat_sel[2:0]: 0=LFSR 1=全1 2=全0 3=0101 4=W64 5=ΣΔ 麦模型
  reg [2:0]  pat_sel [0:N_CH-1];
  reg        src_edge;                  // 0=源在下降沿更新, 1=上升沿（段 8 反证用）
  reg [15:0] lfsr    [0:N_CH-1];

  reg  pdm_d;
  wire ev_fall = pdm_d & ~pdm_clk4;
  wire ev_rise = ~pdm_d & pdm_clk4;
  always @(posedge clk) pdm_d <= pdm_clk4;

  wire [N_CH-1:0] bit_w;
  wire [N8-1:0]   bit8_w;

  genvar gi;
  generate
    for (gi = 0; gi < N_CH; gi = gi + 1) begin : g_src
      reg [6:0] wcnt;                   // W64 的位指针
      wire signed [63:0] wsh = W64;
      // 更新沿可选：真实 PDM 麦有的在下降沿推出数据、有的在上升沿。
      // 段 8 靠翻这个把「采点选错半周期」变可见。
      wire ev = src_edge ? ev_rise : ev_fall;

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          lfsr[gi] <= 16'hACE1 ^ (gi * 16'h1111);
          wcnt <= 7'd0;
        end else if (en && ev) begin
          lfsr[gi] <= {lfsr[gi][14:0], lfsr[gi][15] ^ lfsr[gi][13] ^ lfsr[gi][12] ^ lfsr[gi][10]};
          wcnt <= (wcnt == 7'd63) ? 7'd0 : (wcnt + 7'd1);
        end
      end

      wire mic_bit;
      pdm_mic_model u_mic (
        .clk_i(clk), .rst_n_i(rst_n), .en_i(en), .pdm_clk_i(pdm_clk4),
        .edge_sel_i(src_edge), .amp_i(0.5), .freq_i(1000.0), .dout_o(mic_bit)
      );

      assign bit_w[gi] =
        (pat_sel[gi] == 3'd0) ? lfsr[gi][15] :
        (pat_sel[gi] == 3'd1) ? 1'b1 :
        (pat_sel[gi] == 3'd2) ? 1'b0 :
        (pat_sel[gi] == 3'd3) ? ~wcnt[0] :        // 0101…（wcnt 偶=1）
        (pat_sel[gi] == 3'd4) ? wsh[wcnt] :
                                mic_bit;
    end
  endgenerate

  assign bit8_w = bit_w[N8-1:0];

  // ── DUT：单线 ─────────────────────────────────────────────────────────
  wire [N_CH*OUT_W-1:0]  av16;
  wire                   sv16;
  wire [31:0]            fc16;
  wire [N_CH-1:0]        fz16;
  wire                   dut_clk_o;

  rv32_pdm_array_rx #(
    .MIC_STARTUP_CYCLES(0), .CIC_SETTLE_FRAMES(0), // Raw arithmetic diagnostic.
    .N_CH(N_CH), .MICS_PER_LINE(1), .OUT_W(OUT_W), .LOSS_FRAMES(LOSS_FRAMES)
  ) u_dut (
    .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
    .pdm_din_i(bit_w), .pdm_clk_o(dut_clk_o),
    .audio_vec_o(av16), .sample_valid_o(sv16), .frame_cnt_o(fc16), .frozen_o(fz16)
  );

  wire [N8*OUT_W-1:0] av8;
  wire                sv8;
  rv32_pdm_array_rx #(
    .MIC_STARTUP_CYCLES(0), .CIC_SETTLE_FRAMES(0), // Raw arithmetic diagnostic.
    .N_CH(N8), .MICS_PER_LINE(1), .OUT_W(OUT_W), .LOSS_FRAMES(LOSS_FRAMES)
  ) u_dut8 (
    .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
    .pdm_din_i(bit8_w), .pdm_clk_o(),
    .audio_vec_o(av8), .sample_valid_o(sv8), .frame_cnt_o(), .frozen_o()
  );

  // 段 8 的对照件：只把采点挪到高半周期（HOLD_TICK=11，高半周期里最晚的一拍），
  // 消费点与主 DUT 相同（12）⇒ 两个 DUT 的 valid 同拍。
  // ⚠ 不能用 HOLD_TICK=12：clkgen 要求 HOLD < CONSUME，相等会读到锁存前的旧值。
  wire [N8*OUT_W-1:0] av12;
  wire                sv12;
  rv32_pdm_array_rx #(
    .MIC_STARTUP_CYCLES(0), .CIC_SETTLE_FRAMES(0), // Raw arithmetic diagnostic.
    .N_CH(N8), .MICS_PER_LINE(1), .OUT_W(OUT_W),
    .HOLD_TICK(11), .CONSUME_TICK(12), .LOSS_FRAMES(LOSS_FRAMES)
  ) u_dut12 (
    .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
    .pdm_din_i(bit8_w), .pdm_clk_o(),
    .audio_vec_o(av12), .sample_valid_o(sv12), .frame_cnt_o(), .frozen_o()
  );

  // ── DUT：共线（一根数据线两个麦）──────────────────────────────────────
  // 线上是 tri0 = 理想下拉（P-12）。谁都不驱动的半周期读出来是 0。
  // ⚠ 真实线缆电容让悬空半周期掉不到 0，见文件头。
  reg  [2:0]    pat_a [0:NL-1], pat_b [0:NL-1];
  reg  [15:0]   lfsr_a[0:NL-1], lfsr_b[0:NL-1];
  reg  [6:0]    wcnt_a[0:NL-1], wcnt_b[0:NL-1];
  reg           lr_swap;        // 段 11 反证：对调两个麦占的半周期
  reg  [NL-1:0] a_hiz;          // 段 10：模拟相位 A 缺麦（那半悬空）

  wire          dual_clk, dual_sv;
  wire [N_CH*OUT_W-1:0] dav;
  wire [N_CH-1:0]       dfz;

  tri0 [NL-1:0] line_w;

  rv32_pdm_array_rx #(
    .MIC_STARTUP_CYCLES(0), .CIC_SETTLE_FRAMES(0), // Raw arithmetic diagnostic.
    .N_CH(N_CH), .MICS_PER_LINE(2), .OUT_W(OUT_W), .LOSS_FRAMES(LOSS_FRAMES)
  ) u_dutd (
    .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
    .pdm_din_i(line_w), .pdm_clk_o(dual_clk),
    .audio_vec_o(dav), .sample_valid_o(dual_sv), .frame_cnt_o(), .frozen_o(dfz)
  );

  // 段 9 的对照件：采点**故意**落进高半周期。它两个通道都该读到相位 B 的位流。
  wire                   dw_sv;
  wire [N_CH*OUT_W-1:0]  dwav;
  rv32_pdm_array_rx #(
    .MIC_STARTUP_CYCLES(0), .CIC_SETTLE_FRAMES(0), // Raw arithmetic diagnostic.
    .N_CH(N_CH), .MICS_PER_LINE(2), .OUT_W(OUT_W),
    .HOLD_TICK(11), .CONSUME_TICK(12), .LOSS_FRAMES(LOSS_FRAMES)
  ) u_dutdw (
    .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
    .pdm_din_i(line_w), .pdm_clk_o(),
    .audio_vec_o(dwav), .sample_valid_o(dw_sv), .frame_cnt_o(), .frozen_o()
  );

  // 两个麦的更新沿与驱动半周期。IM73D122 datasheet §3.5 Table 8：
  //   LR=GND 的麦在下降沿推出、低半周期驱动；LR=VDD 的在上升沿推出、高半周期驱动。
  // lr_swap 把两者对调（只有激励源变了，DUT 一个参数都不动）。
  reg dual_d;
  wire dual_fall = dual_d & ~dual_clk;
  wire dual_rise = ~dual_d &  dual_clk;
  always @(posedge clk) dual_d <= dual_clk;

  generate
    for (gi = 0; gi < NL; gi = gi + 1) begin : g_dual
      wire a_ev   = lr_swap ? dual_rise : dual_fall;
      wire b_ev   = lr_swap ? dual_fall : dual_rise;
      wire a_half = lr_swap ?  dual_clk : ~dual_clk;   // 相位 A 占的半周期

      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          lfsr_a[gi] <= 16'h7A5A ^ (gi * 16'h1111);
          lfsr_b[gi] <= 16'h3C3C ^ (gi * 16'h2222);
          wcnt_a[gi] <= 7'd0;
          wcnt_b[gi] <= 7'd0;
        end else if (en) begin
          if (a_ev) begin
            lfsr_a[gi] <= {lfsr_a[gi][14:0], lfsr_a[gi][15] ^ lfsr_a[gi][13] ^
                           lfsr_a[gi][12] ^ lfsr_a[gi][10]};
            wcnt_a[gi] <= (wcnt_a[gi] == 7'd63) ? 7'd0 : (wcnt_a[gi] + 7'd1);
          end
          if (b_ev) begin
            lfsr_b[gi] <= {lfsr_b[gi][14:0], lfsr_b[gi][15] ^ lfsr_b[gi][13] ^
                           lfsr_b[gi][12] ^ lfsr_b[gi][10]};
            wcnt_b[gi] <= (wcnt_b[gi] == 7'd63) ? 7'd0 : (wcnt_b[gi] + 7'd1);
          end
        end
      end

      wire a_bit = (pat_a[gi] == 3'd0) ? lfsr_a[gi][15] :
                   (pat_a[gi] == 3'd1) ? 1'b1 :
                   (pat_a[gi] == 3'd2) ? 1'b0 :
                                         ~wcnt_a[gi][0];
      wire b_bit = (pat_b[gi] == 3'd0) ? lfsr_b[gi][15] :
                   (pat_b[gi] == 3'd1) ? 1'b1 :
                   (pat_b[gi] == 3'd2) ? 1'b0 :
                                         ~wcnt_b[gi][0];

      // 相位 A 占的那半个周期由 a_half 选；a_hiz 时那个麦不在 ⇒ 悬空 ⇒ 下拉。
      // 相位 B 永远驱动自己那半。
      assign line_w[gi] = en ? (a_half ? (a_hiz[gi] ? 1'bz : a_bit) : b_bit) : 1'bz;
    end
  endgenerate

  // ── 参考模型 ──────────────────────────────────────────────────────────
  wire signed [OUT_W-1:0] ref16 [0:N_CH-1];
  wire signed [OUT_W-1:0] ref_a [0:NL-1];
  wire signed [OUT_W-1:0] ref_b [0:NL-1];

  generate
    for (gi = 0; gi < N_CH; gi = gi + 1) begin : g_ref
      pdm_ref_cic #(.OUT_W(OUT_W)) u_ref (
        .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
        .bit_i(bit_w[gi]), .bit_en_i(bit_en4), .decim_en_i(decim_en4),
        .sample_en_o(), .sample_o(ref16[gi])
      );
    end
    for (gi = 0; gi < NL; gi = gi + 1) begin : g_refd
      pdm_ref_cic #(.OUT_W(OUT_W)) u_refa (
        .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
        .bit_i(g_dual[gi].a_bit), .bit_en_i(bit_en4), .decim_en_i(decim_en4),
        .sample_en_o(), .sample_o(ref_a[gi])
      );
      pdm_ref_cic #(.OUT_W(OUT_W)) u_refb (
        .clk_i(clk), .rst_n_i(rst_n), .en_i(en),
        .bit_i(g_dual[gi].b_bit), .bit_en_i(bit_en4), .decim_en_i(decim_en4),
        .sample_en_o(), .sample_o(ref_b[gi])
      );
    end
  endgenerate

  // ── 检查工具 ──────────────────────────────────────────────────────────
  // ⚠ 消息串一律 ASCII（docs/issues/048）。
  integer errors = 0;
  integer ncheck = 0;
  integer cycle_count = 0;
  always @(posedge clk) cycle_count = cycle_count + 1;

  task check;
    input             cond;
    input [8*160-1:0] msg;
    begin
      ncheck = ncheck + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s  (t=%0t)", msg, $time);
      end
    end
  endtask

  function signed [OUT_W-1:0] ch16;  input integer k; begin ch16 = av16[k*OUT_W +: OUT_W]; end endfunction
  function signed [OUT_W-1:0] ch8;   input integer k; begin ch8  = av8 [k*OUT_W +: OUT_W]; end endfunction
  function signed [OUT_W-1:0] ch12;  input integer k; begin ch12 = av12[k*OUT_W +: OUT_W]; end endfunction
  function signed [OUT_W-1:0] chd;   input integer k; begin chd  = dav [k*OUT_W +: OUT_W]; end endfunction
  function signed [OUT_W-1:0] chdw;  input integer k; begin chdw = dwav[k*OUT_W +: OUT_W]; end endfunction

  task wait_valid;
    begin
      @(posedge clk);
      while (!sv16) @(posedge clk);
    end
  endtask

  task wait_validd;                     // 共线 DUT 的 sample_valid
    begin
      @(posedge clk);
      while (!dual_sv) @(posedge clk);
    end
  endtask

  task wait_n_valid;
    input integer n;
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) wait_valid;
    end
  endtask

  task wait_n_validd;
    input integer n;
    integer j;
    begin
      for (j = 0; j < n; j = j + 1) wait_validd;
    end
  endtask

  // ── 主流程 ────────────────────────────────────────────────────────────
  integer i, k, mism, nsamp;
  reg signed [OUT_W-1:0] v8_before, v12_a, v12_b;
  reg signed [OUT_W-1:0] peak_pos, peak_neg, amp_meas;

  initial begin
    // 上电：通道 8…15 用 LFSR，0…3 用四种固定码型，4…7 也用 LFSR
    for (i = 0; i < N_CH; i = i + 1) pat_sel[i] = 3'd0;
    pat_sel[0] = 3'd1;   // 全 1
    pat_sel[1] = 3'd2;   // 全 0
    pat_sel[2] = 3'd3;   // 0101
    pat_sel[3] = 3'd4;   // W64
    src_edge = 1'b0;
    lr_swap  = 1'b0;
    a_hiz    = {NL{1'b0}};
    for (i = 0; i < NL; i = i + 1) begin
      pat_a[i] = 3'd0;
      pat_b[i] = 3'd0;
    end

    // ── 段 1：使能前必须完全静默 ────────────────────────────────────────
    $display("== 1. 使能前静默");
    #2000;
    check(dut_clk_o === 1'b0, "before enable: pdm_clk must stay low");
    check(pdm_clk4  === 1'b0, "before enable: the tb clkgen must stay low too");
    check(sv16 === 1'b0,      "before enable: sample_valid must be low");
    check(fc16 === 32'd0,     "before enable: frame count must be zero");
    #2000;
    check(sv16 === 1'b0,      "before enable: sample_valid must STILL be low");
    $display("   使能前 2000 拍内 valid/帧计数/时钟均静止 ✓");

    // ── 段 2：位精确 ────────────────────────────────────────────────────
    $display("== 2. 位精确（16 通道 DUT vs 64 位无回绕参考）");
    rst_n = 1'b0; #100; rst_n = 1'b1;
    en = 1'b1;

    mism = 0; nsamp = 0;
    for (k = 0; k < 24; k = k + 1) begin
      wait_valid;
      nsamp = nsamp + 1;
      if (nsamp > 2) begin                  // 前两拍是瞬态，参考模型还没稳定
        for (i = 0; i < N_CH; i = i + 1) begin
          if (ch16(i) !== ref16[i]) begin
            mism = mism + 1;
            if (mism <= 3)
              $display("    ch%0d 第 %0d 样点: DUT=%0d 参考=%0d", i, nsamp, ch16(i), ref16[i]);
          end
        end
      end
    end
    check(mism == 0, "16 ch must equal the 64-bit reference sample by sample");
    $display("   %0d 个样点 × %0d 通道，失配 %0d 个", nsamp - 2, N_CH, mism);

    // ── 段 3：绝对金标 ──────────────────────────────────────────────────
    $display("== 3. 绝对金标（值由 pdm_decim.py 算出，非本 TB 推导）");
    check(ch16(0) === G_ALL1, "all-1 pattern steady state must be +8388607");
    check(ch16(1) === G_ALL0, "all-0 pattern steady state must be -8388608");
    check(ch16(2) === G_ALT,  "0101 pattern steady state must be 0");
    check(ch16(3) === G_W64,  "W64 pattern steady state must be 1572864");
    $display("   全1=%0d 全0=%0d 0101=%0d W64=%0d", ch16(0), ch16(1), ch16(2), ch16(3));

    // ── 段 4：N_CH=8 实例化 ─────────────────────────────────────────────
    $display("== 4. N_CH=8 实例化（同一个 RTL 的另一种参数化）");
    wait_valid;
    mism = 0;
    for (i = 0; i < N8; i = i + 1) begin
      if (ch8(i) !== ref16[i]) mism = mism + 1;
    end
    check(mism == 0, "the N_CH=8 instantiation must equal the reference too");
    check(ch8(0) === G_ALL1, "the N_CH=8 all-1 channel golden must hold too");
    $display("   8 通道失配 %0d 个，ch0=%0d ✓", mism, ch8(0));

    // ── 段 5：逐通道独立 ────────────────────────────────────────────────
    $display("== 5. 逐通道独立");
    v8_before = ch16(N_CH-1);
    pat_sel[N_CH-1] = 3'd1;                       // 把 ch8 从 LFSR 换成全 1
    wait_n_valid(3);
    check(ch16(N_CH-1) !== v8_before, "the channel that was changed must change");
    mism = 0;
    for (i = 0; i < N_CH; i = i + 1) begin
      if (i != N_CH-1) begin
        if (ch16(i) !== ref16[i]) mism = mism + 1;
      end
    end
    check(mism == 0, "no other channel may be affected");
    $display("   ch8 改动生效，其余 %0d 通道无一受影响 ✓", N_CH - 1);
    pat_sel[N_CH-1] = 3'd0;

    // ── 段 6：ΣΔ 麦 + 正弦 ──────────────────────────────────────────────
    // 解析预期：1 kHz 处 CIC 通带下垂 = 20log10(H(1k)) = −0.03 dB，可忽略。
    // 所以恢复出的正弦幅度应当 ≈ 0.5 × 2^23 = 4194304（amp=0.5 满刻度）。
    // 允许 ±3 dB 覆盖 ΣΔ 的噪声与非理想性；超出就说明链路增益错了。
    $display("== 6. ΣΔ 麦模型 + 1 kHz 正弦（查链路增益）");
    for (i = 0; i < N_CH; i = i + 1) pat_sel[i] = 3'd5;   // 全部切到麦模型
    rst_n = 1'b0; #100; rst_n = 1'b1;                     // 复位重来
    peak_pos = -24'sd8388608; peak_neg = 24'sd8388607;
    for (k = 0; k < 40; k = k + 1) begin
      wait_valid;
      if (k >= 4) begin                                   // 前 4 拍丢瞬态
        if (ch16(0) > peak_pos) peak_pos = ch16(0);
        if (ch16(0) < peak_neg) peak_neg = ch16(0);
      end
    end
    amp_meas = (peak_pos - peak_neg) / 2;
    $display("   实测峰峰值 %0d，折算幅度 %0d，解析预期 ≈ %0d（0.5×2^23）",
             peak_pos - peak_neg, amp_meas, 24'sd4194304);
    check(amp_meas > 24'sd2960000, "recovered amplitude must not be below -3 dB");
    check(amp_meas < 24'sd5930000, "recovered amplitude must not be above +3 dB");

    // ── 段 7：冻结检测 ──────────────────────────────────────────────────
    $display("== 7. 冻结检测");
    rst_n = 1'b0; #100; rst_n = 1'b1;
    for (i = 0; i < N_CH; i = i + 1) pat_sel[i] = 3'd3;   // 全部 0101 → 恒定
    wait_n_valid(LOSS_FRAMES + 4);
    check(fz16[0] === 1'b1, "frozen must set after LOSS_FRAMES constant frames");
    check(fz16[7] === 1'b1, "every channel must freeze independently");
    pat_sel[0] = 3'd0;                                    // 只让 ch0 动起来
    wait_n_valid(4);
    check(fz16[0] === 1'b0, "frozen must clear once the pattern varies again");
    check(fz16[7] === 1'b1, "a channel that did not change must not be cleared");
    $display("   恒定 %0d 帧后置位、恢复变化后清零，且逐通道独立 ✓", LOSS_FRAMES);

    // ── 段 8：反证（单线）—— 采点真的接在通路上 ─────────────────────────
    // 单线配置下数据线整周期被驱动，所以"采点"= HOLD_TICK。主 DUT 采低半周期
    // （HOLD_TICK=4），对照件 u_dut12 采高半周期（HOLD_TICK=11），消费点相同。
    // 源在下降沿更新 ⇒ 一个位周期内电平不变 ⇒ 两者必须**相等**；
    // 源改成上升沿更新 ⇒ 高半周期换了新值 ⇒ 两者必须**不等**。
    // 若 HOLD_TICK 没接进通路，两种情况都会相等 ⇒ 第二条断言失败。
    // 用 LFSR 不做正弦：正弦位流整体移位一位，64 位窗口和几乎不变，反证不可靠。
    $display("== 8. 反证（单线）：采点从低半周期挪到高半周期，结果必须跟着变");
    rst_n = 1'b0; #100; rst_n = 1'b1;
    for (i = 0; i < N_CH; i = i + 1) pat_sel[i] = 3'd0;   // LFSR，无周期性
    src_edge = 1'b0;
    wait_n_valid(8);
    v12_a = ch12(0);
    check(ch12(0) === ch16(0),
          "falling-edge source: both sample points must see the same bit");

    rst_n = 1'b0; #100; rst_n = 1'b1;
    src_edge = 1'b1;                                      // 源改成上升沿更新
    wait_n_valid(8);
    v12_b = ch12(0);
    check(ch12(0) !== ch16(0),
          "rising-edge source: the two sample points must differ -- if equal, HOLD_TICK is not wired");
    $display("   下降沿更新：两采点都 = %0d（一致）", v12_a);
    $display("   上升沿更新：高半采点 %0d，低半采点 %0d，确实不同 ✓", v12_b, ch16(0));
    src_edge = 1'b0;

    // ── 段 9：共线 —— 每个相位各自等于自己的参考 ────────────────────────
    $display("== 9. 共线：参数化 N_CH/2 根线 × 2 麦，逐相位与自己的参考逐样点比对");
    lr_swap = 1'b0;
    a_hiz   = {NL{1'b0}};
    for (i = 0; i < NL; i = i + 1) begin pat_a[i] = 3'd0; pat_b[i] = 3'd0; end
    rst_n = 1'b0; #100; rst_n = 1'b1;

    mism = 0; nsamp = 0;
    while (nsamp < 24) begin
      wait_validd;
      nsamp = nsamp + 1;
      // ⚠ 第 1 个样点丢：使能后**第一个边沿是上升沿**（div_q 从 0 起，
      //   pdm_clk 先低）⇒ 相位 A 的麦在第一个位周期里没被下降沿驱动过，
      //   它那一拍是启动瞬态。相位 B 没这个问题。
      if (nsamp > 1) begin
        for (i = 0; i < NL; i = i + 1) begin
          if (chd(2*i)   !== ref_a[i]) mism = mism + 1;
          if (chd(2*i+1) !== ref_b[i]) mism = mism + 1;
        end
      end
    end
    check(mism == 0, "every phase of every line must equal its own reference");
    $display("   %0d 个样点 × %0d 根线，失配 %0d 个", nsamp - 1, NL, mism);

    // 反证：把采点**故意**挪进高半周期（HOLD_TICK=11），相位 A 读到的就应该是
    // 相位 B 的位流。若 HOLD_TICK 根本没接进通路，u_dutdw 会与 u_dutd 完全一样，
    // 三条断言会一起失败。这是"共线解复用真的通了"的判据。
    $display("== 9b. 反证（共线）：采点挪进高半周期后，两个相位必须读到同一股位流");
    wait_validd;
    check(chdw(0) === chd(1), "with the hold point in the high half, phase A reads phase B's stream");
    check(chdw(1) === chd(1), "phase B is unaffected: it already samples the high half");
    check(chdw(0) !== chd(0), "the wrong hold point must change the result -- if equal, it is not wired");
    $display("   对照件 ch0=%0d ch1=%0d，正确件 ch1=%0d —— 两个相位确实并到一起 ✓",
             chdw(0), chdw(1), chd(1));

    // ── 段 10：共线缺麦 —— 只有缺的那一路 frozen ────────────────────────
    // ⚠ 这里验的是**理想下拉**：悬空半个周期被 tri0 钉到 0 ⇒ 抽取输出恒定。
    //   真实线缆电容 RC ≈ 5 µs ≫ 200 ns，那一半**掉不到 0**，会保持另一个麦的
    //   电平 ⇒ 真板上缺麦可能**根本不置位**。这条必须上板量（同文件头）。
    $display("== 10. 共线缺麦：相位 A 悬空时只有该通道 frozen 置位");
    rst_n = 1'b0; #100; rst_n = 1'b1;
    for (i = 0; i < NL; i = i + 1) begin pat_a[i] = 3'd0; pat_b[i] = 3'd0; end
    a_hiz[0] = 1'b1;                       // 线 0 的相位 A 麦"拔掉"
    wait_n_validd(LOSS_FRAMES + 4);
    check(dfz[0] === 1'b1, "phase A absent => that channel's frozen must set");
    check(dfz[1] === 1'b0, "phase B on the same line still drives: must not be frozen");
    check(dfz[2] === 1'b0, "no other line may be affected");
    $display("   线 0 相位 A 置位、相位 B 未置位、其余线未置位 ✓");
    a_hiz = {NL{1'b0}};

    // ── 段 11：反证（共线）—— LR 对调后两个通道必须互换 ────────────────
    // 只改激励源（两个麦占的半周期对调），DUT 一个参数不动。
    // 若 lr_swap 没接到激励上，两个通道会保持原值 ⇒ 断言失败（045 那一类陷阱）。
    $display("== 11. 反证（共线）：LR 对调后同线两通道的数据必须互换");
    lr_swap = 1'b0;
    rst_n = 1'b0; #100; rst_n = 1'b1;
    wait_n_validd(9);
    check(chd(0) === ref_a[0], "before the swap: channel 0 must equal the phase-A reference");
    check(chd(1) === ref_b[0], "before the swap: channel 1 must equal the phase-B reference");
    check(ref_a[0] !== ref_b[0], "the two reference streams must differ, or a swap is invisible");

    rst_n = 1'b0; #100; lr_swap = 1'b1; #100; rst_n = 1'b1;
    wait_n_validd(9);
    check(chd(0) === ref_b[0], "after the swap: channel 0 must carry phase B's data");
    check(chd(1) === ref_a[0], "after the swap: channel 1 must carry phase A's data");
    $display("   对调前 ch0=%0d ch1=%0d；对调后 ch0=%0d ch1=%0d —— 确实互换 ✓",
             ref_a[0], ref_b[0], chd(0), chd(1));
    lr_swap = 1'b0;

    // ── 收尾 ────────────────────────────────────────────────────────────
    $display("");
    if (errors == 0) $display("PASS: tb_pdm_array_rx 全部 %0d 项通过（%0d 拍）", ncheck, cycle_count);
    else             $display("FAIL: tb_pdm_array_rx 共 %0d/%0d 项失败", errors, ncheck);
    $finish;
  end

  initial begin
    #(MAX_CYCLES * 25);
    $display("FAIL: TB 超时（%0d 拍）—— 大概率是 sample_valid 再也没响", MAX_CYCLES);
    $finish;
  end

endmodule
