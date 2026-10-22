module rv32_pht_gshare #(
  parameter INDEX_WIDTH = 6,
  parameter ENTRY_NUM = 64
) (
  input                    clk_i,
  input                    rst_n_i,
  input                    test_en_i,
  input  [31:0]            lookup_pc_i,
  output [INDEX_WIDTH-1:0] lookup_index_o,
  output                   predict_taken_o,
  input                    update_valid_i,
  input  [INDEX_WIDTH-1:0] update_index_i,
  input                    update_taken_i
);

  reg [1:0] pht [0:ENTRY_NUM-1];
  reg [INDEX_WIDTH-1:0] ghr;
  wire [1:0] old_counter;
  wire [1:0] incremented_counter;
  wire [1:0] decremented_counter;
  wire [1:0] next_counter;
  integer i;

  assign lookup_index_o = lookup_pc_i[INDEX_WIDTH+1:2] ^ ghr;
  assign predict_taken_o = pht[lookup_index_o][1];
  assign old_counter = pht[update_index_i];
  assign incremented_counter = (old_counter == 2'b11) ? 2'b11 :
                               old_counter + 2'b01;
  assign decremented_counter = (old_counter == 2'b00) ? 2'b00 :
                               old_counter - 2'b01;
  assign next_counter = update_taken_i ? incremented_counter :
                        decremented_counter;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      ghr <= {INDEX_WIDTH{1'b0}};
      for (i = 0; i < ENTRY_NUM; i = i + 1) begin
        pht[i] <= 2'b01;
      end
    end else if (update_valid_i | test_en_i) begin
      pht[update_index_i] <= next_counter;
      ghr <= {ghr[INDEX_WIDTH-2:0], update_taken_i};
    end
  end

endmodule
