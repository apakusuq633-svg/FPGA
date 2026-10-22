`include "rv32_defines.vh"

module rv32_alu (
  input  [31:0] operand_a_i,
  input  [31:0] operand_b_i,
  input  [4:0]  alu_op_i,
  output [31:0] result_o
);

  wire [31:0] add_result;
  wire [31:0] sub_result;
  wire [31:0] sll_result;
  wire [31:0] slt_result;
  wire [31:0] sltu_result;
  wire [31:0] xor_result;
  wire [31:0] srl_result;
  wire [31:0] sra_result;
  wire [31:0] or_result;
  wire [31:0] and_result;
  wire [31:0] mul_lo;
  wire [31:0] mul_hi;
  wire        mul_a_signed;
  wire        mul_b_signed;
  wire        mul_hi_sel;

  assign add_result  = operand_a_i + operand_b_i;
  assign sub_result  = operand_a_i - operand_b_i;
  assign sll_result  = operand_a_i << operand_b_i[4:0];
  assign slt_result  = {31'b0, $signed(operand_a_i) < $signed(operand_b_i)};
  assign sltu_result = {31'b0, operand_a_i < operand_b_i};
  assign xor_result  = operand_a_i ^ operand_b_i;
  assign srl_result  = operand_a_i >> operand_b_i[4:0];
  assign sra_result  = $signed(operand_a_i) >>> operand_b_i[4:0];
  assign or_result   = operand_a_i | operand_b_i;
  assign and_result  = operand_a_i & operand_b_i;

  // mulh 两个操作数都按有符号，mulhsu 只有 rs1 按有符号，mulhu 和 mul 都按无符号。
  assign mul_a_signed = (alu_op_i == `ALU_MULH) | (alu_op_i == `ALU_MULHSU);
  assign mul_b_signed = (alu_op_i == `ALU_MULH);
  // 四条乘法里只有 mul 取低半字，另外三条都取高半字。
  assign mul_hi_sel   = (alu_op_i == `ALU_MULH) | (alu_op_i == `ALU_MULHU) |
                        (alu_op_i == `ALU_MULHSU);

  rv32_mul_unit u_mul_unit (
    .operand_a_i (operand_a_i),
    .operand_b_i (operand_b_i),
    .a_signed_i  (mul_a_signed),
    .b_signed_i  (mul_b_signed),
    .lo_o        (mul_lo),
    .hi_o        (mul_hi)
  );

  // 除法四条不在这里算（rv32_div_unit 多拍出结果，由 EX 级选择），掩码全落空即为 0。
  assign result_o = ({32{alu_op_i == `ALU_ADD}}  & add_result)  |
                    ({32{alu_op_i == `ALU_SUB}}  & sub_result)  |
                    ({32{alu_op_i == `ALU_SLL}}  & sll_result)  |
                    ({32{alu_op_i == `ALU_SLT}}  & slt_result)  |
                    ({32{alu_op_i == `ALU_SLTU}} & sltu_result) |
                    ({32{alu_op_i == `ALU_XOR}}  & xor_result)  |
                    ({32{alu_op_i == `ALU_SRL}}  & srl_result)  |
                    ({32{alu_op_i == `ALU_SRA}}  & sra_result)  |
                    ({32{alu_op_i == `ALU_OR}}   & or_result)   |
                    ({32{alu_op_i == `ALU_AND}}  & and_result)  |
                    ({32{alu_op_i == `ALU_MUL}}  & mul_lo)      |
                    ({32{mul_hi_sel}}            & mul_hi);

endmodule
