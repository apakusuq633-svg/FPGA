module rv32_imm_gen (
  input  [31:0] instr_i,
  output [31:0] imm_o
);

  wire [6:0] opcode;
  wire is_i_type;
  wire is_s_type;
  wire is_b_type;
  wire is_u_type;
  wire is_j_type;
  wire [31:0] imm_i;
  wire [31:0] imm_s;
  wire [31:0] imm_b;
  wire [31:0] imm_u;
  wire [31:0] imm_j;

  assign opcode    = instr_i[6:0];
  assign is_i_type = (opcode == 7'b0010011) |
                     (opcode == 7'b0000011) |
                     (opcode == 7'b1100111);
  assign is_s_type = (opcode == 7'b0100011);
  assign is_b_type = (opcode == 7'b1100011);
  assign is_u_type = (opcode == 7'b0110111) |
                     (opcode == 7'b0010111);
  assign is_j_type = (opcode == 7'b1101111);

  assign imm_i = {{20{instr_i[31]}}, instr_i[31:20]};
  assign imm_s = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
  assign imm_b = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                  instr_i[30:25], instr_i[11:8], 1'b0};
  assign imm_u = {instr_i[31:12], 12'b0};
  assign imm_j = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                  instr_i[20], instr_i[30:21], 1'b0};

  assign imm_o = ({32{is_i_type}} & imm_i) |
                 ({32{is_s_type}} & imm_s) |
                 ({32{is_b_type}} & imm_b) |
                 ({32{is_u_type}} & imm_u) |
                 ({32{is_j_type}} & imm_j);

endmodule
