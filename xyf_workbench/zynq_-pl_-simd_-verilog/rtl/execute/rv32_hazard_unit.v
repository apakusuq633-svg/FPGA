module rv32_hazard_unit (
  input        id_valid_i,
  input        id_uses_rs1_i,
  input        id_uses_rs2_i,
  input [4:0]  id_rs1_i,
  input [4:0]  id_rs2_i,
  input        ex_valid_i,
  input        ex_mem_read_i,
  input [4:0]  ex_rd_i,
  output       load_use_stall_o
);

  wire rs1_hazard;
  wire rs2_hazard;

  assign rs1_hazard = id_uses_rs1_i & (id_rs1_i == ex_rd_i);
  assign rs2_hazard = id_uses_rs2_i & (id_rs2_i == ex_rd_i);
  assign load_use_stall_o = id_valid_i & ex_valid_i & ex_mem_read_i &
                            (ex_rd_i != 5'd0) & (rs1_hazard | rs2_hazard);

endmodule
