// Zynq-7020 的 PL 顶层：AXI4-Lite 控制面 + PS 直访 TCM 的数据面 + irq_o 通知面。
// （原为 7z010，2026-10-01 换核心板。**本文件与器件无关**，两者都能用 ——
//   J3 的封装脚经 scripts/check_pins.tcl 实测在 CLG400 下逐脚相同。）
//
// 纯 RTL，不含 PS7 —— PS7 在 block design 里，FCLK_CLK0 接 clk_i、peripheral_aresetn
// 接 rst_n_i、M_AXI_GP0 接 s_axi_*、irq_o 接 IRQ_F2P。
//
// retire_* 一路进寄存器堆、一路出顶层：给 ILA 用，也顺带保证综合不会把核删掉
// —— 有寄存器堆在消费，retire 观测逻辑就不是死逻辑。
// （裸 PL 那条路的顶层是脚本生成的，靠给 ITCM 预装程序来避免同一个坑，见 gen_synth_top.tcl。）
module rv32_ps_top #(
  parameter RESET_PC = 32'h0000_0000,
  parameter ITCM_WORDS = 4096,
  parameter ITCM_ADDR_WIDTH = 14,
  parameter DTCM_WORDS = 4096,
  parameter DTCM_ADDR_WIDTH = 14,
  parameter LED_WIDTH = 3,
  parameter DAS_ACTIVE_CHANNELS = 8,
  parameter PDM_CHANNELS = DAS_ACTIVE_CHANNELS == 4 ? 8 : DAS_ACTIVE_CHANNELS,
  parameter LIVE16_LOCALIZATION = DAS_ACTIVE_CHANNELS >= 8,
  parameter PDM_MICS_PER_LINE = DAS_ACTIVE_CHANNELS >= 8 ? 2 : 1
) (
  input         clk_i,
  input         rst_n_i,
  input  [11:0] s_axi_awaddr,
  input         s_axi_awvalid,
  output        s_axi_awready,
  input  [31:0] s_axi_wdata,
  input  [3:0]  s_axi_wstrb,
  input         s_axi_wvalid,
  output        s_axi_wready,
  output [1:0]  s_axi_bresp,
  output        s_axi_bvalid,
  input         s_axi_bready,
  input  [11:0] s_axi_araddr,
  input         s_axi_arvalid,
  output        s_axi_arready,
  output [31:0] s_axi_rdata,
  output [1:0]  s_axi_rresp,
  output        s_axi_rvalid,
  input         s_axi_rready,
  output        irq_o,
  // 核侧 MMIO 0x5000 驱动的板载 LED。出顶层去引脚，同时进寄存器堆当只读镜像。
  // 位宽改这里要连 BD 一起重建：module_ref 的引脚宽度是按参数默认值推出来的。
  output [LED_WIDTH-1:0] led_o,
  // 开漏输入用 PULLUP）。裸 PL 顶层 rv32_synth_top 那一路没有板级引脚，gen_synth_top.tcl
  // 里仍接 1'b0 —— 所以裸 PL 工程里 tacho 永不触发，这是有意的，不是漏接。
  // 还没做的只有"板子上的电平适配与实测"（见 docs/board_io.md）。
  input         tacho_i,
  // PDM默认8通道、4根双相DATA、1根CLK；接线见 planar8_configuration.md。
  // ⚠ 加端口就得**重建 BD**（module_ref 的引脚是按当前端口表推出来的）——
  //   DATA宽度由PDM_CHANNELS/PDM_MICS_PER_LINE决定。
  output        pdm_clk_o,
  input  [PDM_CHANNELS/PDM_MICS_PER_LINE-1:0] pdm_din_i,
  input gsc_ready_i,output gsc_valid_o,output [511:0]gsc_data_o,output [63:0]gsc_timestamp_o,
  output        retire_valid_o,
  output [31:0] retire_pc_o,
  output [31:0] retire_instr_o,
  output [3:0]  retire_fault_o
);

  wire        reg_wr;
  wire        reg_rd;
  wire [11:0] reg_addr;
  wire [31:0] reg_wdata;
  wire [3:0]  reg_wstrb;
  wire [31:0] reg_rdata;
  wire        reg_wr_err;
  wire        reg_rd_err;

  wire        halt;
  wire        soft_rst;
  wire [31:0] fromhost;
  wire [31:0] tohost;
  wire        tohost_we;

  wire        ps_req;
  wire        ps_write;
  wire        ps_sel;
  // PS 侧 TCM 窗口的地址位宽，同时喂 rv32_ps_regs 的 MEM_ADDR_WIDTH 和下面这根线。
  // 必须 ≥ 每个 TCM 的 ADDR_WIDTH —— 窄了不报错，只是 PS 静默地只能摸到存储器前一段。
  // 起个名字是为了让端口实参和线宽不可能各改各的。
  //
  // 下面 ps_addr_i 的零扩展必须写成 32-PS_MEM_ADDR_WIDTH：rv32_soc 的 ps_addr_i 是
  // 32 位，直接连 14 位线的话 iverilog 会告警，而 run_iverilog.ps1 把任何 stderr 都当致命错误。
  localparam PS_MEM_ADDR_WIDTH = 14;
  wire [PS_MEM_ADDR_WIDTH-1:0] ps_addr;
  wire [31:0] ps_wdata;
  wire        ps_ready;
  wire [31:0] ps_rdata;

  wire simd_active;
  // 阵列系数预装窗口：rv32_ps_regs 到 rv32_soc 的内部连线。**不出顶层** ——
  // 它由 AXI 寄存器窗口驱动，不给 BD 添引脚，所以既不用重建 BD，也不碰 B3。
  wire        coef_we;
  wire        coef_re;
  wire        coef_src;
  wire        coef_ch;
  wire [8:0]  coef_idx;
  wire [15:0] coef_wdata;
  wire [15:0] coef_rdata;
  // 和 coef_* 一样**不出顶层** —— 它由 AXI 窗口驱动，不给 BD 添引脚。
  // 出顶层的只有那 9 根板级麦引脚。
  wire        pdm_cfg_wr, pdm_cfg_rd;
  wire [6:0]  pdm_cfg_addr;
  wire [31:0] pdm_cfg_wdata, pdm_cfg_rdata;
  // 定位加速器两窗（AXI 0x400 = SRP / 0x500 = 互谱+PHAT）：rv32_ps_regs 到
  // rv32_soc 的内部连线。和 coef_* / pdm_cfg_* 一样**不出顶层** ——
  // 由 AXI 窗口驱动，不给 BD 添引脚，所以既不用重建 BD，也不碰 B3。
  wire        srp_cfg_wr, srp_cfg_rd;
  wire [6:0]  srp_cfg_addr;
  wire [31:0] srp_cfg_wdata, srp_cfg_rdata;
  wire        xsp_cfg_wr, xsp_cfg_rd;
  wire [6:0]  xsp_cfg_addr;
  wire [31:0] xsp_cfg_wdata, xsp_cfg_rdata;
  wire        steer_cfg_wr, steer_cfg_rd;
  wire [6:0]  steer_cfg_addr;
  wire [31:0] steer_cfg_wdata, steer_cfg_rdata;

  // 软复位是寄存器堆发的一拍脉冲，和外部复位并起来给整个 SoC。
  wire soc_rst_n = rst_n_i & ~soft_rst;

  rv32_axi_lite_slave #(.ADDR_WIDTH(12)) u_axi (
    .clk_i        (clk_i),
    .rst_n_i      (rst_n_i),
    .s_axi_awaddr (s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata  (s_axi_wdata),
    .s_axi_wstrb  (s_axi_wstrb),
    .s_axi_wvalid (s_axi_wvalid),
    .s_axi_wready (s_axi_wready),
    .s_axi_bresp  (s_axi_bresp),
    .s_axi_bvalid (s_axi_bvalid),
    .s_axi_bready (s_axi_bready),
    .s_axi_araddr (s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata  (s_axi_rdata),
    .s_axi_rresp  (s_axi_rresp),
    .s_axi_rvalid (s_axi_rvalid),
    .s_axi_rready (s_axi_rready),
    .reg_wr_o     (reg_wr),
    .reg_addr_o   (reg_addr),
    .reg_wdata_o  (reg_wdata),
    .reg_wstrb_o  (reg_wstrb),
    .reg_rd_o     (reg_rd),
    .reg_rdata_i  (reg_rdata),
    .reg_wr_err_i (reg_wr_err),
    .reg_rd_err_i (reg_rd_err)
  );

  rv32_ps_regs #(
    .ADDR_WIDTH     (12),
    .MEM_ADDR_WIDTH (PS_MEM_ADDR_WIDTH),
    .LED_WIDTH      (LED_WIDTH)
  ) u_regs (
    .clk_i          (clk_i),
    .rst_n_i        (rst_n_i),
    .reg_wr_i       (reg_wr),
    .reg_rd_i       (reg_rd),
    .reg_addr_i     (reg_addr),
    .reg_wdata_i    (reg_wdata),
    .reg_wstrb_i    (reg_wstrb),
    .reg_rdata_o    (reg_rdata),
    .reg_wr_err_o   (reg_wr_err),
    .reg_rd_err_o   (reg_rd_err),
    .halt_o         (halt),
    .soft_rst_o     (soft_rst),
    .irq_o          (irq_o),
    .fromhost_o     (fromhost),
    .retire_valid_i (retire_valid_o),
    .retire_pc_i    (retire_pc_o),
    .retire_instr_i (retire_instr_o),
    .retire_fault_i (retire_fault_o),
    .tohost_i       (tohost),
    .tohost_we_i    (tohost_we),
    .led_i          (led_o),
    .ps_req_o       (ps_req),
    .ps_write_o     (ps_write),
    .ps_sel_o       (ps_sel),
    .ps_addr_o      (ps_addr),
    .ps_wdata_o     (ps_wdata),
    .ps_ready_i     (ps_ready),
    .ps_rdata_i     (ps_rdata),
    .simd_active_i   (simd_active),
    .coef_we_o       (coef_we),
    .coef_re_o       (coef_re),
    .coef_src_o      (coef_src),
    .coef_ch_o       (coef_ch),
    .coef_idx_o      (coef_idx),
    .coef_wdata_o    (coef_wdata),
    .coef_rdata_i    (coef_rdata),
    .pdm_cfg_wr_o    (pdm_cfg_wr),
    .pdm_cfg_rd_o    (pdm_cfg_rd),
    .pdm_cfg_addr_o  (pdm_cfg_addr),
    .pdm_cfg_wdata_o (pdm_cfg_wdata),
    .pdm_cfg_rdata_i (pdm_cfg_rdata),
    .srp_cfg_wr_o    (srp_cfg_wr),
    .srp_cfg_rd_o    (srp_cfg_rd),
    .srp_cfg_addr_o  (srp_cfg_addr),
    .srp_cfg_wdata_o (srp_cfg_wdata),
    .srp_cfg_rdata_i (srp_cfg_rdata),
    .xsp_cfg_wr_o    (xsp_cfg_wr),
    .xsp_cfg_rd_o    (xsp_cfg_rd),
    .xsp_cfg_addr_o  (xsp_cfg_addr),
    .xsp_cfg_wdata_o (xsp_cfg_wdata),
    .xsp_cfg_rdata_i (xsp_cfg_rdata),
    .steer_cfg_wr_o    (steer_cfg_wr),
    .steer_cfg_rd_o    (steer_cfg_rd),
    .steer_cfg_addr_o  (steer_cfg_addr),
    .steer_cfg_wdata_o (steer_cfg_wdata),
    .steer_cfg_rdata_i (steer_cfg_rdata)
  );

  rv32_soc #(
    .RESET_PC         (RESET_PC),
    .ITCM_WORDS       (ITCM_WORDS),
    .ITCM_ADDR_WIDTH  (ITCM_ADDR_WIDTH),
    .DTCM_WORDS       (DTCM_WORDS),
    .DTCM_ADDR_WIDTH  (DTCM_ADDR_WIDTH),
    .LED_WIDTH        (LED_WIDTH),
    .DAS_ACTIVE_CHANNELS (DAS_ACTIVE_CHANNELS),
    .LIVE16_LOCALIZATION(LIVE16_LOCALIZATION), .PDM_CHANNELS(PDM_CHANNELS), .PDM_MICS_PER_LINE(PDM_MICS_PER_LINE)
  ) u_soc (
    .clk_i          (clk_i),
    .rst_n_i        (soc_rst_n),
    .gsc_ready_i(gsc_ready_i),.gsc_valid_o(gsc_valid_o),.gsc_data_o(gsc_data_o),.gsc_timestamp_o(gsc_timestamp_o),
    .test_en_i      (1'b0),
    .halt_i         (halt),
    .retire_valid_o (retire_valid_o),
    .retire_pc_o    (retire_pc_o),
    .retire_instr_o (retire_instr_o),
    .retire_fault_o (retire_fault_o),
    .tohost_o       (tohost),
    .tohost_we_o    (tohost_we),
    .fromhost_i     (fromhost),
    .led_o          (led_o),
    .ps_req_i       (ps_req),
    .ps_write_i     (ps_write),
    .ps_sel_i       (ps_sel),
    .ps_addr_i      ({{(32-PS_MEM_ADDR_WIDTH){1'b0}}, ps_addr}),
    .ps_wdata_i     (ps_wdata),
    .ps_ready_o     (ps_ready),
    .ps_rdata_o     (ps_rdata),
    .simd_active_o   (simd_active),
    .coef_we_i       (coef_we),
    .coef_re_i       (coef_re),
    .coef_src_i      (coef_src),
    .coef_ch_i       (coef_ch),
    .coef_idx_i      (coef_idx),
    .coef_wdata_i    (coef_wdata),
    .coef_rdata_o    (coef_rdata),
    .tacho_i         (tacho_i),
    .pdm_clk_o       (pdm_clk_o),
    .pdm_din_i       (pdm_din_i),
    .pdm_cfg_wr_i    (pdm_cfg_wr),
    .pdm_cfg_rd_i    (pdm_cfg_rd),
    .pdm_cfg_addr_i  (pdm_cfg_addr),
    .pdm_cfg_wdata_i (pdm_cfg_wdata),
    .pdm_cfg_rdata_o (pdm_cfg_rdata),
    .srp_cfg_wr_i    (srp_cfg_wr),
    .srp_cfg_rd_i    (srp_cfg_rd),
    .srp_cfg_addr_i  (srp_cfg_addr),
    .srp_cfg_wdata_i (srp_cfg_wdata),
    .srp_cfg_rdata_o (srp_cfg_rdata),
    .xsp_cfg_wr_i    (xsp_cfg_wr),
    .xsp_cfg_rd_i    (xsp_cfg_rd),
    .xsp_cfg_addr_i  (xsp_cfg_addr),
    .xsp_cfg_wdata_i (xsp_cfg_wdata),
    .xsp_cfg_rdata_o (xsp_cfg_rdata),
    .steer_cfg_wr_i    (steer_cfg_wr),
    .steer_cfg_rd_i    (steer_cfg_rd),
    .steer_cfg_addr_i  (steer_cfg_addr),
    .steer_cfg_wdata_i (steer_cfg_wdata),
    .steer_cfg_rdata_o (steer_cfg_rdata)
  );

endmodule
