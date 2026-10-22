`include "rv32_defines.vh"

module rv32_decode_stage (
  input         clk_i,
  input  [31:0] instr_i,
  input  [31:0] pc_i,
  input         pred_taken_i,
  input  [31:0] pred_target_i,
  input  [5:0]  pht_index_i,
  input         wb_write_en_i,
  input  [4:0]  wb_write_addr_i,
  input  [31:0] wb_write_data_i,
  output [31:0] rs1_value_o,
  output [31:0] rs2_value_o,
  output [31:0] imm_o,
  output [4:0]  rs1_o,
  output [4:0]  rs2_o,
  output [4:0]  rd_o,
  output [4:0]  alu_op_o,
  output [2:0]  branch_op_o,
  output [1:0]  wb_sel_o,
  output [1:0]  mem_size_o,
  output        op_a_pc_o,
  output        op_a_zero_o,
  output        op_b_imm_o,
  output        uses_rs1_o,
  output        uses_rs2_o,
  output        reg_write_o,
  output        mem_read_o,
  output        mem_write_o,
  output        load_unsigned_o,
  output        branch_o,
  output        jal_o,
  output        jalr_o,
  output        is_call_o,
  output        is_return_o,
  output        mret_o,
  output        csr_valid_o,
  output [11:0] csr_addr_o,
  output [1:0]  csr_op_o,
  output        csr_imm_o,
  output        csr_write_o,
  output        pred_taken_o,
  output [31:0] pred_target_o,
  output [5:0]  pht_index_o,
  output [3:0]  fault_o,
  output [31:0] ra_value_o
);

  wire illegal;
  wire ecall;
  wire ebreak;

  rv32_decoder u_decoder (
    .instr_i          (instr_i),
    .rs1_o            (rs1_o),
    .rs2_o            (rs2_o),
    .rd_o             (rd_o),
    .imm_o            (imm_o),
    .alu_op_o         (alu_op_o),
    .branch_op_o      (branch_op_o),
    .wb_sel_o         (wb_sel_o),
    .mem_size_o       (mem_size_o),
    .op_a_pc_o        (op_a_pc_o),
    .op_a_zero_o      (op_a_zero_o),
    .op_b_imm_o       (op_b_imm_o),
    .uses_rs1_o       (uses_rs1_o),
    .uses_rs2_o       (uses_rs2_o),
    .reg_write_o      (reg_write_o),
    .mem_read_o       (mem_read_o),
    .mem_write_o      (mem_write_o),
    .load_unsigned_o  (load_unsigned_o),
    .branch_o         (branch_o),
    .jal_o            (jal_o),
    .jalr_o           (jalr_o),
    .is_call_o        (is_call_o),
    .is_return_o      (is_return_o),
    .ecall_o          (ecall),
    .ebreak_o         (ebreak),
    .mret_o           (mret_o),
    .csr_valid_o      (csr_valid_o),
    .csr_addr_o       (csr_addr_o),
    .csr_op_o         (csr_op_o),
    .csr_imm_o        (csr_imm_o),
    .csr_write_o      (csr_write_o),
    .illegal_o        (illegal)
  );

  rv32_regfile u_regfile (
    .clk_i         (clk_i),
    .write_en_i    (wb_write_en_i),
    .write_addr_i  (wb_write_addr_i),
    .write_data_i  (wb_write_data_i),
    .read_addr1_i  (rs1_o),
    .read_addr2_i  (rs2_o),
    .read_data1_o  (rs1_value_o),
    .read_data2_o  (rs2_value_o),
    .ra_value_o    (ra_value_o)
  );

  assign pred_taken_o  = pred_taken_i;
  assign pred_target_o = pred_target_i;
  assign pht_index_o   = pht_index_i;
  assign fault_o       = illegal ? `FAULT_ILLEGAL :
                         ecall   ? `FAULT_ECALL :
                         ebreak  ? `FAULT_EBREAK : `FAULT_NONE;

endmodule
