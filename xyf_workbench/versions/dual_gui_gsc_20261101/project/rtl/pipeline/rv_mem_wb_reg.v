module rv_mem_wb_reg (
  input         clk_i,
  input         rst_n_i,
  // hold 期间本级的 valid 与 payload 一起冻结（不是清零）。
  // 为什么要 hold 而不是清 valid：docs/issues/030 —— 访存停顿若把 WB 的 valid 清掉，
  // 卡在 EX 的消费者就失去了这一级前递，而 EX/MEM 里往往是不写寄存器的那条 store，
  // 两级同时落空 → 读到过期寄存器值。
  input         hold_i,
  input         valid_i,
  input  [31:0] pc_i,
  input  [31:0] instr_i,
  input  [31:0] alu_result_i,
  input  [31:0] load_data_i,
  input  [31:0] pc_plus4_i,
  input  [4:0]  rd_i,
  input  [1:0]  wb_sel_i,
  input         reg_write_i,
  input  [3:0]  fault_i,
  output        valid_o,
  output [31:0] pc_o,
  output [31:0] instr_o,
  output [31:0] alu_result_o,
  output [31:0] load_data_o,
  output [31:0] pc_plus4_o,
  output [4:0]  rd_o,
  output [1:0]  wb_sel_o,
  output        reg_write_o,
  output [3:0]  fault_o
);

  localparam WIDTH = 172;
  wire [WIDTH-1:0] payload_in;
  wire [WIDTH-1:0] payload_out;

  assign payload_in = {
    pc_i, instr_i, alu_result_i, load_data_i, pc_plus4_i, rd_i, wb_sel_i,
    reg_write_i, fault_i
  };
  assign {
    pc_o, instr_o, alu_result_o, load_data_o, pc_plus4_o, rd_o, wb_sel_o,
    reg_write_o, fault_o
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
