module rv32_ras #(
  parameter DEPTH = 8,
  parameter PTR_WIDTH = 4,
  parameter INDEX_WIDTH = 3
) (
  input         clk_i,
  input         rst_n_i,
  input         test_en_i,
  input         push_i,
  input         pop_i,
  input  [31:0] push_address_i,
  output        valid_o,
  output [31:0] top_address_o
);

  reg [31:0] stack [0:DEPTH-1];
  reg [PTR_WIDTH-1:0] count;
  localparam integer LAST_INDEX = DEPTH - 1;
  wire [INDEX_WIDTH-1:0] push_index;
  wire [INDEX_WIDTH-1:0] top_index;

  assign valid_o       = (count != {PTR_WIDTH{1'b0}});
  assign push_index    = (count < DEPTH) ? count[INDEX_WIDTH-1:0] :
                         LAST_INDEX[INDEX_WIDTH-1:0];
  assign top_index     = valid_o ? count[INDEX_WIDTH-1:0] - 1'b1 :
                         {INDEX_WIDTH{1'b0}};
  assign top_address_o = valid_o ? stack[top_index] : 32'b0;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      count <= {PTR_WIDTH{1'b0}};
    end else if (push_i | pop_i | test_en_i) begin
      if (push_i) begin
        stack[push_index] <= push_address_i;
        count <= (count < DEPTH) ? count + 1'b1 : count;
      end else if (pop_i) begin
        count <= valid_o ? count - 1'b1 : count;
      end
    end
  end

endmodule
