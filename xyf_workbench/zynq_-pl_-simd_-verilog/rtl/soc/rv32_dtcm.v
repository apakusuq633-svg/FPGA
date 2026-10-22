// DTCM：真双口同步读数据存储器（BRAM 风格），读延迟一拍，带字节写使能。
//
// A 口给核：一个访存在 EX/MEM 里占两拍 —— 第 1 拍 ready_o=0（等待拍，memory_stall
//   冻结 EX/MEM 保住地址），第 2 拍 ready_o=1（应答拍，rdata_o 有效、操作退休）。
//   ready 必须是隔拍应答（req_i & ~ready_q），不能照抄 rv32_itcm 的 ready_q <= req_i：
//   ITCM 的地址和 PC 同沿更新所以天然稳定，DTCM 的地址来自 EX/MEM、只在被冻结时才稳定；
//   照抄会让背靠背访存的第 2 个操作在 req 持续为高时就看到 ready=1，而 rdata_q 里还是
//   上一个操作地址的数据 —— 静默串数据，波形完全正常。
//   核侧写由 dmem_write_o 用 & dmem_ready_i 限定在应答拍，本模块不重复门控 ——
//   重复门控会掩盖主机侧那道门控被删掉，tb 的写周期计数器就抓不到了。
// B 口给 PS：读写各一路，PS 侧保证每次请求只拉高 req 一拍。
//   读的时序同 A 口（隔拍出数）；写在 ps_req_i 当拍直接生效，不经 ready 门控。
//   两口的读写都在同一个 always 块之外分端口描述，才能被推断成一块 TDP BRAM。
//
// 读写同拍同地址读到旧值（READ_FIRST，读写同块且非阻塞），单发射下是 don't-care。
// 两个 rdata_q 不加复位（否则推断不出 BRAM），两个 ready_q 必须异步复位。
module rv32_dtcm #(
  // 同 rv32_itcm：WORDS 必须等于 2^(ADDR_WIDTH-2)，改一个忘另一个是静默失效。
  parameter WORDS = 4096,
  parameter ADDR_WIDTH = 14,
  parameter MEM_FILE = ""
) (
  input                   clk_i,
  input                   rst_n_i,
  input                   req_i,
  input                   write_i,
  input  [ADDR_WIDTH-1:0] addr_i,
  input  [31:0]           wdata_i,
  input  [3:0]            wstrb_i,
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

  (* ram_style = "block" *) reg [31:0] memory [0:WORDS-1];
  reg [31:0] rdata_q;
  reg [31:0] ps_rdata_q;
  reg        ready_q;
  reg        ps_ready_q;
  wire [ADDR_WIDTH-3:0] word_index;
  wire [ADDR_WIDTH-3:0] ps_word_index;
  wire write_enable;
  wire ps_write_enable;

  assign word_index    = addr_i[ADDR_WIDTH-1:2];
  assign ps_word_index = ps_addr_i[ADDR_WIDTH-1:2];

  // A 口：核访存。读写同块、非阻塞赋值 → READ_FIRST；四个字节通道对应 BRAM 的字节写使能。
  always @(posedge clk_i) begin
    if (write_enable & wstrb_i[0]) begin
      memory[word_index][7:0] <= wdata_i[7:0];
    end
    if (write_enable & wstrb_i[1]) begin
      memory[word_index][15:8] <= wdata_i[15:8];
    end
    if (write_enable & wstrb_i[2]) begin
      memory[word_index][23:16] <= wdata_i[23:16];
    end
    if (write_enable & wstrb_i[3]) begin
      memory[word_index][31:24] <= wdata_i[31:24];
    end
    rdata_q <= memory[word_index];
  end

  // B 口：PS 读写。与 A 口同块不同端口，构成 TDP。
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

  // 隔拍应答：req 保持期间 0/1 交替，同一请求只应答一次，应答完必回 0。
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      ready_q <= 1'b0;
    end else begin
      ready_q <= req_i & ~ready_q;
    end
  end

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      ps_ready_q <= 1'b0;
    end else begin
      ps_ready_q <= ps_req_i & ~ps_ready_q;
    end
  end

  assign write_enable    = req_i & write_i;
  assign ps_write_enable = ps_req_i & ps_write_i;
  assign ready_o         = ready_q;
  assign rdata_o         = rdata_q;
  assign ps_ready_o      = ps_ready_q;
  assign ps_rdata_o      = ps_rdata_q;

  initial begin
    if (MEM_FILE != "") begin
      $readmemh(MEM_FILE, memory);
    end
  end

endmodule
