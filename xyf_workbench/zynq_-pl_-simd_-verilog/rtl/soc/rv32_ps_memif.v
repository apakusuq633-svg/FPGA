// PS 访问 ITCM/DTCM 的窗口：自增字地址 + 块选择 + 运行期写保护。
//
// MEM_ADDR[31] 选块（0=ITCM，1=DTCM），低位是**字偏移**。读写 MEM_WDATA/MEM_RDATA
// 都会让字偏移自增，所以下载 4096 字固件只是一条紧凑的 store 循环。
//
// 写保护：核没停（既没 halt 也没软复位）时拒绝写并置粘滞错误位，地址也不动，
// 等 PS 停住核之后可以原地重试。读不设限 —— 读走 B 口、不破坏任何状态，
// 运行期观测 buffer 填充是有用的，真正会破坏一致性的是写。
//
// 读的数据在请求下一拍才回来（ITCM/DTCM 的 PS 口都是 req 后一拍出 ready/rdata），
// 所以 rdata_o 在 rd_active 那一拍直接由 ps_rdata_i 组合给出，正好落在寄存器总线
// "读数据延后一拍" 的约定上。
module rv32_ps_memif #(
  // 字偏移可用宽度 = ADDR_WIDTH-2。窄于 TCM 的 ADDR_WIDTH 时不会报错，
  // 只是自增窗口到半路就回卷 —— 表现为"固件灌进去一半"。
  parameter ADDR_WIDTH = 14
) (
  input                    clk_i,
  input                    rst_n_i,
  input                    addr_wr_i,
  input  [31:0]            addr_wdata_i,
  input                    wdata_wr_i,
  input  [31:0]            wdata_i,
  input                    rdata_rd_i,
  input                    ctrl_wr_i,
  input  [31:0]            ctrl_wdata_i,
  input                    allow_write_i,
  output [31:0]            addr_o,
  output [31:0]            wdata_o,
  output [31:0]            rdata_o,
  output [31:0]            ctrl_o,
  output                   err_o,
  output                   ps_req_o,
  output                   ps_write_o,
  output                   ps_sel_o,
  output [ADDR_WIDTH-1:0]  ps_addr_o,
  output [31:0]            ps_wdata_o,
  input                    ps_ready_i,
  input  [31:0]            ps_rdata_i
);

  localparam WORD_INDEX_WIDTH = ADDR_WIDTH - 2;

  reg  [WORD_INDEX_WIDTH-1:0] word_index_q;
  reg                         sel_q;
  reg  [31:0]                 wdata_q;
  reg                         err_q;
  reg                         rd_active;

  wire                        write_ok;
  wire [WORD_INDEX_WIDTH-1:0] word_index_d;

  // 被拒的写不自增地址，PS 停住核之后可以从同一个地址重来。
  assign write_ok     = wdata_wr_i & allow_write_i;
  assign word_index_d = word_index_q + 1'b1;

  assign addr_o   = {sel_q, {(31-WORD_INDEX_WIDTH){1'b0}}, word_index_q};
  assign wdata_o  = wdata_q;
  assign ctrl_o   = {29'b0, rd_active, err_q, 1'b0};
  assign err_o    = err_q;

  // 请求是单拍脉冲：PS 侧每次只发起一笔，AXI 从端保证同一时刻只有一笔在飞。
  assign ps_req_o   = wdata_wr_i | rdata_rd_i;
  assign ps_write_o = write_ok;
  assign ps_sel_o   = sel_q;
  assign ps_addr_o  = {word_index_q, 2'b00};
  assign ps_wdata_o = wdata_i;

  // 读数据在请求下一拍回来，那时 ps_ready_i 正高。用 ready 而不是自己数拍，是为了
  // 万一将来 TCM 的 PS 口改了延迟，这里不用跟着改。
  assign rdata_o    = ps_ready_i ? ps_rdata_i : wdata_q;

  wire idx_load;
  wire idx_clear;
  wire idx_inc;

  assign idx_load  = addr_wr_i;
  assign idx_clear = ctrl_wr_i & ctrl_wdata_i[0];
  // 自增只跟"实际发生了访问"走：写要看是否被放行（被拒的写不自增），读无条件。
  assign idx_inc   = write_ok | rdata_rd_i;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      word_index_q <= {WORD_INDEX_WIDTH{1'b0}};
      sel_q        <= 1'b0;
      wdata_q      <= 32'b0;
      err_q        <= 1'b0;
      rd_active    <= 1'b0;
    end else begin
      // 显式优先链：装载 > 归零 > 自增。总线是串行的，三者实际不会撞，写清楚是为了好读。
      if (idx_load) begin
        word_index_q <= addr_wdata_i[WORD_INDEX_WIDTH-1:0];
      end else if (idx_clear) begin
        word_index_q <= {WORD_INDEX_WIDTH{1'b0}};
      end else if (idx_inc) begin
        word_index_q <= word_index_d;
      end

      if (addr_wr_i) begin
        sel_q <= addr_wdata_i[31];
      end

      if (write_ok) begin
        wdata_q <= wdata_i;
      end

      // 被拒的写置粘滞错误位，写 MEM_CTRL[1] 清。
      if (wdata_wr_i & ~allow_write_i) begin
        err_q <= 1'b1;
      end else if (ctrl_wr_i & ctrl_wdata_i[1]) begin
        err_q <= 1'b0;
      end

      rd_active <= rdata_rd_i;
    end
  end

endmodule
