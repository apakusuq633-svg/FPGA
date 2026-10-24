module rv32_soc #(
  parameter RESET_PC = 32'h0000_0000,
  parameter ITCM_WORDS = 4096,
  parameter ITCM_ADDR_WIDTH = 14,
  parameter DTCM_WORDS = 4096,
  parameter DTCM_ADDR_WIDTH = 14,
  // 领航者全板只有 3 个 PL LED（H15/L15/J16），所以是 3 不是 4。
  parameter LED_WIDTH = 3,
  parameter DAS_ACTIVE_CHANNELS = 8,
  parameter PDM_CHANNELS = DAS_ACTIVE_CHANNELS == 4 ? 8 : 2*((DAS_ACTIVE_CHANNELS+1)/2),
  parameter ALGORITHM_CHANNELS = DAS_ACTIVE_CHANNELS == 4 ? 8 : DAS_ACTIVE_CHANNELS,
  parameter [PDM_CHANNELS-1:0] PDM_ACTIVE_MASK = DAS_ACTIVE_CHANNELS == 9 ? 10'h1ff : {PDM_CHANNELS{1'b1}},
  parameter LIVE16_LOCALIZATION = DAS_ACTIVE_CHANNELS >= 8,
  parameter ACOU_LANES = (DAS_ACTIVE_CHANNELS == 8 || DAS_ACTIVE_CHANNELS == 9 || DAS_ACTIVE_CHANNELS == 12) ? 4 : 8,
  parameter PDM_MICS_PER_LINE = DAS_ACTIVE_CHANNELS >= 8 ? 2 : 1,
  parameter PDM_DECIM = DAS_ACTIVE_CHANNELS == 9 ? 16 : 64,
  parameter LOCALIZER_HOP = 512,
  parameter LOCALIZER_R_LEN = DAS_ACTIVE_CHANNELS == 9 ? 64 : 32,
  parameter LOCALIZER_BIN_LO = DAS_ACTIVE_CHANNELS == 9 ? 2 : 6,
  parameter LOCALIZER_BIN_COUNT = DAS_ACTIVE_CHANNELS == 9 ? 64 : 208,
  parameter LOCALIZER_BAND_LAST = DAS_ACTIVE_CHANNELS == 9 ? 50 : 203,
  parameter ITCM_FILE = "",
  parameter DTCM_FILE = "",
  parameter LOCALIZER_ACCEL = DAS_ACTIVE_CHANNELS == 8 || DAS_ACTIVE_CHANNELS == 9 || DAS_ACTIVE_CHANNELS == 12,
  parameter LOCALIZER_RESULT_OFFSET = (DAS_ACTIVE_CHANNELS == 8 || DAS_ACTIVE_CHANNELS == 9) ? 0 : 393216
) (
  input         clk_i,
  input         rst_n_i,
  // Reserved internal stream boundary for future PS DMA integration.
  input gsc_ready_i,output gsc_valid_o,output [511:0] gsc_data_o,
  output [63:0] gsc_timestamp_o,
  output [31:0] gsc_overflow_o,gsc_alignment_errors_o,
`ifdef LOCALIZER_PCM_TEST
  input [PDM_CHANNELS*24-1:0] test_pcm_i,input test_pcm_valid_i,input [31:0] test_sample_id_i,
`endif
  input         test_en_i,
  input         halt_i,
  output        retire_valid_o,
  output [31:0] retire_pc_o,
  output [31:0] retire_instr_o,
  output [3:0]  retire_fault_o,
  // MMIO 邮箱：核侧 0x4000 写、0x4004 读。
  // tohost_we_o 与 tohost_o 同一拍有效（都是寄存器输出），上位机按 we 采样即可。
  output [31:0] tohost_o,
  output        tohost_we_o,
  input  [31:0] fromhost_i,
  // LED：固件写核侧 0x5000 就更新，读回同一地址拿到当前值。
  // 只支持整字 sw —— 核侧 store 数据是预移位的（rv32_lsu.v），sb/sh 会让字节落到
  // dmem_wdata 的高位，低 4 位恒 0。tohost 有同样的性质，两边行为一致。
  output [LED_WIDTH-1:0] led_o,
  // PS 侧 TCM 访问端口。每次请求只拉高 ps_req_i 一拍；ps_ready_o 在下一拍回，
  // 那时 ps_rdata_o 有效（读）。写在 ps_req_i 当拍直接生效。
  input         ps_req_i,
  input         ps_write_i,
  input         ps_sel_i,
  input  [31:0] ps_addr_i,
  input  [31:0] ps_wdata_i,
  output        ps_ready_o,
  output [31:0] ps_rdata_o,
  output        simd_active_o,
  // PS 侧阵列系数预装窗口（AXI 偏移 0x0C0–0x0CC，经 rv32_ps_regs 转成这条简单总线）。
  // 一个抽头一次，按**逻辑抽头号**寻址、Q15 进出；bank/word 的换算在 rv32_vec_unit 里。
  // 这是核里面那块存储的第二个端口，不是第二份硬件。
  input         coef_we_i,
  input         coef_re_i,
  input         coef_src_i,
  input         coef_ch_i,
  input  [8:0]  coef_idx_i,
  input  [15:0] coef_wdata_i,
  output [15:0] coef_rdata_o,
  // 转速脉冲。引脚约束在 R18 = J3.25（ps_pl_wrapper.xdc，开漏输入用 PULLUP）。
  // ⚠ 原来它只喂音频观测器当时标；那条 I2S 通路 2026-10-06 整体移除后，SoC 内部
  //   **暂时没有消费者** —— 端口留着是因为 docs/board_io.md 的 PDM 排线计划明确
  //   沿用这根脚当转速输入，等诊断侧真要用时再接。
  input         tacho_i,
  // Eight PDM microphones, one DIN per microphone; J3 pinout in board_io.md.
  output        pdm_clk_o,
  input  [PDM_CHANNELS/PDM_MICS_PER_LINE-1:0] pdm_din_i,
  // PDM 采集窗口（AXI 0x300–0x3FF，经 rv32_ps_regs 转成这条简单总线）。
  // Raw capture 0x300..0x37f, audio FIFO 0x380..0x3ff; core raw mirror 0xC000.
  input         pdm_cfg_wr_i,
  input         pdm_cfg_rd_i,
  input  [6:0]  pdm_cfg_addr_i,
  input  [31:0] pdm_cfg_wdata_i,
  output [31:0] pdm_cfg_rdata_o,
  // 定位加速器的 PS 侧窗口（SRP 走 AXI 0x400，互谱+PHAT 走 0x500，经 rv32_ps_regs
  // 转成这条简单总线）。与核侧的 MMIO 页 0x8000 / 0x9000 是**同一组寄存器**的
  // 两个端口，不是两份硬件 —— 同音频/ANC 的规矩。
  input         srp_cfg_wr_i,
  input         srp_cfg_rd_i,
  input  [6:0]  srp_cfg_addr_i,
  input  [31:0] srp_cfg_wdata_i,
  output [31:0] srp_cfg_rdata_o,
  input         xsp_cfg_wr_i,
  input         xsp_cfg_rd_i,
  input  [6:0]  xsp_cfg_addr_i,
  input  [31:0] xsp_cfg_wdata_i,
  output [31:0] xsp_cfg_rdata_o,
  // 波束转向块的 PS 侧窗口（AXI 0x600，经 rv32_ps_regs 转成这条简单总线）。
  // 与核侧的 MMIO 页 0xA000 是**同一组寄存器**的两个端口 —— 同 SRP/XSP。
  input         steer_cfg_wr_i,
  input         steer_cfg_rd_i,
  input  [6:0]  steer_cfg_addr_i,
  input  [31:0] steer_cfg_wdata_i,
  output [31:0] steer_cfg_rdata_o
);

  wire imem_req;
  wire [31:0] imem_addr;
  wire imem_ready;
  wire [31:0] imem_rdata;
  wire dmem_req;
  wire dmem_write;
  wire [31:0] dmem_addr;
  wire [31:0] dmem_wdata;
  wire [3:0] dmem_wstrb;
  wire dmem_ready;
  wire [31:0] dmem_rdata;
  wire dtcm_ready;
  wire [31:0] dtcm_rdata;

  wire [3:0]  ps_wstrb;
  // 定位加速器：门铃从核出来（SoC 内部线，**不出顶层**），忙信号并进 simd_active。
  wire        core_srp_start, core_xsp_start, core_steer_start;
  wire        core_simd_active;
  wire        srp_busy, xsp_busy, steer_busy;
  wire [31:0] srp_core_rdata, xsp_core_rdata, steer_core_rdata;
  wire itcm_ps_ready;
  wire [31:0] itcm_ps_rdata;
  wire dtcm_ps_ready;
  wire [31:0] dtcm_ps_rdata;

  // ── MMIO 译码 ─────────────────────────────────────────────────────────────
  // 把 0x4000–0x4FFF（邮箱）、0x5000–0x5FFF（GPIO/LED）两整页从 DTCM 手里摘出来。
  // 译码必须在 SoC 层做：核边界上 dmem_addr 已是完整 32 位地址，核内没有任何地址比较。
  //
  // 不变式（比它看上去弱，改 DTCM 前务必读完）：MMIO 页基址必须 ≥ 2^DTCM_ADDR_WIDTH，
  // 而且**只有 ≥ 0x8000 才是长期安全的**。DTCM 忽略 addr[31:DTCM_ADDR_WIDTH]，落在它
  // 别名窗口里的页会被同时命中；16KB 的 DTCM 覆盖 0x0000–0x3FFF，所以现在 0x4000 起
  // 才没事。但 DTCM 一旦扩到 32KB，ADDR_WIDTH 变 15、窗口变成 0x0000–0x7FFF，
  // 0x4000 / 0x5000 两页会**同时**落进别名窗口 —— 那时这两页必须一起搬，
  // 漏搬任意一页都是静默错。
  //
  // 页限定必须写全。mmio_tohost 从前是裸的偏移比较，只靠 mmio_write 传递限定；
  // 多一页之后若照旧只比偏移，写 0x5000 会同时命中 tohost —— 灯亮了，还顺手把
  // 「程序结束」打给 PS（DONE + 中断）。这种错不报错、只是静默错，所以每项都显式带页。
  localparam [19:0] MMIO_PAGE_MBOX  = 20'h00004;   // 0x4000–0x4FFF
  localparam [19:0] MMIO_PAGE_GPIO  = 20'h00005;   // 0x5000–0x5FFF
  // 定位加速器两页。**取 0x8000 起不是随手挑的**：上面那条不变式要求页基址
  // ≥ 2^DTCM_ADDR_WIDTH，且只有 ≥ 0x8000 才在 DTCM 扩到 32KB 后仍然安全 ——
  // 0x4000–0x5000 那两页到时候必须一起搬，新页别再往那段里挤。
  localparam [19:0] MMIO_PAGE_SRP   = 20'h00008;   // 0x8000–0x8FFF
  localparam [19:0] MMIO_PAGE_XSP   = 20'h00009;   // 0x9000–0x9FFF
  localparam [19:0] MMIO_PAGE_STEER = 20'h0000A;   // 0xA000–0xAFFF（波束转向）
  localparam [19:0] MMIO_PAGE_CAPTURE = 20'h0000C;
  localparam [19:0] MMIO_PAGE_LOCALIZER = 20'h0000D;
  wire mmio_page_localizer=LOCALIZER_ACCEL&&(dmem_addr[31:12]==MMIO_PAGE_LOCALIZER);
  reg localizer_enable;
  reg localizer_srp_start_q;
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)localizer_srp_start_q<=0;
    else localizer_srp_start_q<=localizer_enable&&retire_valid_o&&
      retire_instr_o[6:0]==7'h2b&&retire_instr_o[14:12]==0;
  end
  wire loc_busy,loc_done,loc_fft_start,loc_fft_inv,loc_fft_pop,loc_fft_seek,loc_fft_ready,loc_fft_done;
  wire loc_ac_start,loc_ac_ready,loc_ac_done,loc_r_we,loc_srp_done;
  wire [1:0] loc_ac_sel;
  wire [2:0] loc_request;
  wire [31:0] loc_fft_data,loc_fft_result,loc_ac_data,loc_ac_result,loc_request_id;
  wire [31:0] loc_window,loc_first,loc_latency,loc_raw_drop,loc_window_drop;
  wire [31:0] loc_compute_cycles;
  wire [31:0] loc_score,loc_srp_score;
  wire [16:0] loc_r_addr;
  wire [15:0] loc_r_data;
  wire [9:0] loc_grid,loc_score_addr;
  reg test_direction_enable;
  reg auto_recovery_enable;
  wire recovery_request=(mmio_write&&mmio_page_localizer&&mmio_offset==12'd48&&dmem_wdata==32'h52454152)||
    (pdm_cfg_wr_i&&pdm_cfg_addr_i==7'd50&&pdm_cfg_wdata_i==32'h52454152);
  wire rearm,recovery_rearm;
  reg pause_rearm;
  assign rearm=recovery_rearm|pause_rearm;
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)pause_rearm<=0;
    else pause_rearm<=mmio_write&&mmio_page_localizer&&mmio_offset==12'd92&&
      dmem_wdata==32'h52535438&&!localizer_enable&&!loc_busy&&!loc_fault&&
      recovery_state==0&&!srp_busy&&!steer_busy;
  end
  wire [2:0] recovery_state;
  wire [31:0] recovery_epoch,fault_events,total_raw_drop,total_window_drop,first_fault_sample,gap_end_sample;
  wire loc_fault=loc_raw_drop!=0||loc_window_drop!=0;
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)begin test_direction_enable<=0;auto_recovery_enable<=0;end
    else if(pdm_cfg_wr_i&&pdm_cfg_addr_i==7'd50&&pdm_cfg_wdata_i!=32'h52454152)begin
      if(pdm_cfg_wdata_i==32'h41555431)auto_recovery_enable<=1; // AUT1, explicit opt-in, max three attempts
      else if(pdm_cfg_wdata_i==0)begin test_direction_enable<=0;auto_recovery_enable<=0;end
      else test_direction_enable<=pdm_cfg_wdata_i==32'h53494d31; // SIM1 is TEST_ONLY
    end
  end
  rv32_localizer_recovery u_recovery(.clk_i(clk_i),.rst_n_i(rst_n_i),.fault_i(loc_fault),
    .request_i(recovery_request),.auto_enable_i(auto_recovery_enable),.engines_idle_i(!core_simd_active&&!srp_busy&&!xsp_busy&&!steer_busy),
    .window_done_i(loc_done),.sample_seq_i(pdm_frame_cnt),.raw_drop_i(loc_raw_drop),.window_drop_i(loc_window_drop),
    .rearm_o(recovery_rearm),.state_o(recovery_state),.epoch_o(recovery_epoch),.fault_events_o(fault_events),
    .total_raw_drop_o(total_raw_drop),.total_window_drop_o(total_window_drop),
    .first_fault_sample_o(first_fault_sample),.gap_end_sample_o(gap_end_sample));
  reg [31:0] loc_rdata;
  // One clock domain for acquisition timestamps and PS receipt measurements.
  reg [31:0] acquisition_clock,anchor_clock,anchor_sample,previous_pcm_id;
  reg have_pcm_anchor;
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)begin acquisition_clock<=0;anchor_clock<=0;anchor_sample<=0;previous_pcm_id<=0;have_pcm_anchor<=0;end
    else begin
      acquisition_clock<=acquisition_clock+1;
      if(pdm_valid_aligned)begin
        if(!have_pcm_anchor||pdm_frame_cnt!=previous_pcm_id+1)begin
          anchor_clock<=acquisition_clock;anchor_sample<=pdm_frame_cnt;have_pcm_anchor<=1;
        end
        previous_pcm_id<=pdm_frame_cnt;
      end
    end
  end
  reg [5:0] loc_statistics_index;
  reg [9:0] loc_cpu_score_index;
  reg loc_score_autoincrement;
  wire [31:0] loc_statistics_data;
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)begin loc_statistics_index<=0;loc_cpu_score_index<=0;loc_score_autoincrement<=0;end
    else if(mmio_write&&mmio_page_localizer)begin
      if(mmio_offset==12'd76)loc_statistics_index<=dmem_wdata[5:0];
      if(mmio_offset==12'd84)begin loc_cpu_score_index<=dmem_wdata[9:0];loc_score_autoincrement<=DAS_ACTIVE_CHANNELS==9&&dmem_wdata[31];end
    end
    else if(mmio_read&&!mmio_ack_q&&mmio_page_localizer&&mmio_offset==12'd88&&loc_score_autoincrement&&!loc_busy)
      loc_cpu_score_index<=loc_cpu_score_index+1'b1;
  end
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)localizer_enable<=0;
    // Explicit test mode only until physical geometry is available.
    else if(mmio_write&&mmio_page_localizer&&mmio_offset==0)
      localizer_enable<=dmem_wdata[31]&&dmem_wdata[0]&&LOCALIZER_ACCEL;
  end
  always @*case(mmio_offset[7:2])
    0:loc_rdata={localizer_enable,30'b0,localizer_enable};
    1:loc_rdata={28'b0,loc_request,loc_busy};
    2:loc_rdata=loc_request_id;
    3:loc_rdata=loc_window;
    4:loc_rdata=loc_first;
    5:loc_rdata=loc_latency;
    6:loc_rdata=loc_raw_drop;
    7:loc_rdata=loc_window_drop;
    8:loc_rdata={22'b0,loc_grid};
    9:loc_rdata=loc_score;
    10:loc_rdata=32'h4c4f4301;
    11:loc_rdata=loc_compute_cycles;
    12:loc_rdata={29'b0,recovery_state};
    13:loc_rdata=recovery_epoch;
    14:loc_rdata=fault_events;
    15:loc_rdata=total_raw_drop+loc_raw_drop;
    16:loc_rdata=total_window_drop+loc_window_drop;
    17:loc_rdata=first_fault_sample;
    18:loc_rdata=gap_end_sample;
    19:loc_rdata={26'b0,loc_statistics_index};
    20:loc_rdata=loc_statistics_data;
    21:loc_rdata={loc_score_autoincrement,21'b0,loc_cpu_score_index};
    22:loc_rdata=loc_srp_score;
    24:loc_rdata=!LOCALIZER_ACCEL?0:DAS_ACTIVE_CHANNELS==9?32'h50394432:DAS_ACTIVE_CHANNELS==8?32'h50384f31:0;
    27:loc_rdata=acquisition_clock;
    28:loc_rdata=anchor_clock;
    29:loc_rdata=anchor_sample;
    31:loc_rdata={31'b0,direction_approved};
    default:loc_rdata=0;
  endcase
  wire mmio_page_capture;
  wire [11:0] mmio_offset;
  wire        mmio_page_mbox;
  wire        mmio_page_gpio;
  wire        mmio_page_srp;
  wire        mmio_page_xsp;
  wire        mmio_page_steer;
  wire        dmem_mmio;
  wire        mmio_tohost;
  wire        mmio_fromhost;
  wire        mmio_gpio;
  wire        mmio_srp_win;
  wire        mmio_xsp_win;
  wire        mmio_steer_win;
  wire        mmio_write;
  wire        mmio_read;
  wire        dtcm_req;
  wire [31:0] mmio_rdata;

  assign mmio_page_capture = (dmem_addr[31:12] == MMIO_PAGE_CAPTURE);
  assign mmio_offset     = dmem_addr[11:0];
  assign mmio_page_mbox  = (dmem_addr[31:12] == MMIO_PAGE_MBOX);
  assign mmio_page_gpio  = (dmem_addr[31:12] == MMIO_PAGE_GPIO);
  assign mmio_page_srp   = (dmem_addr[31:12] == MMIO_PAGE_SRP);
  assign mmio_page_xsp   = (dmem_addr[31:12] == MMIO_PAGE_XSP);
  assign mmio_page_steer = (dmem_addr[31:12] == MMIO_PAGE_STEER);
  assign dmem_mmio       = dmem_req & (mmio_page_mbox | mmio_page_gpio |
                                       mmio_page_srp | mmio_page_xsp |
                                       mmio_page_steer | mmio_page_capture | mmio_page_localizer);
  assign mmio_tohost    = mmio_page_mbox & (mmio_offset == 12'h000);
  assign mmio_fromhost  = mmio_page_mbox & (mmio_offset == 12'h004);
  assign mmio_gpio      = mmio_page_gpio & (mmio_offset == 12'h000);
  // 三个定位/转向块各占 8 个字（32 字节），所以窗口按 offset[11:5] 限。
  assign mmio_srp_win   = mmio_page_srp & (mmio_offset[11:5] == 6'b000000);
  assign mmio_xsp_win   = mmio_page_xsp & (mmio_offset[11:5] == 6'b000000);
  assign mmio_steer_win = mmio_page_steer & (mmio_offset[11:5] == 6'b000000);
  assign mmio_write     = dmem_mmio & dmem_write;
  assign mmio_read      = dmem_mmio & ~dmem_write;

  // 摘掉 MMIO 三页再送 DTCM：不摘的话 0x4000 会被 DTCM 别名成 word 0 一起写掉。
  // 未译码的 MMIO 地址照样回 ready —— 否则核等不到应答会永久挂死。
  wire scratch_sel = LIVE16_LOCALIZATION && dmem_addr[31:16] == 16'h0001;
  wire scratch_ready; wire [31:0] scratch_rdata;
  assign dtcm_req = dmem_req & ~dmem_mmio & ~scratch_sel;
  generate if (LIVE16_LOCALIZATION) begin : g_live16_scratch
    rv32_dtcm #(.WORDS(16384), .ADDR_WIDTH(16)) u_ram (
      .clk_i(clk_i),.rst_n_i(rst_n_i),.req_i(dmem_req & scratch_sel),
      .write_i(dmem_write),.addr_i(dmem_addr[15:0]),.wdata_i(dmem_wdata),.wstrb_i(dmem_wstrb),
      .ready_o(scratch_ready),.rdata_o(scratch_rdata),
      .ps_req_i(1'b0),.ps_write_i(1'b0),.ps_addr_i(16'b0),.ps_wdata_i(32'b0),
      .ps_wstrb_i(4'b0),.ps_ready_o(),.ps_rdata_o());
  end else begin : g_no_scratch
    assign scratch_ready=1'b0; assign scratch_rdata=32'b0;
  end endgenerate

  // ── MMIO 的回答**打一拍**（2026-10-04 改）────────────────────────────────
  // 原来写的是 `dmem_ready = dmem_mmio ? 1'b1 : dtcm_ready` —— MMIO **同拍组合应答**。
  // 那让整个存储器接口成了一条**出核再回来的组合闭环**，实测是全设计最差路径：
  //     payload → LSU → dmem_req → mmio 页译码 → dmem_write/mmio_read
  //             → 外设读数据 mux → dmem_rdata → 回 payload
  //   34 级 / 25.404 ns，**布线占 56%**（docs/issues/057）。
  //
  // ⚠ 这里原来那条注释写着「不能靠打拍解决：打一拍会返回陈旧数据」——
  //   **只对了一半**。单独给读数据打拍确实陈旧；但**同时把应答也推迟一拍**，
  //   核会 `memory_stall` 冻住 EX/MEM、**地址一直保持**，外设的组合读数据
  //   在应答那一拍**依然有效**，根本不陈旧。**DTCM 一直就是这么工作的**
  //   （`ready_q <= req & ~ready_q`），MMIO 只是没跟上。
  // 代价：每次 MMIO 访问由 1 拍变 2 拍（与 DTCM 口径一致）。核的 stall 机制本来就支持。
  reg mmio_ack_q;
  reg [31:0] mmio_rdata_q;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      mmio_ack_q   <= 1'b0;
      mmio_rdata_q <= 32'b0;
    end else begin
      // ⚠ 必须 `& ~mmio_ack_q` —— 应答是**一次性的脉冲**，不是"请求的延迟"。
      //   写成 `mmio_ack_q <= dmem_mmio` 的话，上一笔 MMIO 的 ack 会**漏进下一笔的
      //   请求拍**：紧随其后的那条 lw 在第一拍就被判为"已应答"，而它的读数据是
      //   **请求拍之后**才采的 ⇒ 读到上一笔留下的 0。
      //   实测指纹：`sw 到 MMIO` 紧跟 `lw 同一地址`，写进去的值回读成 0
      //   （tb_rv32_ps 的 "DTCM[1] == firmware readback of LED"）。
      //   DTCM 一直是 `ready_q <= req & ~ready_q`，MMIO 照抄即可。
      mmio_ack_q   <= dmem_mmio & ~mmio_ack_q;
      mmio_rdata_q <= mmio_rdata;      // **请求那一拍**把读数据采下来
    end
  end
  assign dmem_ready   = dmem_mmio ? mmio_ack_q : scratch_sel ? scratch_ready : dtcm_ready;
  // ⚠ 读数据必须用**采下来的那一份**（`mmio_rdata_q`），不能直接用组合的
  //   `mmio_rdata`：外设的状态寄存器可能**每拍都在变**，隔一拍再读就真的陈旧了。
  //   在请求那一拍采样，核拿到的就正好是它请求时的值，各路外设一致。
  assign dmem_rdata   = dmem_mmio ? mmio_rdata_q : scratch_sel ? scratch_rdata : dtcm_rdata;
  // 读回各路，每路都有落点（漏默认值会推成 latch）。led_q 是无符号寄存器，
  // 赋进 32 位分支自动零扩展，不需要再写位宽拼接。
  assign mmio_rdata   = mmio_read ? (mmio_fromhost ? fromhost_i :
                                     mmio_gpio     ? led_q :
                                     mmio_srp_win  ? srp_core_rdata :
                                     mmio_xsp_win  ? xsp_core_rdata :
                                     mmio_steer_win ? steer_core_rdata :
                                     mmio_page_capture ? pdm_capture_rdata :
                                     mmio_page_localizer ? loc_rdata :32'b0) : 32'b0;

  // 写按 dmem_write（它已经被核侧用 & dmem_ready_i 限定过），不重复门控。
  // 两个 MMIO 写寄存器共用一个块：都是 mmio_write 的从属，复位行为也一致。
  // led_q 落在软复位域里 —— rv32_ps_top 把 soft_rst 并进了 SoC 的 rst_n_i，
  // 所以 PS 写 CTRL.SOFT_RST 会把灯灭掉，这是有意的（软复位就是复位整个 SoC）。
  reg [31:0]          tohost_q;
  reg                 tohost_we_q;
  reg [LED_WIDTH-1:0] led_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      tohost_q    <= 32'b0;
      tohost_we_q <= 1'b0;
      led_q       <= {LED_WIDTH{1'b0}};
    end else begin
      // we 打一拍再输出，和 tohost_q 对齐：核写进去的值在下一拍才采得到。
      tohost_we_q <= mmio_write & mmio_tohost;
      if (mmio_write & mmio_tohost) begin
        tohost_q <= dmem_wdata;
      end
      if (mmio_write & mmio_gpio) begin
        led_q <= dmem_wdata[LED_WIDTH-1:0];
      end
    end
  end

  assign tohost_o    = tohost_q;
  assign tohost_we_o = tohost_we_q;
  assign led_o       = led_q;

  rv32_core #(.RESET_PC(RESET_PC), .AUDIO_STREAM(1), .ACOU_LANES(ACOU_LANES),
    .ACOU_CACHE_N(LOCALIZER_BIN_COUNT),.ACOU_BAND_HI(LOCALIZER_BAND_LAST),
    .FFT_SPARSE_LO(DAS_ACTIVE_CHANNELS==9?LOCALIZER_BIN_LO:0),
    .FFT_SPARSE_COUNT(DAS_ACTIVE_CHANNELS==9?LOCALIZER_BIN_COUNT:513),.LOCAL_TRANSFER(LOCALIZER_ACCEL)) u_core (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .test_en_i      (test_en_i),
    .halt_i         (halt_i),
    .imem_req_o     (imem_req),
    .imem_addr_o    (imem_addr),
    .imem_ready_i   (imem_ready),
    .imem_rdata_i   (imem_rdata),
    .dmem_req_o     (dmem_req),
    .dmem_write_o   (dmem_write),
    .dmem_addr_o    (dmem_addr),
    .dmem_wdata_o   (dmem_wdata),
    .dmem_wstrb_o   (dmem_wstrb),
    .dmem_ready_i   (dmem_ready),
    .dmem_rdata_i   (dmem_rdata),
    .retire_valid_o (retire_valid_o),
    .retire_pc_o    (retire_pc_o),
    .retire_instr_o (retire_instr_o),
    .retire_fault_o (retire_fault_o),
    .coef_we_i      (coef_we_i),
    .coef_re_i      (coef_re_i),
    .coef_src_i     (coef_src_i),
    .coef_ch_i      (coef_ch_i),
    .coef_idx_i     (coef_idx_i),
    .coef_wdata_i   (coef_wdata_i),
    .simd_active_o  (core_simd_active),
    .coef_rdata_o   (coef_rdata_o),
    .srp_start_o    (core_srp_start),
    .xsp_start_o    (core_xsp_start),
    .steer_start_o  (core_steer_start),
    .audio_valid_i(beam_fir_valid), .audio_sample_i(beam_fir_sample),
    .audio_ready_o(beam_fir_ready), .audio_done_o(beam_fir_done), .audio_result_o(beam_fir_result),
    .transfer_enable_i(localizer_enable),.transfer_request_i(loc_request),
    .transfer_fft_start_i(loc_fft_start),.transfer_fft_inv_i(loc_fft_inv),
    .transfer_fft_pop_i(loc_fft_pop),.transfer_fft_seek_i(loc_fft_seek),.transfer_fft_data_i(loc_fft_data),
    .transfer_fft_ready_o(loc_fft_ready),.transfer_fft_done_o(loc_fft_done),.transfer_fft_result_o(loc_fft_result),
    .transfer_ac_start_i(loc_ac_start),.transfer_ac_sel_i(loc_ac_sel),.transfer_ac_data_i(loc_ac_data),
    .transfer_ac_ready_o(loc_ac_ready),.transfer_ac_done_o(loc_ac_done),.transfer_ac_result_o(loc_ac_result)
  );

  // ITCM 是同步读（BRAM 风格）：req 与地址本拍采样，rdata/ready 下一拍返回。
  // 取指级送来的 imem_addr 已经是"下一拍的 PC"，两边时钟沿对齐，无需额外打拍。
  rv32_itcm #(
    .WORDS      (ITCM_WORDS),
    .ADDR_WIDTH (ITCM_ADDR_WIDTH),
    .MEM_FILE   (ITCM_FILE)
  ) u_itcm (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .req_i       (imem_req),
    .addr_i      (imem_addr[ITCM_ADDR_WIDTH-1:0]),
    .ready_o     (imem_ready),
    .rdata_o     (imem_rdata),
    .ps_req_i    (ps_req_i & ~ps_sel_i),
    .ps_write_i  (ps_write_i),
    .ps_addr_i   (ps_addr_i[ITCM_ADDR_WIDTH-1:0]),
    .ps_wdata_i  (ps_wdata_i),
    .ps_wstrb_i  (ps_wstrb),
    .ps_ready_o  (itcm_ps_ready),
    .ps_rdata_o  (itcm_ps_rdata)
  );

  // DTCM 也是同步读，但访问是"电平请求 + 隔拍应答"：一个操作占两拍，第 2 拍 ready
  // 拉高、rdata 同时有效，写也只在那一拍生效（见 rv32_dtcm.v 头部）。
  rv32_dtcm #(
    .WORDS      (DTCM_WORDS),
    .ADDR_WIDTH (DTCM_ADDR_WIDTH),
    .MEM_FILE   (DTCM_FILE)
  ) u_dtcm (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .req_i       (dtcm_req),
    .write_i     (dmem_write),
    .addr_i      (dmem_addr[DTCM_ADDR_WIDTH-1:0]),
    .wdata_i     (dmem_wdata),
    .wstrb_i     (dmem_wstrb),
    .ready_o     (dtcm_ready),
    .rdata_o     (dtcm_rdata),
    .ps_req_i    (ps_req_i & ps_sel_i),
    .ps_write_i  (ps_write_i),
    .ps_addr_i   (ps_addr_i[DTCM_ADDR_WIDTH-1:0]),
    .ps_wdata_i  (ps_wdata_i),
    .ps_wstrb_i  (ps_wstrb),
    .ps_ready_o  (dtcm_ps_ready),
    .ps_rdata_o  (dtcm_ps_rdata)
  );

  // PS 端口全是整字访问，字节使能常开。两口都是 req 后一拍出 ready，所以可以直接并
  // 成一路：ps_sel_i 在请求当拍就选定了块，ready/rdata 回来时选择信号还在。
  assign ps_wstrb  = 4'hF;
  assign ps_ready_o = ps_sel_i ? dtcm_ps_ready : itcm_ps_ready;
  assign ps_rdata_o = ps_sel_i ? dtcm_ps_rdata : itcm_ps_rdata;

  // Production: twelve microphones on six DINs; fs = clk/1024 = 39.0625 kHz.
  // Aligned PCM feeds the continuous DAS/SIMD FIR and the dual-bank raw snapshot.
  // fw_live owns snapshots through core MMIO 0xC000; PS consumes audio at 0x380.
  // Unity gain is Q2.14 16384; zero would mute the chain (docs/issues/029).
  wire beam_fir_valid, beam_fir_ready, beam_fir_done;
  wire [15:0] beam_fir_sample, beam_fir_result;
  wire [ALGORITHM_CHANNELS*32-1:0] beam_comp;
  wire beam_locked;
  wire link_start,direction_valid,direction_ready,direction_applied;
  wire [9:0] link_target,committed_grid,direction_id,applied_direction_id;
  wire [ALGORITHM_CHANNELS*32-1:0] direction_comp;
  wire [31:0] direction_version,link_rejected,applied_version,effective_sample,audio_sample_seq,group_delay;
  wire direction_transition,direction_trusted;
  // Circular9: only the RV32 quality-approved commit can mark a direction trusted.
  // LOC[25] commits the already-computed steering bank; LOC[26] revokes trust.
  wire circular9_direction=DAS_ACTIVE_CHANNELS==9;
  reg direction_approved,approved_pulse;
  reg [31:0] approved_version,approved_first_clock;
  always @(posedge clk_i or negedge rst_n_i)begin
    if(!rst_n_i)begin direction_approved<=0;approved_pulse<=0;approved_version<=0;approved_first_clock<=0;end
    else begin
      approved_pulse<=0;
      // A 10 ms first-receipt deadline differs from holding the accepted result
      // until the next overlapping window. Give that window one hop + 100 us.
      if(circular9_direction&&direction_approved&&(acquisition_clock-approved_first_clock)>(400000+LOCALIZER_HOP*256+4000))direction_approved<=0;
      if(loc_fault||recovery_state!=0)direction_approved<=0;
      else if(circular9_direction&&mmio_write&&mmio_page_localizer)begin
        if(mmio_offset==12'd120)approved_first_clock<=dmem_wdata;
        if(mmio_offset==12'd104)direction_approved<=0;
        if(mmio_offset==12'd100&&beam_locked&&!steer_busy&&(acquisition_clock-approved_first_clock)<400000)begin
          direction_approved<=1;approved_pulse<=1;approved_version<=dmem_wdata;
        end
      end
    end
  end
  wire production_direction_fault=loc_fault||recovery_state!=0||(circular9_direction&&!direction_approved);
  rv32_direction_link #(.CHANNELS(ALGORITHM_CHANNELS),.COMMITTED_ONLY(DAS_ACTIVE_CHANNELS==9)) u_direction_link(
    .clk_i(clk_i),.rst_n_i(rst_n_i),.enable_i(circular9_direction||test_direction_enable),.fault_i(production_direction_fault),
    .result_valid_i(circular9_direction?approved_pulse:loc_done),
    .result_grid_i(circular9_direction?committed_grid:loc_grid),
    .result_version_i(circular9_direction?approved_version:loc_window),.result_score_i($signed(loc_score)),
    .steer_busy_i(steer_busy),.steer_locked_i(beam_locked),
    .steer_bus_idle_i(!mmio_steer_win&&!steer_cfg_wr_i&&!steer_cfg_rd_i&&!core_steer_start),
    .steer_committed_i(committed_grid),.steer_comp_i(beam_comp),
    .steer_start_o(link_start),.steer_target_o(link_target),.direction_valid_o(direction_valid),.direction_ready_i(direction_ready),
    .direction_comp_o(direction_comp),.direction_id_o(direction_id),.direction_version_o(direction_version),.rejected_o(link_rejected));
  wire [31:0] pdm_capture_rdata, beam_rdata;
  reg [31:0] integrated_rdata;
  always @*case(pdm_cfg_addr_i[4:0])
    18:integrated_rdata={27'b0,auto_recovery_enable,recovery_state,test_direction_enable};
    19:integrated_rdata=applied_version;
    20:integrated_rdata=effective_sample;
    21:integrated_rdata=group_delay;
    22:integrated_rdata=recovery_epoch;
    23:integrated_rdata=link_rejected;
    24:integrated_rdata=acquisition_clock;
    25:integrated_rdata=PDM_DECIM;
    26:integrated_rdata=LOCALIZER_HOP;
    27:integrated_rdata=LOCALIZER_R_LEN;
    default:integrated_rdata=0;
  endcase
  wire integrated_page=pdm_cfg_addr_i[5]&&pdm_cfg_addr_i[4:0]>=18&&pdm_cfg_addr_i[4:0]<=27;
  assign pdm_cfg_rdata_o = integrated_page?integrated_rdata:pdm_cfg_addr_i[5] ? beam_rdata : pdm_capture_rdata;
  rv32_das_stream #(.ACTIVE_CHANNELS(DAS_ACTIVE_CHANNELS)) u_beam (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .pcm_i(pdm_aligned[ALGORITHM_CHANNELS*24-1:0]), .valid_i(pdm_valid_aligned),
    .steer_comp_i(beam_comp), .steer_locked_i(beam_locked), .steer_busy_i(steer_busy),
    .cfg_wr_i(pdm_cfg_wr_i & pdm_cfg_addr_i[5] & !integrated_page),
    .cfg_rd_i(pdm_cfg_rd_i & pdm_cfg_addr_i[5] & !integrated_page),
    .cfg_addr_i(pdm_cfg_addr_i[4:0]), .cfg_wdata_i(pdm_cfg_wdata_i),
    .cfg_rdata_o(beam_rdata), .fir_valid_o(beam_fir_valid),
    .fir_sample_o(beam_fir_sample), .fir_ready_i(beam_fir_ready),
    .fir_done_i(beam_fir_done), .fir_result_i(beam_fir_result),
    .link_enable_i(circular9_direction||test_direction_enable),.direction_fault_i(production_direction_fault),
    .direction_valid_i(direction_valid),.direction_comp_i(direction_comp),
    .direction_version_i(direction_version),.direction_id_i(direction_id),.sample_seq_i(pdm_frame_cnt),
    .direction_ready_o(direction_ready),.direction_applied_o(direction_applied),
    .direction_version_o(applied_version),.direction_id_o(applied_direction_id),
    .effective_sample_seq_o(effective_sample),.audio_sample_seq_o(audio_sample_seq),
    .group_delay_q16_o(group_delay),.transitioning_o(direction_transition),.direction_trusted_o(direction_trusted)
  );
  wire [191:0] gsc_pcm;
  generate if(PDM_CHANNELS==12||DAS_ACTIVE_CHANNELS==9)begin:g_gsc
    genvar gc;
    for(gc=0;gc<12;gc=gc+1)begin:g_pcm
      if(gc<ALGORITHM_CHANNELS)assign gsc_pcm[gc*16+:16]=pdm_aligned[gc*24+8+:16];
      else assign gsc_pcm[gc*16+:16]=0;
    end
    rv32_gsc_tap #(.ACTIVE_CHANNELS(ALGORITHM_CHANNELS)) u_tap(.clk_i(clk_i),.rst_n_i(rst_n_i),.raw_valid_i(pdm_valid_aligned),
      .raw_pcm_i(gsc_pcm),.raw_seq_i(pdm_frame_cnt),.beam_valid_i(beam_fir_done),.beam_seq_i(audio_sample_seq),
      .beam_i(beam_fir_sample),.fir_i(beam_fir_result),.direction_version_i(applied_version),.effective_seq_i(effective_sample),
      .window_id_i(loc_window),.group_delay_q16_i(group_delay),.recovery_epoch_i(recovery_epoch),.direction_id_i(applied_direction_id),
      .trusted_i(direction_trusted&&!production_direction_fault),.transition_i(direction_transition),
      .valid_o(gsc_valid_o),.ready_i(gsc_ready_i!==1'b0),.data_o(gsc_data_o),
      .timestamp_o(gsc_timestamp_o),
      .overflow_o(gsc_overflow_o),.alignment_errors_o(gsc_alignment_errors_o));
  end else begin:g_no_gsc
    assign gsc_pcm=0;assign gsc_valid_o=0;assign gsc_data_o=0;assign gsc_timestamp_o=0;assign gsc_overflow_o=0;assign gsc_alignment_errors_o=0;
  end endgenerate
  wire         pdm_en;
  wire         pdm_valid_raw, pdm_valid_aligned;
  wire [PDM_CHANNELS-1:0] pdm_frozen;
  wire [31:0]  pdm_frame_cnt;
  wire [PDM_CHANNELS*24-1:0] pdm_raw;
  wire [PDM_CHANNELS*24-1:0] pdm_aligned;
  wire [PDM_CHANNELS*24-1:0] pdm_aligned_unmasked;
  genvar mask_ch;
  generate for(mask_ch=0;mask_ch<PDM_CHANNELS;mask_ch=mask_ch+1)begin:g_active_mask
    assign pdm_aligned[mask_ch*24+:24]=PDM_ACTIVE_MASK[mask_ch] ? pdm_aligned_unmasked[mask_ch*24+:24] : 24'b0;
  end endgenerate
  wire [PDM_CHANNELS*16-1:0] pdm_gain;

`ifdef LOCALIZER_PCM_TEST
  assign pdm_aligned_unmasked=test_pcm_i;
  assign pdm_valid_aligned=test_pcm_valid_i;
  assign pdm_frame_cnt=test_sample_id_i;
  assign pdm_raw=0;assign pdm_valid_raw=0;assign pdm_frozen=0;assign pdm_clk_o=0;
`else
  rv32_pdm_array_rx #(.N_CH(PDM_CHANNELS), .DECIM(PDM_DECIM), .ACTIVE_MASK(PDM_ACTIVE_MASK), .MICS_PER_LINE(PDM_MICS_PER_LINE)) u_pdm_rx (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .en_i           (pdm_en),
    .pdm_din_i      (pdm_din_i),
    .pdm_clk_o      (pdm_clk_o),
    .audio_vec_o    (pdm_raw),
    .sample_valid_o (pdm_valid_raw),
    .frame_cnt_o    (pdm_frame_cnt),
    .frozen_o       (pdm_frozen)
  );

  rv32_chan_align #(
    .N_CH  (PDM_CHANNELS),
    .IN_W  (24),
    .OUT_W (24)
  ) u_pdm_align (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .en_i        (pdm_en),
    .audio_vec_i (pdm_raw),
    .valid_i     (pdm_valid_raw),
    .gain_q_i    (pdm_gain),
    .audio_vec_o (pdm_aligned_unmasked),
    .valid_o     (pdm_valid_aligned)
  );
`endif

  wire capture_core = dmem_mmio & mmio_page_capture;
  rv32_pdm_capture #(
    .N_CH     (PDM_CHANNELS), .ACTIVE_MASK(PDM_ACTIVE_MASK),
    .IN_W     (24),
    .FRAME_AW (9)
  ) u_pdm_cap (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .audio_vec_i (pdm_aligned),
    .valid_i     (pdm_valid_aligned),
    .frame_cnt_i (pdm_frame_cnt),
    .frozen_i    (pdm_frozen),
    .cfg_wr_i    ((mmio_write & mmio_page_capture) | (pdm_cfg_wr_i & ~pdm_cfg_addr_i[5] & ~capture_core)),
    .cfg_rd_i    ((mmio_read & mmio_page_capture & ~mmio_ack_q) | (pdm_cfg_rd_i & ~pdm_cfg_addr_i[5] & ~capture_core)),
    .cfg_addr_i  (capture_core ? mmio_offset[8:2] : pdm_cfg_addr_i),
    .cfg_wdata_i (capture_core ? dmem_wdata : pdm_cfg_wdata_i),
    .cfg_rdata_o (pdm_capture_rdata),
    .en_o        (pdm_en),
    .gain_o      (pdm_gain)
  );

  // ── 定位加速器（两块）─────────────────────────────────────────────────────
  // 挂在这里而不是只在生成的裸 PL 顶层里：够得着 yosys 的 `hierarchy -top rv32_soc`，
  // 否则它们的 latch 会静默逃过 verify 第 6 项。
  //
  // 规模先按**固件同尺寸**（4 对 × 16×16 = 256 格）例化：与固件金标准
  // build/fw_srp_p.hex 同形，能做"固件(C) ↔ RTL(Verilog)"的跨实现逐位对照。
  // 参数化已留全尺寸（28 对 × 1024 格 ≈ 111 KB BRAM）：换过去只是改这两个参数，
  // 但必须先复跑实现量 WNS 与 tile 数 —— 全尺寸历史上是 +25 个 BRAM tile。
  //
  // ⚠⚠ 核侧**读**要带 `& ~mmio_ack_q`，**写**不能带 —— 两者不是一回事。
  //
  //   **读**：`mmio_read = dmem_mmio & ~dmem_write`，而 `dmem_write` 是应答同拍的
  //   （见 rv32_memory_stage.v：`dmem_write_o = ... & dmem_ready_i`），所以一次读
  //   访问里 `mmio_read` 在**请求拍和应答拍都是 1**。外壳的 ADDR/RDATA 窗口是
  //   **自增**的，不削成一拍的话每笔读走两步（读跳格），与"读即弹"那类窗口同一个坑。
  //   必须留 `& ~mmio_ack_q`。
  //
  //   **写**：`mmio_write = dmem_mmio & dmem_write` 本身就只有**应答那一拍**高
  //   （`dmem_write` 被 `& dmem_ready_i` 限定过），是一根干净的单拍选通。
  //   再加 `& ~mmio_ack_q` 就把它削成**零拍** —— 写全部静默丢掉。实测（2026-10-06，
  //   build/scratch/tb_mmio_steer.v，20 条指令 39 拍）：
  //       请求拍 wr=0 ack=0  -> 译码成读，core_rd_i 冒出**假读脉冲**
  //       应答拍 wr=1 ack=1  -> mmio_write=1 但被 ~mmio_ack_q 掐掉，core_wr_i=0
  //   壳收到 core_wr_i **0** 个 / core_rd_i 5 个 ⇒ 转向块永远配不上，§9 闭环锁不住。
  //   地址与数据在这一拍都仍然稳定（trace 逐拍打印过），所以直接去掉门控即可。
  //
  //   这笔账以前记成"读/写电平都持续两拍"，**对读成立、对写正好反了**。
  rv32_srp_regs #(
    .N_PAIR (LIVE16_LOCALIZATION ? ALGORITHM_CHANNELS*(ALGORITHM_CHANNELS-1)/2 : 4),
    .N_GRID (LIVE16_LOCALIZATION ? 1024 : 256),
    // R_LEN=1024 = NFFT：τ 绕回后 idx 能到 1000 以上，行只有 256 深就会读到
    // 下一对的行里去。**这个参数不是可选项**，见 rv32_srp_scan.v 的参数表那段。
    .R_LEN  (LIVE16_LOCALIZATION ? LOCALIZER_R_LEN : 1024),
    .IDX_W  (LIVE16_LOCALIZATION ? $clog2(LOCALIZER_R_LEN) : 10),
    .ADDR_W (LIVE16_LOCALIZATION ? 17 : 15), .GRID_IDX_W(10),
    .FRAC_W (4),
    .DW     (16),.FAST_SCAN(DAS_ACTIVE_CHANNELS==9&&LOCALIZER_ACCEL?4:LOCALIZER_ACCEL),.LOCAL_TRANSFER(LOCALIZER_ACCEL)
  ) u_srp (
    .clk_i        (clk_i),
    .rst_n_i      (rst_n_i),
    .core_start_i (localizer_enable?localizer_srp_start_q:core_srp_start),
    .core_wr_i    (mmio_write & mmio_srp_win),
    .core_rd_i    (mmio_read  & mmio_srp_win & ~mmio_ack_q),
    .core_addr_i  (mmio_offset[8:2]),
    .core_wdata_i (dmem_wdata),
    .core_rdata_o (srp_core_rdata),
    .ps_wr_i      (srp_cfg_wr_i),
    .ps_rd_i      (srp_cfg_rd_i),
    .ps_addr_i    (srp_cfg_addr_i),
    .ps_wdata_i   (srp_cfg_wdata_i),
    .ps_rdata_o   (srp_cfg_rdata_o),
    .busy_o       (srp_busy),
    .transfer_enable_i(localizer_enable),.transfer_r_we_i(loc_r_we),
    .transfer_r_addr_i(loc_r_addr),.transfer_r_data_i(loc_r_data),
    .transfer_p_addr_i(loc_busy?loc_score_addr:loc_cpu_score_index),.transfer_p_data_o(loc_srp_score),.transfer_done_o(loc_srp_done)
  );

  generate if(LOCALIZER_ACCEL)begin:g_localizer
    rv32_overlap_localizer #(.CHANNELS(ALGORITHM_CHANNELS),.CAPTURE_SLOTS(PDM_CHANNELS),
      .HOP_SAMPLES(LOCALIZER_HOP),.R_LEN(LOCALIZER_R_LEN),.BIN_LO(LOCALIZER_BIN_LO),
      .BIN_COUNT(LOCALIZER_BIN_COUNT),.BAND_LAST(LOCALIZER_BAND_LAST),
      .CPU_SCHEDULED(1),.RESULT_OFFSET(LOCALIZER_RESULT_OFFSET)) u_transfer(
      .clk_i(clk_i),.rst_n_i(rst_n_i),.enable_i(localizer_enable),.rearm_i(rearm),
      .valid_i(pdm_valid_aligned),.pcm_i(pdm_aligned),.sample_id_i(pdm_frame_cnt),
      .busy_o(loc_busy),.done_o(loc_done),.window_id_o(loc_window),.first_o(loc_first),
      .latency_o(loc_latency),.raw_drop_o(loc_raw_drop),.window_drop_o(loc_window_drop),
      .best_grid_o(loc_grid),.best_score_o(loc_score),
      .fft_start_o(loc_fft_start),.fft_io_o(),.fft_inv_o(loc_fft_inv),.fft_pop_o(loc_fft_pop),
      .fft_seek_o(loc_fft_seek),.fft_data_o(loc_fft_data),.fft_ready_i(loc_fft_ready),
      .fft_done_i(loc_fft_done),.fft_result_i(loc_fft_result),
      .ac_ready_i(loc_ac_ready),.ac_done_i(loc_ac_done),.ac_result_i(loc_ac_result),
      .ac_start_o(loc_ac_start),.ac_sel_o(loc_ac_sel),.ac_data_o(loc_ac_data),
      .srp_r_we_o(loc_r_we),.srp_r_addr_o(loc_r_addr),.srp_r_data_o(loc_r_data),
      .srp_start_o(),.srp_done_i(loc_srp_done),.srp_busy_i(srp_busy),
      .srp_score_addr_o(loc_score_addr),.srp_score_i($signed(loc_srp_score)),
      .run_request_o(loc_request),.request_id_o(loc_request_id),.compute_cycles_o(loc_compute_cycles),
      .statistics_index_i(loc_statistics_index),.statistics_data_o(loc_statistics_data));
  end else begin:g_no_localizer
    assign loc_statistics_data=0;
    assign loc_busy=0;assign loc_done=0;assign loc_request=0;assign loc_request_id=0;assign loc_compute_cycles=0;
    assign loc_window=0;assign loc_first=0;assign loc_latency=0;assign loc_raw_drop=0;
    assign loc_window_drop=0;assign loc_grid=0;assign loc_score=0;
    assign loc_fft_start=0;assign loc_fft_inv=0;assign loc_fft_pop=0;assign loc_fft_seek=0;
    assign loc_fft_data=0;assign loc_ac_start=0;assign loc_ac_sel=0;assign loc_ac_data=0;
    assign loc_r_we=0;assign loc_r_addr=0;assign loc_r_data=0;assign loc_score_addr=0;
  end endgenerate

  rv32_xsp_regs #(
    .DW     (16),
    .NB     (513),
    .BIN_LO (DAS_ACTIVE_CHANNELS==9 ? 2 : 5),
    .BIN_HI (DAS_ACTIVE_CHANNELS==9 ? 52 : 209)
  ) u_xsp (
    .clk_i        (clk_i),
    .rst_n_i      (rst_n_i),
    .core_start_i (core_xsp_start),
    .core_wr_i    (mmio_write & mmio_xsp_win),
    .core_rd_i    (mmio_read  & mmio_xsp_win & ~mmio_ack_q),
    .core_addr_i  (mmio_offset[8:2]),
    .core_wdata_i (dmem_wdata),
    .core_rdata_o (xsp_core_rdata),
    .ps_wr_i      (xsp_cfg_wr_i),
    .ps_rd_i      (xsp_cfg_rd_i),
    .ps_addr_i    (xsp_cfg_addr_i),
    .ps_wdata_i   (xsp_cfg_wdata_i),
    .ps_rdata_o   (xsp_cfg_rdata_o),
    .busy_o       (xsp_busy)
  );

  // ── 波束转向块 ───────────────────────────────────────────────────────────
  // 与 SRP/XSP 同形：核走 MMIO 0xA000，PS 走 AXI 0x600，发起用门铃 funct3=010。
  // 迟滞/渐变状态机在壳里（§26.5.1/§26.5.2），几何在 rv32_steer 里。
  // 规模与固件同尺寸（256 格 = 16×16），参数与 rv32_steer.v 的默认值一致。
  rv32_steer_regs #(
    .N_GRID   (LIVE16_LOCALIZATION ? 1024 : 256),
    .GRID_W   (LIVE16_LOCALIZATION ? 32 : 16),
    .IDX_W    (10),
    .FRAC_W   (4),
    .N_MIC    (ALGORITHM_CHANNELS),
    .CELL_TOL (2)
  ) u_steer (
    .clk_i        (clk_i),
    .rst_n_i      (rst_n_i),
    .core_start_i (core_steer_start),
    .core_wr_i    (mmio_write & mmio_steer_win),
    .core_rd_i    (mmio_read  & mmio_steer_win & ~mmio_ack_q),
    .core_addr_i  (mmio_offset[8:2]),
    .core_wdata_i (dmem_wdata),
    .core_rdata_o (steer_core_rdata),
    .ps_wr_i      (steer_cfg_wr_i),
    .ps_rd_i      (steer_cfg_rd_i),
    .ps_addr_i    (steer_cfg_addr_i),
    .ps_wdata_i   (steer_cfg_wdata_i),
    .ps_rdata_o   (steer_cfg_rdata_o),
    .busy_o       (steer_busy),
    .comp_o       (beam_comp), .locked_o (beam_locked)
    ,.link_start_i(link_start),.link_target_i(link_target),.committed_grid_o(committed_grid)
  );

  // 加速器的忙也并进 simd_active：PS 侧的 CYC_SIMD 就能在板上直接量到定位
  // 加速器占了多少拍 —— 零成本的上板证据（rv32_ps_regs.v 的 ADDR_CYC_SIMD）。
  assign simd_active_o = core_simd_active | srp_busy | xsp_busy | steer_busy;

endmodule
