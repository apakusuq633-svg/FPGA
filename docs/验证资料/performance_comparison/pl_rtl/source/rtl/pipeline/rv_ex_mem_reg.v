module rv_ex_mem_reg (
  input         clk_i,
  input         rst_n_i,
  input         hold_i,
  input         valid_i,
  input  [31:0] pc_i,
  input  [31:0] instr_i,
  input  [31:0] alu_result_i,
  input  [31:0] store_data_i,
  input  [31:0] pc_plus4_i,
  input  [4:0]  rd_i,
  input  [1:0]  wb_sel_i,
  input  [1:0]  mem_size_i,
  input         reg_write_i,
  input         mem_read_i,
  input         mem_write_i,
  input         load_unsigned_i,
  input  [3:0]  fault_i,
  output        valid_o,
  output [31:0] pc_o,
  output [31:0] instr_o,
  output [31:0] alu_result_o,
  output [31:0] store_data_o,
  output [31:0] pc_plus4_o,
  output [4:0]  rd_o,
  output [1:0]  wb_sel_o,
  output [1:0]  mem_size_o,
  output        reg_write_o,
  output        mem_read_o,
  output        mem_write_o,
  output        load_unsigned_o,
  output [3:0]  fault_o
);

  localparam WIDTH = 177;
  wire [WIDTH-1:0] payload_in;
  wire [WIDTH-1:0] payload_out;

  assign payload_in = {
    pc_i, instr_i, alu_result_i, store_data_i, pc_plus4_i, rd_i, wb_sel_i,
    mem_size_i, reg_write_i, mem_read_i, mem_write_i, load_unsigned_i, fault_i
  };
  assign {
    pc_o, instr_o, alu_result_o, store_data_o, pc_plus4_o, rd_o, wb_sel_o,
    mem_size_o, reg_write_o, mem_read_o, mem_write_o, load_unsigned_o, fault_o
  } = payload_out;

  rv_pipeline_reg #(.WIDTH(WIDTH)) u_pipeline_reg (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .hold_i    (hold_i),
    .flush_i   (1'b0),
    .valid_i   (valid_i),
    .payload_i (payload_in),
    .valid_o   (valid_o),
    .payload_o (payload_out)
  );

endmodule
