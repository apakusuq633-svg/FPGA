// 向量阵列的一个 bank：简单双口（1 读 1 写），同步读。
//
// 为什么是「每个 lane 一个 bank」而不是「一块大存储器 + 多路选择」：阵列每拍要同时取
// 8 个抽头，一块存储器一拍只吐一个数。拆成 per-lane 的 bank 之后，8 个 bank 各自有
// 独立地址口，一拍就能并行取 8 个——而且它们**读的是同一个字地址**（见 rv32_vec_unit
// 的抽头映射），是广播而不是 8 路独立寻址。
//
// 强制 ram_style = "block"：不加的话综合器会按容量挑，128 字 × 24 位这个尺寸它多半
// 会推成分布式 RAM（LUTRAM），而 LUTRAM 用的正是本项目最紧的 Slice 资源（实测已用
// 61.48%）。进 BRAM 只花 BRAM 列，那边现在才 8/60。
module rv32_vec_bank #(
  parameter integer AW = 9,     // 字数 = 2^AW
  parameter integer DW = 32
) (
  input               clk_i,
  input               we_i,
  input  [AW-1:0]     waddr_i,
  input  [DW-1:0]     wdata_i,
  input  [AW-1:0]     raddr_i,
  output reg [DW-1:0] rdata_o
);

  (* ram_style = "block" *)
  reg [DW-1:0] mem_q [0:(1<<AW)-1];

  // 读口不接复位：和 rv32_itcm/rv32_dtcm 同一个理由 —— 带复位的输出寄存器
  // 常常让综合器放弃把输出打包进 BRAM 而改成 fabric 触发器。
  always @(posedge clk_i) begin
    if (we_i) begin
      mem_q[waddr_i] <= wdata_i;
    end
    rdata_o <= mem_q[raddr_i];
  end

endmodule
