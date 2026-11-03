`include "rv32_defines.vh"

module rv32_writeback_stage (
  input         valid_i,
  input  [31:0] alu_result_i,
  input  [31:0] load_data_i,
  input  [31:0] pc_plus4_i,
  input  [4:0]  rd_i,
  input  [1:0]  wb_sel_i,
  input         reg_write_i,
  input  [3:0]  fault_i,
  output        write_en_o,
  output [4:0]  write_addr_o,
  output [31:0] write_data_o
);

  assign write_data_o = (wb_sel_i == `WB_MEM) ? load_data_i :
                        (wb_sel_i == `WB_PC4) ? pc_plus4_i : alu_result_i;
  assign write_en_o   = valid_i & reg_write_i &
                        (fault_i == `FAULT_NONE) & (rd_i != 5'd0);
  assign write_addr_o = rd_i;

endmodule
