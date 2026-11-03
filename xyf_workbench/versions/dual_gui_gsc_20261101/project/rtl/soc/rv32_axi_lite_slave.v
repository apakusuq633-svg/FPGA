// AXI4-Lite 从端：单笔事务，AW/W 任意顺序到达，缓冲齐了再发起一次寄存器写。
//
// 寄存器总线约定（读固定两拍）：
//   写：reg_wr_o 拉高一拍，reg_addr_o/reg_wdata_o/reg_wstrb_o 当拍有效，reg_err_i 当拍回。
//   读：reg_rd_o 拉高一拍并给出 reg_addr_o，reg_rdata_i/reg_err_i 在**下一拍**有效。
// 读数统一延后一拍，是为了让两条读路径（纯寄存器组合读、TCM 同步读）用同一个约定：
// 从端不必知道对面是哪一种。地址是字节地址，直接用寄存器映射表里的偏移。
// AR 握手到 rvalid 一共三拍：落地址一拍、发起读一拍、等数据一拍。
//
// 时钟端口故意叫 clk_i/rst_n_i 而不是 s_axi_aclk：全设计只允许一个时钟名（verify.ps1
// 第 3 项），block design 里 FCLK_CLK0 接到这一根上。
module rv32_axi_lite_slave #(
  parameter ADDR_WIDTH = 12
) (
  input                    clk_i,
  input                    rst_n_i,
  input  [ADDR_WIDTH-1:0]  s_axi_awaddr,
  input                    s_axi_awvalid,
  output                   s_axi_awready,
  input  [31:0]            s_axi_wdata,
  input  [3:0]             s_axi_wstrb,
  input                    s_axi_wvalid,
  output                   s_axi_wready,
  output [1:0]             s_axi_bresp,
  output                   s_axi_bvalid,
  input                    s_axi_bready,
  input  [ADDR_WIDTH-1:0]  s_axi_araddr,
  input                    s_axi_arvalid,
  output                   s_axi_arready,
  output [31:0]            s_axi_rdata,
  output [1:0]             s_axi_rresp,
  output                   s_axi_rvalid,
  input                    s_axi_rready,
  output                   reg_wr_o,
  output [ADDR_WIDTH-1:0]  reg_addr_o,
  output [31:0]            reg_wdata_o,
  output [3:0]             reg_wstrb_o,
  output                   reg_rd_o,
  input  [31:0]            reg_rdata_i,
  input                    reg_wr_err_i,
  input                    reg_rd_err_i
);

  localparam [1:0] RESP_OKAY   = 2'b00;
  localparam [1:0] RESP_SLVERR = 2'b10;

  // ── 写通路 ────────────────────────────────────────────────────────────────
  reg                   aw_captured;
  reg                   w_captured;
  reg                   wr_done;
  reg  [ADDR_WIDTH-1:0] awaddr_q;
  reg  [31:0]           wdata_q;
  reg  [3:0]            wstrb_q;
  reg  [1:0]            bresp_q;

  // bvalid 期间不再收新的一笔，避免把两笔写混在一起。
  assign s_axi_awready = ~aw_captured & ~wr_done;
  assign s_axi_wready  = ~w_captured  & ~wr_done;
  // 挡掉 rd_issue：读发起那一拍地址总线归读，写要让开一拍。
  assign reg_wr_o      = aw_captured & w_captured & ~wr_done & ~rd_issue;
  assign reg_wdata_o   = wdata_q;
  assign reg_wstrb_o   = wstrb_q;
  assign s_axi_bvalid  = wr_done;
  assign s_axi_bresp   = bresp_q;

  // ── 读通路 ────────────────────────────────────────────────────────────────
  reg  [ADDR_WIDTH-1:0] araddr_q;
  reg          rd_issue;
  reg          rd_wait;
  reg          rd_pending;
  reg  [31:0]  rdata_q;
  reg  [1:0]   rresp_q;

  // AR 握手后一拍才发起寄存器读：地址先落进 araddr_q，后端译码从寄存器出发。
  // 不这么做的话 s_axi_araddr 会组合穿过 23 路译码比较器、再经 halt_o 打进核的
  // 流水控制 —— 实测那正是整条关键路径的起点，AXI 引脚到 BRAM 之间没有寄存器。
  // 代价是读延迟多一拍，AXI-Lite 对延迟没有要求。
  // arready 里挡掉 reg_wr_o：读写共用一根 reg_addr_o，同拍发起会让读拿到写的地址。
  assign s_axi_arready = ~rd_issue & ~rd_wait & ~rd_pending & ~reg_wr_o;
  wire   ar_fire       = s_axi_arvalid & s_axi_arready;
  assign reg_rd_o      = rd_issue;
  assign s_axi_rdata   = rdata_q;
  assign s_axi_rresp   = rresp_q;
  assign s_axi_rvalid  = rd_pending;

  // 读写共用地址总线：读发起那一拍给缓冲住的读地址，其余时候给缓冲住的写地址。
  assign reg_addr_o    = rd_issue ? araddr_q : awaddr_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      aw_captured <= 1'b0;
      w_captured  <= 1'b0;
      wr_done     <= 1'b0;
      awaddr_q    <= {ADDR_WIDTH{1'b0}};
      wdata_q     <= 32'b0;
      wstrb_q     <= 4'b0;
      bresp_q     <= RESP_OKAY;
    end else begin
      if (s_axi_awvalid & s_axi_awready) begin
        aw_captured <= 1'b1;
        awaddr_q    <= s_axi_awaddr;
      end
      if (s_axi_wvalid & s_axi_wready) begin
        w_captured <= 1'b1;
        wdata_q    <= s_axi_wdata;
        wstrb_q    <= s_axi_wstrb;
      end
      if (reg_wr_o) begin
        wr_done <= 1'b1;
        bresp_q <= reg_wr_err_i ? RESP_SLVERR : RESP_OKAY;
      end
      // 必须等 bvalid 被接收才能清 captured：提前清会让下一笔的地址盖掉还没回完的响应。
      if (s_axi_bvalid & s_axi_bready) begin
        aw_captured <= 1'b0;
        w_captured  <= 1'b0;
        wr_done     <= 1'b0;
      end
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      araddr_q   <= {ADDR_WIDTH{1'b0}};
      rd_issue   <= 1'b0;
      rd_wait    <= 1'b0;
      rd_pending <= 1'b0;
      rdata_q    <= 32'b0;
      rresp_q    <= RESP_OKAY;
    end else begin
      if (ar_fire) begin
        araddr_q <= s_axi_araddr;
      end
      rd_issue <= ar_fire;
      rd_wait  <= rd_issue;

      if (rd_wait) begin
        // 总线约定的第二拍：数据这时才有效。
        rd_pending <= 1'b1;
        rdata_q    <= reg_rdata_i;
        rresp_q    <= reg_rd_err_i ? RESP_SLVERR : RESP_OKAY;
      end else if (s_axi_rvalid & s_axi_rready) begin
        rd_pending <= 1'b0;
      end
    end
  end

endmodule
