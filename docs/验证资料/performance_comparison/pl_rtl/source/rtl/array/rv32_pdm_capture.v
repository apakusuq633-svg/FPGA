// PDM 阵列的 PS 侧采集缓冲（双 bank）。
//
// 一条样点的宽度是 N_CH × 16 位，比观测器那条 32 位（立体声 L/R）宽得多，
// 所以**一个样点占 WORDS = N_CH/2 个 32 位字**，8 通道就是 4 个字。
// 取每个通道 24 位样点的**高 16 位** —— 与既有音频通路的 16 位口径一致，
// 下游 FFT 吃的也是这个宽度。
//
// 双 bank 的语义和观测器完全一样：一个 bank 在采、另一个给 PS 读，
// 写满即发布（READY 置位），PS 读完写 ACK_SEQ 再 RELEASE 才回收。
// **采集永不反压**：bank 不可用时整帧丢弃并计数（DROP），序号让每个缺口可见。
//
// ⚠ 增益寄存器复位值是 **16384（Q2.14 的 1.0）**，不是 0。
//   rv32_chan_align 自己的增益复位是 0 也就是**静音**，PS 忘了写就什么也采不到，
//   而且现象是「有帧、有 valid、数据全 0」——看着像麦坏了。见 docs/issues/029。
//   这里反过来：默认单位增益，要改再写。少一个能静默吃掉整条通路的坑。
//
// ⚠ N_CH 必须是偶数（打包按 2 通道 1 字）。8 / 16 都满足。
module rv32_pdm_capture #(
  parameter integer N_CH     = 8,
  parameter [N_CH-1:0] ACTIVE_MASK = {N_CH{1'b1}},
  parameter integer IN_W     = 24,
  parameter integer FRAME_AW = 9
) (
  input                       clk_i,
  input                       rst_n_i,
  // 来自 rv32_chan_align（已对齐 / 去直流 / 增益校准）
  input  [N_CH*IN_W-1:0]      audio_vec_i,
  input                       valid_i,
  input  [31:0]               frame_cnt_i,
  input  [N_CH-1:0]           frozen_i,
  // PS 侧窗口（0x300–0x3FF，经 rv32_ps_regs 转发）
  input                       cfg_wr_i,
  input                       cfg_rd_i,
  input  [6:0]                cfg_addr_i,
  input  [31:0]               cfg_wdata_i,
  output reg [31:0]           cfg_rdata_o,
  // 给阵列 + chan_align 用
  output                      en_o,
  output [N_CH*16-1:0]        gain_o
);

  // ⚠ N_CH 必须 ≥ 4（下面按 2 通道 1 字打包，WORDS=1 时 WW=$clog2(1)=0 会让
  //   [WW-1:0] 变成非法位选）。8 / 16 都满足。
  localparam integer WORDS    = N_CH / 2;
  localparam integer WW       = $clog2(WORDS);
  localparam integer CAPACITY = 1 << FRAME_AW;
  localparam integer AIDX_W   = 1 + FRAME_AW + WW;
  localparam integer IDX_W    = FRAME_AW + WW;
  // ⚠ 不能写 WORDS[WW-1:0]-1：WORDS=4 时低 2 位是 2'b00，减 1 得 −1。
  localparam [WW-1:0] WORDS_M1 = WORDS - 1;

  // 寄存器号（PS 侧 0x300 + 4*n）
  localparam [6:0] R_CTRL   = 7'd0;
  localparam [6:0] R_STATUS = 7'd1;
  localparam [6:0] R_LEN    = 7'd2;
  localparam [6:0] R_SELECT = 7'd3;
  localparam [6:0] R_SEQ    = 7'd4;
  localparam [6:0] R_FIRST  = 7'd5;
  localparam [6:0] R_DROP   = 7'd6;
  localparam [6:0] R_INDEX  = 7'd7;
  localparam [6:0] R_DATA   = 7'd8;
  localparam [6:0] R_ACKSEQ = 7'd9;
  localparam [6:0] R_RELEASE= 7'd10;
  localparam [6:0] R_FRAME  = 7'd11;
  localparam [6:0] R_FROZEN = 7'd12;
  localparam [6:0] R_META   = 7'd13;
  localparam [6:0] R_GAIN0  = 7'd16;

  // ── 帧打包：每通道取 24 位样点的高 16 位 ────────────────────────────────
  wire [N_CH*16-1:0] frame_i;
  genvar gi;
  generate
    for (gi = 0; gi < N_CH; gi = gi + 1) begin : g_pack
      assign frame_i[gi*16 +: 16] = ACTIVE_MASK[gi] ? audio_vec_i[gi*IN_W + (IN_W-16) +: 16] : 16'b0;
    end
  endgenerate

  // ── 写侧状态 ──────────────────────────────────────────────────────────
  reg                   en_q, capture_q, snapshot_q;
  reg [FRAME_AW-1:0]    pos_q;
  // ⚠ 比 pos_q 宽一位：默认长度是 CAPACITY = 2^FRAME_AW，FRAME_AW 位装不下它。
  reg [FRAME_AW:0]      length_q;
  reg                   bank_q, accept_q, select_q;
  reg [1:0]             ready_q;
  reg [31:0]            sequence_q, dropped_q, ack_seq_q, ack_errors_q;
  reg [31:0]            seq0_q, seq1_q, first0_q, first1_q, meta0_q, meta1_q;
  reg [IDX_W-1:0]       rd_index_q;

  reg                   wr_active_q;
  reg [WW-1:0]          wr_word_q;
  reg [N_CH*16-1:0]     frame_q;

  wire [31:0] selected_seq   = select_q ? seq1_q : seq0_q;
  wire        selected_ready = select_q ? ready_q[1] : ready_q[0];
  wire        release_ok     = cfg_wr_i && cfg_addr_i == R_RELEASE && cfg_wdata_i[0] &&
                               selected_ready && ack_seq_q == selected_seq;
  // 刚释放的 bank 当拍就能复用；已发布的 bank 不能。
  wire [1:0]  available = ~ready_q | (release_ok ? (select_q ? 2'b10 : 2'b01) : 2'b00);
  wire        starting  = pos_q == 0;
  wire        write_bank   = starting ? !available[0] : bank_q;
  wire        write_accept = starting ? (|available) : accept_q;
  wire        capture_reset = cfg_wr_i && cfg_addr_i == R_CTRL;
  wire        frame_start = valid_i && capture_q && en_q && !wr_active_q && !capture_reset && !(snapshot_q && starting && available == 0);

  // 一个样点写 WORDS 拍。样点间隔是 1024 拍，8 通道只要 4 拍，余量极大。
  wire wr_go      = wr_active_q;
  wire wr_last    = wr_active_q && (wr_word_q == WORDS_M1);
  // WORDS is six for a 12-channel frame, so concatenation would leave holes.
  wire [AIDX_W-1:0] wr_addr = write_bank*CAPACITY*WORDS + pos_q*WORDS + wr_word_q;
  wire [AIDX_W-1:0] rd_addr = select_q*CAPACITY*WORDS + rd_index_q;

  // 一个同步写口 + 一个同步读口 ⇒ 推断出 block RAM。
  // 用法：先写 SELECT 和 INDEX，再读 DATA（AXI 会补上必需的时钟）。
  (* ram_style = "block" *) reg [31:0] memory [0:2*CAPACITY*WORDS-1];
  reg [31:0] data_q;
  always @(posedge clk_i) begin
    if (wr_go && write_accept) memory[wr_addr] <= frame_q[wr_word_q*32 +: 32];
    if (selected_ready) data_q <= rd_index_q < CAPACITY*WORDS ? memory[rd_addr] : 0;
  end

  // ── 增益（Q2.14，2 通道 1 字）─────────────────────────────────────────
  reg [15:0] gain_q [0:N_CH-1];
  integer k;
  generate
    for (gi = 0; gi < N_CH; gi = gi + 1) begin : g_gain
      assign gain_o[gi*16 +: 16] = ACTIVE_MASK[gi] ? gain_q[gi] : 16'b0;
    end
  endgenerate

  assign en_o = en_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      en_q <= 1'b0; capture_q <= 1'b0; snapshot_q <= 1'b0;
      pos_q <= 0; length_q <= CAPACITY[FRAME_AW:0];
      bank_q <= 1'b0; accept_q <= 1'b0; select_q <= 1'b0;
      ready_q <= 2'b0; sequence_q <= 0; dropped_q <= 0; ack_seq_q <= 0; ack_errors_q <= 0;
      seq0_q <= 0; seq1_q <= 0; first0_q <= 0; first1_q <= 0; meta0_q <= 0; meta1_q <= 0;
      rd_index_q <= 0; wr_active_q <= 1'b0; wr_word_q <= 0; frame_q <= 0;
      for (k = 0; k < N_CH; k = k + 1) gain_q[k] <= ACTIVE_MASK[k] ? 16'd16384 : 16'd0;   // Q2.14 的 1.0，不是静音
    end else begin
      if (cfg_wr_i && cfg_addr_i == R_LEN && !capture_q &&
          cfg_wdata_i > 0 && cfg_wdata_i <= CAPACITY) length_q <= cfg_wdata_i[FRAME_AW:0];
      if (cfg_wr_i && cfg_addr_i == R_SELECT)  select_q   <= cfg_wdata_i[0];
      if (cfg_wr_i && cfg_addr_i == R_INDEX)   rd_index_q <= cfg_wdata_i[IDX_W-1:0];
      if (cfg_wr_i && cfg_addr_i == R_ACKSEQ)  ack_seq_q  <= cfg_wdata_i;
      if (cfg_wr_i && cfg_addr_i == R_RELEASE && cfg_wdata_i[0]) begin
        if (release_ok) ready_q[select_q] <= 1'b0;
        else            ack_errors_q <= ack_errors_q + 1'b1;
      end
      for (k = 0; k < WORDS; k = k + 1) begin
        if (cfg_wr_i && cfg_addr_i == R_GAIN0 + k) begin
          gain_q[2*k]   <= ACTIVE_MASK[2*k] ? cfg_wdata_i[15:0] : 16'b0;
          gain_q[2*k+1] <= ACTIVE_MASK[2*k+1] ? cfg_wdata_i[31:16] : 16'b0;
        end
      end

      // 开一帧
      if (frame_start) begin
        frame_q      <= frame_i;
        wr_active_q  <= 1'b1;
        wr_word_q    <= 0;
        // DROP 按**丢掉的样点**计，不按丢掉的整个 bank 计。
        // 观测器那边的一帧就是一样点（立体声 32 位），所以它一帧记一次；
        // 这边一帧是 8 通道的一个样点、一个 bank 装 length_q 帧，
        // 沿用那个口径的话「丢了 4096 个样点」和「丢了 1 个 bank」会显示成同一个数，
        // 诊断时看不出丢了多少。
        if (!write_accept) dropped_q <= dropped_q + 1'b1;
        if (starting) begin
          bank_q   <= write_bank;
          accept_q <= write_accept;
          if (write_accept) begin
            if (write_bank) first1_q <= frame_cnt_i;
            else            first0_q <= frame_cnt_i;
          end
        end
      end

      // 收一帧
      if (wr_last) begin
        wr_active_q <= 1'b0;
        if ({1'b0, pos_q} == {1'b0, length_q} - 1'b1) begin
          pos_q <= 0;
          sequence_q <= sequence_q + 1'b1;
          if (write_accept) begin
            ready_q[write_bank] <= 1'b1;
            if (write_bank) begin seq1_q <= sequence_q; meta1_q <= length_q; end
            else            begin seq0_q <= sequence_q; meta0_q <= length_q; end
          end
          // 丢弃在 frame_start 那拍已经逐样点计过，这里不再重复计
        end else begin
          pos_q <= pos_q + 1'b1;
        end
      end else if (wr_active_q) begin
        wr_word_q <= wr_word_q + 1'b1;
      end

      // 写 CTRL 开一个新纪元，两个 bank 一起作废
      if (capture_reset) begin
        en_q      <= cfg_wdata_i[0];
        capture_q <= cfg_wdata_i[1];
        snapshot_q <= cfg_wdata_i[2];
        ready_q <= 2'b0; pos_q <= 0; accept_q <= 1'b0;
        sequence_q <= 0; dropped_q <= 0; ack_errors_q <= 0;
        wr_active_q <= 1'b0; wr_word_q <= 0;
      end
    end
  end

  always @* begin
    case (cfg_addr_i)
      R_CTRL:    cfg_rdata_o = {29'b0, snapshot_q, capture_q, en_q};
      // ⚠ 原来是 `{16'b0, (frozen_i & ACTIVE_MASK), 13'b0, wr_active_q, ready_q}` —— N_CH=8 时那
      //   已经是 **39 位**，赋给 32 位会被静默截掉高 7 位，frozen 落到 [22:15]，
      //   而文档写的是 [15:8]。现在按 N_CH 补零凑满 32 位：frozen 高位对齐在
      //   [31:16]（N_CH=16 时正好占满，N_CH 更小则左侧补零）。
      R_STATUS:  cfg_rdata_o = {{(16-N_CH){1'b0}}, (frozen_i & ACTIVE_MASK), 13'b0, wr_active_q, ready_q};
      R_LEN:     cfg_rdata_o = {{(32-FRAME_AW){1'b0}}, length_q};
      R_SELECT:  cfg_rdata_o = {31'b0, select_q};
      R_SEQ:     cfg_rdata_o = selected_seq;
      R_FIRST:   cfg_rdata_o = select_q ? first1_q : first0_q;
      R_DROP:    cfg_rdata_o = dropped_q;
      R_INDEX:   cfg_rdata_o = {{(32-IDX_W){1'b0}}, rd_index_q};
      R_DATA:    cfg_rdata_o = selected_ready ? data_q : 32'b0;
      R_ACKSEQ:  cfg_rdata_o = ack_seq_q;
      R_FRAME:   cfg_rdata_o = frame_cnt_i;
      7'd31:     cfg_rdata_o = 32'h41435303; // Reserved word, beyond gain registers 16..23.
      R_FROZEN:  cfg_rdata_o = {{(32-N_CH){1'b0}}, (frozen_i & ACTIVE_MASK)};
      R_META:    cfg_rdata_o = select_q ? meta1_q : meta0_q;
      default: begin
        if (cfg_addr_i >= R_GAIN0 && cfg_addr_i < R_GAIN0 + WORDS)
          cfg_rdata_o = {gain_q[2*(cfg_addr_i-R_GAIN0)+1], gain_q[2*(cfg_addr_i-R_GAIN0)]};
        else
          cfg_rdata_o = 32'b0;
      end
    endcase
  end

endmodule
