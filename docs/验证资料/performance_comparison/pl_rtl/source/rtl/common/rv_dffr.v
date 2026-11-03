module rv_dffr #(
  parameter WIDTH = 1,
  parameter [WIDTH-1:0] RESET_VALUE = {WIDTH{1'b0}}
) (
  input                  clk_i,
  input                  rst_n_i,
  input                  en_i,
  input      [WIDTH-1:0] d_i,
  output reg [WIDTH-1:0] q_o
);

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      q_o <= RESET_VALUE;
    end else if (en_i) begin
      q_o <= d_i;
    end
  end

endmodule
