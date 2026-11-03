// M 扩展的乘法器：一个无符号 32×32 加符号修正，四条乘法指令共用。
//
// 低半字与符号无关，mul 直接用。高半字按
//   a_s·b_s ≡ a_u·b_u − (a[31]?b_u:0)·2^32 − (b[31]?a_u:0)·2^32  (mod 2^64)
// 修正项只落在高半字，所以高低分开算，综合工具只需要一套 DSP48。
// 写成四个独立的 $signed 乘法 Vivado 不会帮你共享，会推四套。
module rv32_mul_unit (
  input  [31:0] operand_a_i,
  input  [31:0] operand_b_i,
  input         a_signed_i,
  input         b_signed_i,
  output [31:0] lo_o,
  output [31:0] hi_o
);

  (* use_dsp = "yes" *) wire [63:0] product;

  assign product = operand_a_i * operand_b_i;

  // mulh 两个修正全开，mulhsu 只开 rs1 那个，mulhu 和 mul 都不开。
  wire [31:0] a_fix;
  wire [31:0] b_fix;

  assign a_fix = (a_signed_i & operand_a_i[31]) ? operand_b_i : 32'b0;
  assign b_fix = (b_signed_i & operand_b_i[31]) ? operand_a_i : 32'b0;

  assign lo_o = product[31:0];
  assign hi_o = product[63:32] - (a_fix + b_fix);

endmodule
