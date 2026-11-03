// 12-channel default, six shared DATA lines; physical wiring is unverified.
// CH2k=LR GND, CH2k+1=LR VDD. Shared CIC cadence aligns PCM groups.
// Pin capture spacing is not a measured acoustic delay.
module raw9_rx #(
  parameter integer N_CH          = 8,
  parameter [N_CH-1:0] ACTIVE_MASK = {N_CH{1'b1}},
  parameter integer MICS_PER_LINE = 2,
  parameter integer OUT_W         = 24,
  parameter integer ORDER         = 3,
  parameter integer DECIM         = 64,
  parameter integer ACC_W         = 24,
  parameter integer HOLD_TICK     = 4,
  parameter integer CONSUME_TICK  = 12,
  parameter integer LOSS_FRAMES   = 4096,
  parameter integer MIC_STARTUP_CYCLES = 2000000,
  parameter integer CIC_SETTLE_FRAMES = 4
) (
  input                           clk_i,
  input                           rst_n_i,
  input                           en_i,
  input  [N_CH/MICS_PER_LINE-1:0] pdm_din_i,
  output                          pdm_clk_o,
  output [N_CH*OUT_W-1:0]         audio_vec_o,
  output                          sample_valid_o,
  output [31:0]                   frame_cnt_o,
  output [N_CH-1:0]               frozen_o
);

  localparam integer N_LINE = N_CH / MICS_PER_LINE;

  // ── 时钟与节拍 ────────────────────────────────────────────────────────
  wire hold_en_w, bit_en_w, decim_en_w;

  raw9_clkgen #(
    .HOLD_TICK    (HOLD_TICK),
    .CONSUME_TICK (CONSUME_TICK),
    .DECIM       (DECIM)
  ) u_clkgen (
    .clk_i      (clk_i),
    .rst_n_i    (rst_n_i),
    .en_i       (en_i),
    .pdm_clk_o  (pdm_clk_o),
    .hold_en_o  (hold_en_w),
    .bit_en_o   (bit_en_w),
    .decim_en_o (decim_en_w)
  );

  // ── 共线解复用：相位 A 的位保持到消费点 ───────────────────────────────
  // 只有一个寄存器，不需要移位链：CIC 只在 bit_en 那一拍看输入。
  reg [N_LINE-1:0] phase_a_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      phase_a_q <= {N_LINE{1'b0}};
    end else if (!en_i) begin
      phase_a_q <= {N_LINE{1'b0}};
    end else if (hold_en_w) begin
      phase_a_q <= pdm_din_i;
    end
  end

  // ── N_CH 个 CIC 通道 ──────────────────────────────────────────────────
  wire [N_CH-1:0] ch_valid_w;
  wire signed [OUT_W-1:0] ch_sample_w [0:N_CH-1];

  // Zero/zero is an explicit raw diagnostic mode, never acoustic acceptance.
  localparam RAW_DIAGNOSTIC = MIC_STARTUP_CYCLES == 0 && CIC_SETTLE_FRAMES == 0;
  localparam START_W = $clog2(MIC_STARTUP_CYCLES + 1) > 0 ? $clog2(MIC_STARTUP_CYCLES + 1) : 1;
  localparam SETTLE_W = $clog2(CIC_SETTLE_FRAMES + 1) > 0 ? $clog2(CIC_SETTLE_FRAMES + 1) : 1;
  reg [START_W-1:0] startup_q;
  reg [SETTLE_W-1:0] settle_q;
  reg pair_primed_q;
  wire cic_bit_en = bit_en_w && (RAW_DIAGNOSTIC || pair_primed_q);
  wire output_ready = startup_q == MIC_STARTUP_CYCLES && settle_q == CIC_SETTLE_FRAMES;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      startup_q <= 0;
      settle_q <= 0;
      pair_primed_q <= 0;
    end else if (!en_i) begin
      startup_q <= 0;
      settle_q <= 0;
      pair_primed_q <= 0;
    end else begin
      if (startup_q != MIC_STARTUP_CYCLES) startup_q <= startup_q + 1'b1;
      // The first A sample precedes the first falling CLOCK edge.
      if (bit_en_w) pair_primed_q <= 1;
      // Flush CIC after microphone startup, not merely after clock startup.
      if (startup_q != MIC_STARTUP_CYCLES) settle_q <= 0;
      else if ((&ch_valid_w) && settle_q != CIC_SETTLE_FRAMES) settle_q <= settle_q + 1'b1;
    end
  end

  genvar gl;
  generate
    for (gl = 0; gl < N_LINE; gl = gl + 1) begin : g_line
      // 每线两个麦时 A/B 占 2k/2k+1；每线一个麦时只有 A，占 k。
      localparam integer CH_A = (MICS_PER_LINE == 2) ? (2 * gl) : gl;
      localparam integer CH_B = 2 * gl + 1;

      rv32_pdm_cic #(
        .ORDER (ORDER),
        .DECIM (DECIM),
        .ACC_W (ACC_W),
        .OUT_W (OUT_W)
      ) u_cic_a (
        .clk_i      (clk_i),
        .rst_n_i    (rst_n_i),
        .en_i       (en_i),
        .bit_i      (phase_a_q[gl]),
        .bit_en_i   (cic_bit_en),
        .decim_en_i (decim_en_w),
        .sample_en_o(ch_valid_w[CH_A]),
        .sample_o   (ch_sample_w[CH_A])
      );
      assign audio_vec_o[CH_A*OUT_W +: OUT_W] = ACTIVE_MASK[CH_A] ? ch_sample_w[CH_A] : {OUT_W{1'b0}};

      if (MICS_PER_LINE == 2) begin : g_phase_b
        rv32_pdm_cic #(
          .ORDER (ORDER),
          .DECIM (DECIM),
          .ACC_W (ACC_W),
          .OUT_W (OUT_W)
        ) u_cic_b (
          .clk_i      (clk_i),
          .rst_n_i    (rst_n_i),
          .en_i       (en_i),
          .bit_i      (pdm_din_i[gl]),
          .bit_en_i   (cic_bit_en),
          .decim_en_i (decim_en_w),
          .sample_en_o(ch_valid_w[CH_B]),
          .sample_o   (ch_sample_w[CH_B])
        );
        assign audio_vec_o[CH_B*OUT_W +: OUT_W] = ACTIVE_MASK[CH_B] ? ch_sample_w[CH_B] : {OUT_W{1'b0}};
      end
    end
  endgenerate

  // sample_valid_o：与 CIC 内部的 sample_en_o 同拍（decim_en 延两拍）。
  // 用 AND 而不是取第一条：各通道的 valid 一旦不同拍，valid 直接掉，
  // 问题立刻可见而不是静默错位。
  // ⚠ 这个 AND 的前提是**所有通道共用一个 decim_en** —— 共线解复用特意保住
  //   了这一点（两个相位同拍消费），别把它拆成两套。
  assign sample_valid_o = en_i & output_ready & (&ch_valid_w);

  // ── 帧计数 ────────────────────────────────────────────────────────────
  reg [31:0] frame_cnt_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      frame_cnt_q <= 32'b0;
    end else if (!en_i) begin
      frame_cnt_q <= 32'b0;
    end else if (sample_valid_o) begin
      frame_cnt_q <= frame_cnt_q + 1'b1;
    end
  end

  assign frame_cnt_o = frame_cnt_q;

  // ── 冻结检测（frozen）─────────────────────────────────────────────────
  // 判据：抽头样点连续 LOSS_FRAMES 帧逐位不变。
  // ⚠ 报的是「这个麦的数据恒定」，**不是**「这个麦不在」—— 两者不等价：
  //   ① 真实数字静音（IM73D122 的零输入是交替码型）抽取后也恒定；
  //   ② 共线后某一相位缺麦时，那半个周期靠线容保持另一个麦的电平，
  //      **可能掉不到 0**，于是缺麦照样可能不置位。② 待上板量，见
  //      docs/pdm_array_spec.md P-12。
  //   所以它是**警告**不是错误。默认 4096 帧 ≈ 105 ms。
  reg signed [OUT_W-1:0] prev_q  [0:N_CH-1];
  reg [15:0]             still_q [0:N_CH-1];
  reg [N_CH-1:0]         frozen_q;
  integer                k;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      frozen_q <= {N_CH{1'b0}};
      for (k = 0; k < N_CH; k = k + 1) begin
        prev_q[k]  <= {OUT_W{1'b0}};
        still_q[k] <= 16'b0;
      end
    end else if (!en_i) begin
      // 停用即清，使能后从干净状态起算，否则上一次运行的计数会带进来
      frozen_q <= {N_CH{1'b0}};
      for (k = 0; k < N_CH; k = k + 1) begin
        still_q[k] <= 16'b0;
      end
    end else if (sample_valid_o) begin
      for (k = 0; k < N_CH; k = k + 1) begin
        if (ch_sample_w[k] == prev_q[k]) begin
          if (still_q[k] < LOSS_FRAMES[15:0]) begin
            still_q[k] <= still_q[k] + 1'b1;
          end
          if (still_q[k] >= LOSS_FRAMES[15:0] - 1'b1) begin
            frozen_q[k] <= 1'b1;
          end
        end else begin
          prev_q[k]   <= ch_sample_w[k];
          still_q[k]  <= 16'b0;
          frozen_q[k] <= 1'b0;
        end
      end
    end
  end

  assign frozen_o = frozen_q & ACTIVE_MASK;

endmodule
