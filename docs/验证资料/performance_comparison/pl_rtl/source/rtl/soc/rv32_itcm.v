// ITCM：真双口同步读指令存储器（BRAM 风格）。
//
// A 口给核：地址本拍采样，读数下一拍出现在 rdata_o；ready_o 是 req_i 打一拍。
//   取指级在 ready 为低期间保持 PC，地址因此稳定，rdata_o 恒等于 mem[pc_q]。
// B 口给 PS：读写各一路，PS 侧保证每次请求只拉高 req 一拍。
//   读的时序同 A 口（隔拍出数）；写在 ps_req_i 当拍直接生效，不经 ready 门控。
//   两口的读写都在同一个 always 块之外分端口描述，才能被推断成一块 TDP BRAM。
//
// 两个 rdata_q 都故意不加复位，否则综合不会把它们打包进 BRAM 的输出寄存器。
module rv32_itcm #(
  // WORDS 必须等于 2^(ADDR_WIDTH-2)：只改一个不会报错，只会静默失效
  // （索引位宽不够 → 大半数组访问不到；数组太小 → 越界读出 X）。
  parameter WORDS = 4096,
  parameter ADDR_WIDTH = 14,
  parameter MEM_FILE = ""
) (
  input                   clk_i,
  input                   rst_n_i,
  input                   req_i,
  input  [ADDR_WIDTH-1:0] addr_i,
  output                  ready_o,
  output [31:0]           rdata_o,
  input                   ps_req_i,
  input                   ps_write_i,
  input  [ADDR_WIDTH-1:0] ps_addr_i,
  input  [31:0]           ps_wdata_i,
  input  [3:0]            ps_wstrb_i,
  output                  ps_ready_o,
  output [31:0]           ps_rdata_o
);

  reg [31:0] memory [0:WORDS-1];
  reg [31:0] rdata_q;
  reg [31:0] ps_rdata_q;
  reg        ready_q;
  reg        ps_ready_q;
  wire [ADDR_WIDTH-3:0] word_index;
  wire [ADDR_WIDTH-3:0] ps_word_index;

  assign word_index    = addr_i[ADDR_WIDTH-1:2];
  assign ps_word_index = ps_addr_i[ADDR_WIDTH-1:2];

  // A 口：核取指，只读。
  always @(posedge clk_i) begin
    rdata_q <= memory[word_index];
  end

  // B 口：PS 读写。写按字节使能，读与写在同一块里（TDP 的 B 口模板）。
  //
  // 写必须带上 ps_req_i，和 rv32_dtcm 的 ps_write_enable 对齐。rv32_soc 只把
  // ps_req_i 按 ps_sel_i 分给两块 TCM，ps_write_i 是共用的、不带选块信息 ——
  // 漏掉 req 就等于把选块信号丢掉：PS 每写一次 DTCM，ITCM 的同一个字号会被一起
  // 写掉，而且一声不响。现象是核取到被改写的指令后乱跑（全 0 是非法指令，
  // mtvec 又是 0，于是 PC 原地打转），从波形上看不出是存储器被串写。
  wire ps_write_enable = ps_req_i & ps_write_i;

  always @(posedge clk_i) begin
    if (ps_write_enable & ps_wstrb_i[0]) begin
      memory[ps_word_index][7:0] <= ps_wdata_i[7:0];
    end
    if (ps_write_enable & ps_wstrb_i[1]) begin
      memory[ps_word_index][15:8] <= ps_wdata_i[15:8];
    end
    if (ps_write_enable & ps_wstrb_i[2]) begin
      memory[ps_word_index][23:16] <= ps_wdata_i[23:16];
    end
    if (ps_write_enable & ps_wstrb_i[3]) begin
      memory[ps_word_index][31:24] <= ps_wdata_i[31:24];
    end
    ps_rdata_q <= memory[ps_word_index];
  end

  // A 口的 ready 与数据同步延后一拍：req 有效的下一拍 ready 才有效。
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      ready_q <= 1'b0;
    end else begin
      ready_q <= req_i;
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      ps_ready_q <= 1'b0;
    end else begin
      ps_ready_q <= ps_req_i;
    end
  end

  assign ready_o    = ready_q;
  assign rdata_o    = rdata_q;
  assign ps_ready_o = ps_ready_q;
  assign ps_rdata_o = ps_rdata_q;

  initial begin
    if (MEM_FILE != "") begin
      $readmemh(MEM_FILE, memory);
    end
  end

endmodule
