// PS 侧寄存器堆：控制、状态、性能计数、retire 观测、邮箱、TCM 访问窗口。
//
// 总线时序（与 rv32_axi_lite_slave 的约定一致）：
//   写：reg_wr_i 单拍脉冲，reg_addr_i/reg_wdata_i 当拍有效，reg_wr_err_o 当拍回。
//   读：reg_rd_i 单拍脉冲并给出地址，reg_rdata_o/reg_rd_err_o 在**下一拍**有效。
//
// 核的控制全部经这里：halt_o 冻结整条流水，soft_rst_o 给 SoC 一拍异步复位。
// 软复位会把 HALT 置 1 —— 复位后核不会自己跑起来，必须 PS 显式清 HALT。
// 这条是有意的：下载固件期间核若自己开始取指，取到的会是写了一半的程序。
module rv32_ps_regs #(
  parameter ADDR_WIDTH = 12,
  parameter MEM_ADDR_WIDTH = 14,
  parameter LED_WIDTH = 3
) (
  input                       clk_i,
  input                       rst_n_i,
  input                       reg_wr_i,
  input                       reg_rd_i,
  input  [ADDR_WIDTH-1:0]     reg_addr_i,
  input  [31:0]               reg_wdata_i,
  input  [3:0]                reg_wstrb_i,
  output [31:0]               reg_rdata_o,
  output                      reg_wr_err_o,
  output                      reg_rd_err_o,
  output                      halt_o,
  output                      soft_rst_o,
  output                      irq_o,
  output [31:0]               fromhost_o,
  input                       retire_valid_i,
  input  [31:0]               retire_pc_i,
  input  [31:0]               retire_instr_i,
  input  [3:0]                retire_fault_i,
  input  [31:0]               tohost_i,
  input                       tohost_we_i,
  // 核侧 LED 寄存器的只读镜像：固件写核侧 0x5000 的值。PS 不用另配 AXI GPIO
  // 就能验证固件在驱动灯，也能和 RETIRE_CNT 一起判断核是否真在跑。
  input  [LED_WIDTH-1:0]      led_i,
  output                      ps_req_o,
  output                      ps_write_o,
  output                      ps_sel_o,
  output [MEM_ADDR_WIDTH-1:0] ps_addr_o,
  output [31:0]               ps_wdata_o,
  input                       ps_ready_i,
  input  [31:0]               ps_rdata_i,
  // SIMD/加速器忙信号，只为 CYC_SIMD 计数用；与音频无关。
  input                       simd_active_i,
  // Q15 进出。**读写都要核停住**：写是因为不能改动正在跑的滤波器，读是因为阵列的
  // 系数读口只有一条、读会借它 —— TCM 那条"读不设限"在这里不成立。
  output                      coef_we_o,
  output                      coef_re_o,
  output                      coef_src_o,
  output                      coef_ch_o,
  output [8:0]                coef_idx_o,
  output [15:0]               coef_wdata_o,
  input  [15:0]               coef_rdata_i,
  // 两条窗口同一个编号空间。和音频那条一样是组合读口，在 reg_rd_i 当拍接住、下一拍送出。
  // **不做核侧 MMIO 镜像**：这条通路是给 PS 的，核不需要它，硬加一个页只会多一处要同步的东西。
  output                      pdm_cfg_wr_o,
  output                      pdm_cfg_rd_o,
  output [6:0]                pdm_cfg_addr_o,
  output [31:0]               pdm_cfg_wdata_o,
  input  [31:0]               pdm_cfg_rdata_i,
  // 定位加速器两个窗口：SRP 走 0x400，互谱+PHAT 走 0x500。
  // 与核侧 MMIO 页 0x8000 / 0x9000 是同一组寄存器的两个端口。
  output                      srp_cfg_wr_o,
  output                      srp_cfg_rd_o,
  output [6:0]                srp_cfg_addr_o,
  output [31:0]               srp_cfg_wdata_o,
  input  [31:0]               srp_cfg_rdata_i,
  output                      xsp_cfg_wr_o,
  output                      xsp_cfg_rd_o,
  output [6:0]                xsp_cfg_addr_o,
  output [31:0]               xsp_cfg_wdata_o,
  input  [31:0]               xsp_cfg_rdata_i,
  // 波束转向块：走 0x600（此前全空），与核侧 MMIO 页 0xA000 同一组寄存器。
  output                      steer_cfg_wr_o,
  output                      steer_cfg_rd_o,
  output [6:0]                steer_cfg_addr_o,
  output [31:0]               steer_cfg_wdata_o,
  input  [31:0]               steer_cfg_rdata_i
);

  localparam [11:0] ADDR_CTRL       = 12'h000;
  localparam [11:0] ADDR_STATUS     = 12'h004;
  localparam [11:0] ADDR_SRC_ADDR   = 12'h008;
  localparam [11:0] ADDR_SRC_LEN    = 12'h00C;
  localparam [11:0] ADDR_RESULT     = 12'h010;
  localparam [11:0] ADDR_SCORE      = 12'h014;
  localparam [11:0] ADDR_IRQ_STAT   = 12'h018;
  localparam [11:0] ADDR_IRQ_MASK   = 12'h01C;
  localparam [11:0] ADDR_RETIRE_CNT = 12'h020;
  localparam [11:0] ADDR_RETIRE_PC  = 12'h024;
  localparam [11:0] ADDR_RETIRE_INS = 12'h028;
  localparam [11:0] ADDR_RETIRE_INF = 12'h02C;
  localparam [11:0] ADDR_TRAP_CNT   = 12'h030;
  localparam [11:0] ADDR_TOHOST     = 12'h034;
  localparam [11:0] ADDR_TOHOST_CNT = 12'h038;
  localparam [11:0] ADDR_FROMHOST   = 12'h03C;
  localparam [11:0] ADDR_CYC_TOTAL  = 12'h040;
  localparam [11:0] ADDR_CYC_BUSY   = 12'h044;
  localparam [11:0] ADDR_CYC_SIMD   = 12'h048;
  localparam [11:0] ADDR_CYC_IDLE   = 12'h04C;
  localparam [11:0] ADDR_MEM_ADDR   = 12'h080;
  localparam [11:0] ADDR_MEM_WDATA  = 12'h084;
  localparam [11:0] ADDR_MEM_RDATA  = 12'h088;
  localparam [11:0] ADDR_MEM_CTRL   = 12'h08C;
  localparam [11:0] ADDR_LED_STATE  = 12'h090;
  localparam [11:0] ADDR_COEF_ADDR  = 12'h0C0;
  localparam [11:0] ADDR_COEF_WDATA = 12'h0C4;
  localparam [11:0] ADDR_COEF_RDATA = 12'h0C8;
  localparam [11:0] ADDR_COEF_CTRL  = 12'h0CC;

  wire [11:0] reg_off = reg_addr_i[11:0];

  (* max_fanout = 32 *) reg halt_q;   // 同上；粒度见上面那段实测
  reg        done_q;
  reg  [2:0] mode_q;
  reg  [3:0] precision_q;
  reg  [31:0] src_addr_q;
  reg  [31:0] src_len_q;
  reg  [31:0] fromhost_q;
  reg  [3:0]  irq_stat_q;
  reg  [3:0]  irq_mask_q;

  reg [31:0] cyc_total_q;
  reg [31:0] cyc_busy_q;
  reg [31:0] cyc_idle_q;
  reg [31:0] cyc_simd_q;

  reg [31:0] retire_cnt_q;
  reg [31:0] retire_pc_q;
  reg [31:0] retire_instr_q;
  reg [3:0]  retire_fault_q;
  reg        retire_seen_q;
  reg [31:0] trap_cnt_q;

  reg [31:0] tohost_q;
  reg [31:0] tohost_cnt_q;

  reg [31:0] rd_data_q;
  reg        rd_memif_q;
  reg        rd_pdm_sel_q;
  reg [31:0] rd_pdm_q;
  reg        rd_srp_sel_q;
  reg [31:0] rd_srp_q;
  reg        rd_xsp_sel_q;
  reg [31:0] rd_xsp_q;
  reg        rd_steer_sel_q;
  reg [31:0] rd_steer_q;

  // 系数预装窗口：一个抽头指针 + 选哪一套/哪个通道 + 粘滞错误位。
  reg  [8:0] coef_idx_q;
  reg        coef_src_q;     // 0 = w，1 = ŝ
  reg        coef_ch_q;
  reg        coef_err_q;
  reg        rd_coef_q;      // 读数据下一拍才到，用它在输出 mux 里接住
  reg        rd_err_q;
  reg        err_seen_q;

  wire wr_ctrl     = reg_wr_i & (reg_off == ADDR_CTRL);
  wire wr_src_addr = reg_wr_i & (reg_off == ADDR_SRC_ADDR);
  wire wr_src_len  = reg_wr_i & (reg_off == ADDR_SRC_LEN);
  wire wr_irq_stat = reg_wr_i & (reg_off == ADDR_IRQ_STAT);
  wire wr_irq_mask = reg_wr_i & (reg_off == ADDR_IRQ_MASK);
  wire wr_fromhost = reg_wr_i & (reg_off == ADDR_FROMHOST);
  wire wr_mem_addr = reg_wr_i & (reg_off == ADDR_MEM_ADDR);
  wire wr_mem_wdat = reg_wr_i & (reg_off == ADDR_MEM_WDATA);
  wire wr_mem_ctrl = reg_wr_i & (reg_off == ADDR_MEM_CTRL);
  wire rd_mem_rdata = reg_rd_i & (reg_off == ADDR_MEM_RDATA);
  // PDM 阵列采集窗口占 0x300–0x3FF（只用到前 0x50 字节）。0x300 段此前全空。
  wire sel_pdm = (reg_off[11:8] == 4'h3);
  // 定位加速器：0x400 = SRP 空间扫描，0x500 = 互谱 + PHAT。两段此前全空。
  // 只用到每窗的头 32 字节（8 个字），按上 4 位译码与 PDM 同粒度。
  wire sel_srp = (reg_off[11:8] == 4'h4);
  wire sel_xsp = (reg_off[11:8] == 4'h5);
  // 波束转向块：0x600 = 转向窗口（0x600 段此前全空）。
  wire sel_steer = (reg_off[11:8] == 4'h6);

  wire wr_coef_addr  = reg_wr_i & (reg_off == ADDR_COEF_ADDR);
  wire wr_coef_wdat  = reg_wr_i & (reg_off == ADDR_COEF_WDATA);
  wire wr_coef_ctrl  = reg_wr_i & (reg_off == ADDR_COEF_CTRL);
  wire rd_coef_rdata = reg_rd_i & (reg_off == ADDR_COEF_RDATA);
  // 核在跑就一律拒绝、地址也不动，等停住之后可以原地重试（和 TCM 那条窗口同规矩）。
  wire allow_coef    = halt_q & ~simd_active_i;
  wire coef_write_ok = wr_coef_wdat  & allow_coef;
  wire coef_read_ok  = rd_coef_rdata & allow_coef;
  wire coef_bad      = (wr_coef_wdat | rd_coef_rdata) & ~allow_coef;

  assign coef_we_o    = coef_write_ok;
  assign coef_re_o    = coef_read_ok;
  assign coef_src_o   = coef_src_q;
  assign coef_ch_o    = coef_ch_q;
  assign coef_idx_o   = coef_idx_q;
  assign coef_wdata_o = reg_wdata_i[15:0];
  wire [31:0] coef_ctrl_read = {29'b0, ~halt_q, coef_err_q, 1'b0};
  wire rd_pdm  = reg_rd_i & sel_pdm;
  wire rd_srp  = reg_rd_i & sel_srp;
  wire rd_xsp  = reg_rd_i & sel_xsp;
  wire rd_steer = reg_rd_i & sel_steer;

  // 三个脉冲都打一拍再出去，不让组合译码直接驱动核。
  // halt_o 和 soft_rst_o 一个进核的流水控制、一个当整个 SoC 的异步复位：若由
  // wr_ctrl（组合译码自 AXI 地址）直接产生，s_axi_araddr 会一路穿过译码比较器、
  // halt_o、核的流水控制打到 BRAM 的控制脚 —— 实测那正是本设计关键路径的来源，
  // AXI 引脚到 BRAM 之间一个寄存器都没有。
  wire ctrl_start = wr_ctrl & reg_wdata_i[0];
  wire ctrl_step  = wr_ctrl & reg_wdata_i[2];
  wire ctrl_srst  = wr_ctrl & reg_wdata_i[4];

  // ⚠ max_fanout：这两个是**扇到全 SoC 的慢速控制信号**，实测反复出现在关键路径的源头
  //   （soft_rst_o → 整个 SoC 的异步复位；halt_q → 核的流水控制），而且路径 54% 是布线
  //   —— 说明驱动点到最远负载之间隔得太远。复制成多份就近驱动是标准做法，**功能不变**
  //   （它们本来就是寄存器输出，复制等价于加缓冲）。不加的话，关键路径会在这两个信号
  //   和核 payload 之间来回跳：压下一批，下一批又冒出来。
  // 复制粒度**实测扫过**：32 → WNS −0.068 / 6 端点；16 → −0.274 / 22 端点。
  // **16 更差**：复制得太碎反而拥塞。32 是甜点，别再往下收。
  (* max_fanout = 32 *) reg start_pulse;
  (* max_fanout = 32 *) reg step_pulse;
  (* max_fanout = 32 *) reg soft_rst_pulse;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      start_pulse    <= 1'b0;
      step_pulse     <= 1'b0;
      soft_rst_pulse <= 1'b0;
    end else begin
      start_pulse    <= ctrl_start;
      step_pulse     <= ctrl_step;
      soft_rst_pulse <= ctrl_srst;
    end
  end

  assign halt_o     = halt_q & ~step_pulse;
  assign soft_rst_o = soft_rst_pulse;

  // ── TCM 访问窗口 ──────────────────────────────────────────────────────────
  // 核停住了才允许 PS 写 TCM：核正在取指/访存时从 B 口写进去，会让取到的指令和
  // 执行的指令不一致；真双口同地址冲突的语义在 BRAM primitive 上也是未定义的。
  // 读不设限 —— 读不改任何状态，运行期观测 buffer 填充是有用的。
  wire        allow_mem_write = halt_q;
  wire [31:0] mem_addr;
  wire [31:0] mem_wdata;
  wire [31:0] mem_rdata;
  wire [31:0] mem_ctrl;
  wire        mem_err;

  rv32_ps_memif #(.ADDR_WIDTH(MEM_ADDR_WIDTH)) u_memif (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    .addr_wr_i     (wr_mem_addr),
    .addr_wdata_i  (reg_wdata_i),
    .wdata_wr_i    (wr_mem_wdat),
    .wdata_i       (reg_wdata_i),
    .rdata_rd_i    (rd_mem_rdata),
    .ctrl_wr_i     (wr_mem_ctrl),
    .ctrl_wdata_i  (reg_wdata_i),
    .allow_write_i (allow_mem_write),
    .addr_o        (mem_addr),
    .wdata_o       (mem_wdata),
    .rdata_o       (mem_rdata),
    .ctrl_o        (mem_ctrl),
    .err_o         (mem_err),
    .ps_req_o      (ps_req_o),
    .ps_write_o    (ps_write_o),
    .ps_sel_o      (ps_sel_o),
    .ps_addr_o     (ps_addr_o),
    .ps_wdata_o    (ps_wdata_o),
    .ps_ready_i    (ps_ready_i),
    .ps_rdata_i    (ps_rdata_i)
  );

  // err 是粘滞位，中断要取上升沿，否则会一直重挂。
  wire irq_err_rise = mem_err & ~err_seen_q;
  wire trap_retire  = retire_valid_i & (retire_fault_i != 4'b0);

  wire [3:0] irq_status = {1'b0, irq_stat_q[2:0]};   // bit3 原为音频帧中断，2026-10-06 随该通路移除
  assign irq_o = |(irq_status & irq_mask_q);

  // ── 控制与状态 ────────────────────────────────────────────────────────────
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      halt_q      <= 1'b1;
      done_q      <= 1'b0;
      mode_q      <= 3'b0;
      precision_q <= 4'b0;
      src_addr_q  <= 32'b0;
      src_len_q   <= 32'b0;
      fromhost_q  <= 32'b0;
      irq_stat_q  <= 4'b0;
      irq_mask_q  <= 4'b0;
    end else begin
      // 写与事件共用一段：START 的清零写在最前，后面的置位优先，语义是"这一拍到的
      // 事件不会被同拍的 START 抹掉"。用寄存后的 start_pulse 而不是 wr_ctrl，
      // 理由同上面三个脉冲（不让组合译码直接驱动功能逻辑）。
      if (start_pulse) begin
        done_q     <= 1'b0;
        irq_stat_q <= 4'b0;
      end
      if (wr_ctrl) begin
        // 软复位当拍就把 HALT 置上：软复位脉冲本身晚一拍，只用它置位会让核
        // 有一拍处于"没停且正在被复位"的空隙。
        halt_q      <= reg_wdata_i[1] | ctrl_srst;
        mode_q      <= reg_wdata_i[7:5];
        precision_q <= reg_wdata_i[11:8];
      end
      if (wr_src_addr) begin
        src_addr_q <= reg_wdata_i;
      end
      if (wr_src_len) begin
        src_len_q <= reg_wdata_i;
      end
      if (wr_fromhost) begin
        fromhost_q <= reg_wdata_i;
      end
      if (wr_irq_mask) begin
        irq_mask_q <= reg_wdata_i[3:0];
      end

      // 软复位把 HALT 拉回 1：复位后核停在原地，等 PS 放行。
      if (soft_rst_pulse) begin
        halt_q <= 1'b1;
      end

      // IRQ_STAT 是 W1C：先按写清，再让同拍发生的事件置位。
      if (wr_irq_stat) begin
        irq_stat_q <= irq_stat_q & ~reg_wdata_i[3:0];
      end
      if (tohost_we_i) begin
        irq_stat_q[1] <= 1'b1;
        done_q        <= 1'b1;
      end
      if (irq_err_rise) begin
        irq_stat_q[2] <= 1'b1;
      end
    end
  end

  // 系数预装窗口。地址是一个抽头指针，写/读成功都自增；被拒则地址不动 ——
  // 和 rv32_ps_memif 对 TCM 的做法一致，PS 停住核之后可以从同一个抽头重来。
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      coef_idx_q <= 9'b0;
      coef_src_q <= 1'b0;
      coef_ch_q  <= 1'b0;
      coef_err_q <= 1'b0;
    end else begin
      // 显式优先链：装载 > 归零 > 自增。总线是串行的，三者实际不会撞。
      if (wr_coef_addr) begin
        coef_idx_q <= reg_wdata_i[8:0];
        coef_src_q <= reg_wdata_i[9];
        coef_ch_q  <= reg_wdata_i[10];
      end else if (wr_coef_ctrl & reg_wdata_i[0]) begin
        coef_idx_q <= 9'b0;
      end else if (coef_write_ok | coef_read_ok) begin
        coef_idx_q <= coef_idx_q + 9'd1;
      end

      if (coef_bad) begin
        coef_err_q <= 1'b1;
      end else if (wr_coef_ctrl & reg_wdata_i[1]) begin
        coef_err_q <= 1'b0;
      end
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      cyc_total_q <= 32'b0;
      cyc_busy_q  <= 32'b0;
      cyc_idle_q  <= 32'b0;
      cyc_simd_q  <= 32'b0;
    end else if (start_pulse) begin
      cyc_total_q <= 32'b0;
      cyc_busy_q  <= 32'b0;
      cyc_idle_q  <= 32'b0;
      cyc_simd_q  <= 32'b0;
    end else begin
      cyc_total_q <= cyc_total_q + 1'b1;
      if (simd_active_i) cyc_simd_q <= cyc_simd_q + 1'b1;
      if (halt_q) begin
        cyc_idle_q <= cyc_idle_q + 1'b1;
      end else begin
        cyc_busy_q <= cyc_busy_q + 1'b1;
      end
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      retire_cnt_q   <= 32'b0;
      retire_pc_q    <= 32'b0;
      retire_instr_q <= 32'b0;
      retire_fault_q <= 4'b0;
      retire_seen_q  <= 1'b0;
      trap_cnt_q     <= 32'b0;
    end else if (start_pulse) begin
      retire_cnt_q   <= 32'b0;
      trap_cnt_q     <= 32'b0;
      retire_seen_q  <= 1'b0;
    end else if (retire_valid_i) begin
      retire_cnt_q   <= retire_cnt_q + 1'b1;
      retire_pc_q    <= retire_pc_i;
      retire_instr_q <= retire_instr_i;
      retire_fault_q <= retire_fault_i;
      retire_seen_q  <= 1'b1;
      if (trap_retire) begin
        trap_cnt_q <= trap_cnt_q + 1'b1;
      end
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      tohost_q     <= 32'b0;
      tohost_cnt_q <= 32'b0;
    end else if (start_pulse) begin
      tohost_cnt_q <= 32'b0;
    end else if (tohost_we_i) begin
      tohost_q     <= tohost_i;
      tohost_cnt_q <= tohost_cnt_q + 1'b1;
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      err_seen_q <= 1'b0;
    end else begin
      err_seen_q <= mem_err;
    end
  end

  // ── 读回 ──────────────────────────────────────────────────────────────────
  wire [31:0] ctrl_read   = {20'b0, precision_q, mode_q, 1'b0, 1'b0, 1'b0, halt_q, 1'b0};
  wire [31:0] status_read = {20'b0, precision_q, mode_q, mem_err, irq_o, halt_q, done_q, ~halt_q};
  wire [31:0] retire_info = {23'b0, retire_seen_q, 4'b0, retire_fault_q};

  wire rd_mapped = (reg_off == ADDR_CTRL)       | (reg_off == ADDR_STATUS)     |
                   (reg_off == ADDR_SRC_ADDR)   | (reg_off == ADDR_SRC_LEN)    |
                   (reg_off == ADDR_RESULT)     | (reg_off == ADDR_SCORE)      |
                   (reg_off == ADDR_IRQ_STAT)   | (reg_off == ADDR_IRQ_MASK)   |
                   (reg_off == ADDR_RETIRE_CNT) | (reg_off == ADDR_RETIRE_PC)  |
                   (reg_off == ADDR_RETIRE_INS) | (reg_off == ADDR_RETIRE_INF) |
                   (reg_off == ADDR_TRAP_CNT)   | (reg_off == ADDR_TOHOST)     |
                   (reg_off == ADDR_TOHOST_CNT) | (reg_off == ADDR_FROMHOST)   |
                   (reg_off == ADDR_CYC_TOTAL)  | (reg_off == ADDR_CYC_BUSY)   |
                   (reg_off == ADDR_CYC_SIMD)   | (reg_off == ADDR_CYC_IDLE)   |
                   (reg_off == ADDR_MEM_ADDR)   | (reg_off == ADDR_MEM_WDATA)  |
                   (reg_off == ADDR_MEM_RDATA)  | (reg_off == ADDR_MEM_CTRL)   |
                   (reg_off == ADDR_LED_STATE)  |
                   (reg_off == ADDR_COEF_ADDR)  | (reg_off == ADDR_COEF_WDATA) |
                   (reg_off == ADDR_COEF_RDATA) | (reg_off == ADDR_COEF_CTRL)  |
                   sel_pdm | sel_srp | sel_xsp | sel_steer;

  wire wr_mapped = (reg_off == ADDR_CTRL)     | (reg_off == ADDR_SRC_ADDR) |
                   (reg_off == ADDR_SRC_LEN)  | (reg_off == ADDR_IRQ_STAT) |
                   (reg_off == ADDR_IRQ_MASK) | (reg_off == ADDR_FROMHOST) |
                   (reg_off == ADDR_MEM_ADDR) | (reg_off == ADDR_MEM_WDATA)|
                   (reg_off == ADDR_MEM_CTRL) |
                   (reg_off == ADDR_COEF_ADDR)  | (reg_off == ADDR_COEF_WDATA) |
                   (reg_off == ADDR_COEF_CTRL)  | sel_pdm |
                   sel_srp | sel_xsp | sel_steer;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      rd_data_q    <= 32'b0;
      rd_memif_q   <= 1'b0;
      rd_coef_q    <= 1'b0;
      rd_pdm_sel_q <= 1'b0;
      rd_pdm_q     <= 32'b0;
      rd_srp_sel_q <= 1'b0;
      rd_srp_q     <= 32'b0;
      rd_xsp_sel_q <= 1'b0;
      rd_xsp_q     <= 32'b0;
      rd_steer_sel_q <= 1'b0;
      rd_steer_q   <= 32'b0;
      rd_err_q     <= 1'b0;
    end else if (reg_rd_i) begin
      // 访问 TCM 的那笔要等 memif 现取，这里只记下"是它"，数据下一拍由 memif 给。
      rd_memif_q <= (reg_off == ADDR_MEM_RDATA);
      rd_coef_q    <= coef_read_ok;
      rd_pdm_sel_q <= rd_pdm;
      rd_pdm_q     <= pdm_cfg_rdata_i;
      rd_srp_sel_q <= rd_srp;
      rd_srp_q     <= srp_cfg_rdata_i;
      rd_xsp_sel_q <= rd_xsp;
      rd_xsp_q     <= xsp_cfg_rdata_i;
      rd_steer_sel_q <= rd_steer;
      rd_steer_q   <= steer_cfg_rdata_i;
      rd_err_q   <= ~rd_mapped;
      case (reg_off)
        ADDR_CTRL:       rd_data_q <= ctrl_read;
        ADDR_STATUS:     rd_data_q <= status_read;
        ADDR_SRC_ADDR:   rd_data_q <= src_addr_q;
        ADDR_SRC_LEN:    rd_data_q <= src_len_q;
        ADDR_RESULT:     rd_data_q <= 32'b0;
        ADDR_SCORE:      rd_data_q <= 32'b0;
        ADDR_IRQ_STAT:   rd_data_q <= {28'b0, irq_status};
        ADDR_IRQ_MASK:   rd_data_q <= {28'b0, irq_mask_q};
        ADDR_RETIRE_CNT: rd_data_q <= retire_cnt_q;
        ADDR_RETIRE_PC:  rd_data_q <= retire_pc_q;
        ADDR_RETIRE_INS: rd_data_q <= retire_instr_q;
        ADDR_RETIRE_INF: rd_data_q <= retire_info;
        ADDR_TRAP_CNT:   rd_data_q <= trap_cnt_q;
        ADDR_TOHOST:     rd_data_q <= tohost_q;
        ADDR_TOHOST_CNT: rd_data_q <= tohost_cnt_q;
        ADDR_FROMHOST:   rd_data_q <= fromhost_q;
        ADDR_CYC_TOTAL:  rd_data_q <= cyc_total_q;
        ADDR_CYC_BUSY:   rd_data_q <= cyc_busy_q;
        ADDR_CYC_SIMD:   rd_data_q <= cyc_simd_q;
        ADDR_CYC_IDLE:   rd_data_q <= cyc_idle_q;
        ADDR_MEM_ADDR:   rd_data_q <= mem_addr;
        ADDR_MEM_WDATA:  rd_data_q <= mem_wdata;
        ADDR_MEM_CTRL:   rd_data_q <= mem_ctrl;
        ADDR_LED_STATE:  rd_data_q <= led_i;
        // COEF_RDATA 的真值走 rd_coef_q 那条，这里落到 default 读 0。
        ADDR_COEF_ADDR:  rd_data_q <= {21'b0, coef_ch_q, coef_src_q, coef_idx_q};
        ADDR_COEF_WDATA: rd_data_q <= 32'b0;
        ADDR_COEF_CTRL:  rd_data_q <= coef_ctrl_read;
        default:         rd_data_q <= 32'b0;
      endcase
    end
  end

  // 组合读口的窗口（PDM / SRP / XSP / 转向）优先于 rd_data_q：它们在 case 里落到
  // default 分支（读 0），真值由各自的 rd_*_q 从组合口接过来。
  assign reg_rdata_o  = rd_memif_q   ? mem_rdata :
                        rd_coef_q    ? {16'b0, coef_rdata_i} :
                        rd_pdm_sel_q ? rd_pdm_q :
                        rd_srp_sel_q ? rd_srp_q :
                        rd_xsp_sel_q ? rd_xsp_q :
                        rd_steer_sel_q ? rd_steer_q : rd_data_q;
  assign reg_rd_err_o = rd_err_q | (rd_coef_rdata & ~allow_coef);
  // 写错误当拍回：未映射地址，或者核没停就想写 TCM / 写系数。
  assign reg_wr_err_o = (reg_wr_i & ~wr_mapped) | (wr_mem_wdat & ~allow_mem_write) |
                        (wr_coef_wdat & ~allow_coef);
  assign fromhost_o   = fromhost_q;

  assign pdm_cfg_wr_o    = reg_wr_i & sel_pdm;
  assign pdm_cfg_rd_o    = rd_pdm;
  assign pdm_cfg_addr_o  = {1'b0,reg_off[7:2]};   // 7 位字数，与核侧 mmio_offset[8:2] 同一编号空间
  assign pdm_cfg_wdata_o = reg_wdata_i;

  // 定位加速器两窗：地址都取 reg_off[6:2]（7 位字数，与核侧 mmio_offset[8:2]
  // 同一编号空间；两个窗口只有 8 个寄存器，高位天然为 0）。
  assign srp_cfg_wr_o    = reg_wr_i & sel_srp;
  assign srp_cfg_rd_o    = rd_srp;
  assign srp_cfg_addr_o  = reg_off[6:2];
  assign srp_cfg_wdata_o = reg_wdata_i;
  assign xsp_cfg_wr_o    = reg_wr_i & sel_xsp;
  assign xsp_cfg_rd_o    = rd_xsp;
  assign xsp_cfg_addr_o  = reg_off[6:2];
  assign xsp_cfg_wdata_o = reg_wdata_i;
  assign steer_cfg_wr_o    = reg_wr_i & sel_steer;
  assign steer_cfg_rd_o    = rd_steer;
  assign steer_cfg_addr_o  = reg_off[6:2];
  assign steer_cfg_wdata_o = reg_wdata_i;

endmodule
