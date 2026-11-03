module rv_dff #(
  parameter WIDTH = 1
) (
  input                  clk_i,
  input                  en_i,
  input      [WIDTH-1:0] d_i,
  output reg [WIDTH-1:0] q_o
);

  always @(posedge clk_i) begin
    if (en_i) begin
      q_o <= d_i;
    end
  end

endmodule
