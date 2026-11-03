module rv_if_id_reg (
  input         clk_i,
  input         rst_n_i,
  input         hold_i,
  input         flush_i,
  input         valid_i,
  input  [31:0] pc_i,
  input  [31:0] instr_i,
  input         pred_taken_i,
  input  [31:0] pred_target_i,
  input  [5:0]  pht_index_i,
  output        valid_o,
  output [31:0] pc_o,
  output [31:0] instr_o,
  output        pred_taken_o,
  output [31:0] pred_target_o,
  output [5:0]  pht_index_o
);

  localparam WIDTH = 103;
  wire [WIDTH-1:0] payload_in;
  wire [WIDTH-1:0] payload_out;

  assign payload_in = {pc_i, instr_i, pred_taken_i, pred_target_i, pht_index_i};
  assign {pc_o, instr_o, pred_taken_o, pred_target_o, pht_index_o} = payload_out;

  rv_pipeline_reg #(.WIDTH(WIDTH)) u_pipeline_reg (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .hold_i    (hold_i),
    .flush_i   (flush_i),
    .valid_i   (valid_i),
    .payload_i (payload_in),
    .valid_o   (valid_o),
    .payload_o (payload_out)
  );

endmodule
