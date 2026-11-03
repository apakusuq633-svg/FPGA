`include "rv32_defines.vh"

module rv32_branch_unit (
  input  [31:0] pc_i,
  input  [31:0] rs1_i,
  input  [31:0] rs2_i,
  input  [31:0] imm_i,
  input  [2:0]  branch_op_i,
  input         branch_i,
  input         jal_i,
  input         jalr_i,
  output        taken_o,
  output [31:0] target_o
);

  wire eq;
  wire signed_lt;
  wire unsigned_lt;
  wire branch_taken;
  wire [31:0] direct_target;
  wire [31:0] indirect_target;

  assign eq          = (rs1_i == rs2_i);
  assign signed_lt   = ($signed(rs1_i) < $signed(rs2_i));
  assign unsigned_lt = (rs1_i < rs2_i);

  assign branch_taken = ((branch_op_i == `BR_EQ)  & eq)          |
                        ((branch_op_i == `BR_NE)  & ~eq)         |
                        ((branch_op_i == `BR_LT)  & signed_lt)   |
                        ((branch_op_i == `BR_GE)  & ~signed_lt)  |
                        ((branch_op_i == `BR_LTU) & unsigned_lt) |
                        ((branch_op_i == `BR_GEU) & ~unsigned_lt);

  assign direct_target   = pc_i + imm_i;
  assign indirect_target = (rs1_i + imm_i) & 32'hffff_fffe;
  assign taken_o         = jal_i | jalr_i | (branch_i & branch_taken);
  assign target_o        = jalr_i ? indirect_target : direct_target;

endmodule
