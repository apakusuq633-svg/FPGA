module rv32_forward_unit (
  input  [4:0]  rs1_i,
  input  [4:0]  rs2_i,
  input  [31:0] rs1_data_i,
  input  [31:0] rs2_data_i,
  input         exmem_write_i,
  input  [4:0]  exmem_rd_i,
  input  [31:0] exmem_data_i,
  input         memwb_write_i,
  input  [4:0]  memwb_rd_i,
  input  [31:0] memwb_data_i,
  output [31:0] rs1_forward_o,
  output [31:0] rs2_forward_o
);

  wire exmem_rs1_match;
  wire exmem_rs2_match;
  wire memwb_rs1_match;
  wire memwb_rs2_match;

  assign exmem_rs1_match = exmem_write_i & (exmem_rd_i != 5'd0) &
                           (exmem_rd_i == rs1_i);
  assign exmem_rs2_match = exmem_write_i & (exmem_rd_i != 5'd0) &
                           (exmem_rd_i == rs2_i);
  assign memwb_rs1_match = memwb_write_i & (memwb_rd_i != 5'd0) &
                           (memwb_rd_i == rs1_i);
  assign memwb_rs2_match = memwb_write_i & (memwb_rd_i != 5'd0) &
                           (memwb_rd_i == rs2_i);

  assign rs1_forward_o = exmem_rs1_match ? exmem_data_i :
                         memwb_rs1_match ? memwb_data_i : rs1_data_i;
  assign rs2_forward_o = exmem_rs2_match ? exmem_data_i :
                         memwb_rs2_match ? memwb_data_i : rs2_data_i;

endmodule
