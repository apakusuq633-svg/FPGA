module rv32_regfile (
  input         clk_i,
  input         write_en_i,
  input  [4:0]  write_addr_i,
  input  [31:0] write_data_i,
  input  [4:0]  read_addr1_i,
  input  [4:0]  read_addr2_i,
  output [31:0] read_data1_o,
  output [31:0] read_data2_o,
  output [31:0] ra_value_o
);

  reg [31:0] registers [0:31];
  wire write_valid;
  wire bypass_rs1;
  wire bypass_rs2;
  wire bypass_ra;

  assign write_valid = write_en_i & (write_addr_i != 5'd0);

  always @(posedge clk_i) begin
    if (write_valid) begin
      registers[write_addr_i] <= write_data_i;
    end
  end

  assign bypass_rs1 = write_valid & (write_addr_i == read_addr1_i);
  assign bypass_rs2 = write_valid & (write_addr_i == read_addr2_i);
  assign bypass_ra  = write_valid & (write_addr_i == 5'd1);

  assign read_data1_o = (read_addr1_i == 5'd0) ? 32'b0 :
                        bypass_rs1 ? write_data_i : registers[read_addr1_i];
  assign read_data2_o = (read_addr2_i == 5'd0) ? 32'b0 :
                        bypass_rs2 ? write_data_i : registers[read_addr2_i];
  assign ra_value_o   = bypass_ra ? write_data_i : registers[1];

endmodule
