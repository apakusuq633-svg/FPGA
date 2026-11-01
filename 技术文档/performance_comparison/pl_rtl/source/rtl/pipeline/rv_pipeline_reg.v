module rv_pipeline_reg #(
  parameter WIDTH = 1
) (
  input              clk_i,
  input              rst_n_i,
  input              hold_i,
  input              flush_i,
  input              valid_i,
  input  [WIDTH-1:0] payload_i,
  output             valid_o,
  output [WIDTH-1:0] payload_o
);

  wire load_en;
  wire valid_d;

  assign load_en = ~hold_i;
  assign valid_d = flush_i ? 1'b0 : valid_i;

  rv_dffr #(
    .WIDTH       (1),
    .RESET_VALUE (1'b0)
  ) u_valid_dff (
    .clk_i   (clk_i),
    .rst_n_i (rst_n_i),
    .en_i    (load_en),
    .d_i     (valid_d),
    .q_o     (valid_o)
  );

  rv_dff #(
    .WIDTH (WIDTH)
  ) u_payload_dff (
    .clk_i (clk_i),
    .en_i  (load_en),
    .d_i   (payload_i),
    .q_o   (payload_o)
  );

endmodule
