module rv32_btb #(
  parameter ENTRY_NUM = 32,
  parameter INDEX_WIDTH = 5
) (
  input         clk_i,
  input         rst_n_i,
  input         test_en_i,
  input  [31:0] lookup_pc_i,
  output        hit_o,
  output [31:0] target_o,
  input         update_valid_i,
  input  [31:0] update_pc_i,
  input  [31:0] update_target_i
);

  localparam TAG_WIDTH = 32 - INDEX_WIDTH - 2;

  reg [ENTRY_NUM-1:0] valid_array;
  reg [TAG_WIDTH-1:0] tag_array [0:ENTRY_NUM-1];
  reg [31:0] target_array [0:ENTRY_NUM-1];
  wire [INDEX_WIDTH-1:0] lookup_index;
  wire [INDEX_WIDTH-1:0] update_index;
  wire [TAG_WIDTH-1:0] lookup_tag;
  wire [TAG_WIDTH-1:0] update_tag;

  assign lookup_index = lookup_pc_i[INDEX_WIDTH+1:2];
  assign update_index = update_pc_i[INDEX_WIDTH+1:2];
  assign lookup_tag   = lookup_pc_i[31:INDEX_WIDTH+2];
  assign update_tag   = update_pc_i[31:INDEX_WIDTH+2];
  assign hit_o        = valid_array[lookup_index] &
                        (tag_array[lookup_index] == lookup_tag);
  assign target_o     = target_array[lookup_index];

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      valid_array <= {ENTRY_NUM{1'b0}};
    end else if (update_valid_i | test_en_i) begin
      valid_array[update_index]  <= 1'b1;
      tag_array[update_index]    <= update_tag;
      target_array[update_index] <= update_target_i;
    end
  end

endmodule
