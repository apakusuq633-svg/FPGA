`include "rv32_defines.vh"

module rv32_lsu (
  input  [31:0] address_i,
  input  [31:0] store_data_i,
  input  [1:0]  size_i,
  input         load_unsigned_i,
  input         mem_read_i,
  input         mem_write_i,
  input  [31:0] memory_rdata_i,
  output [31:0] memory_addr_o,
  output [31:0] memory_wdata_o,
  output [3:0]  memory_wstrb_o,
  output        memory_req_o,
  output [31:0] load_data_o,
  output        misaligned_o
);

  wire byte_access;
  wire half_access;
  wire word_access;
  wire [4:0] shift_amount;
  wire [31:0] shifted_rdata;
  wire [7:0] selected_byte;
  wire [15:0] selected_half;
  wire [31:0] byte_extended;
  wire [31:0] half_extended;

  assign byte_access = (size_i == `MEM_BYTE);
  assign half_access = (size_i == `MEM_HALF);
  assign word_access = (size_i == `MEM_WORD);
  assign misaligned_o = (mem_read_i | mem_write_i) &
                        ((half_access & address_i[0]) |
                         (word_access & (|address_i[1:0])));

  assign memory_addr_o  = {address_i[31:2], 2'b00};
  assign memory_req_o   = (mem_read_i | mem_write_i) & ~misaligned_o;
  assign memory_wdata_o = store_data_i << {address_i[1:0], 3'b000};
  assign memory_wstrb_o = mem_write_i & ~misaligned_o ?
                          (byte_access ? (4'b0001 << address_i[1:0]) :
                           half_access ? (4'b0011 << address_i[1:0]) :
                                         4'b1111) : 4'b0000;

  assign shift_amount  = {address_i[1:0], 3'b000};
  assign shifted_rdata = memory_rdata_i >> shift_amount;
  assign selected_byte = shifted_rdata[7:0];
  assign selected_half = shifted_rdata[15:0];
  assign byte_extended = load_unsigned_i ? {24'b0, selected_byte} :
                         {{24{selected_byte[7]}}, selected_byte};
  assign half_extended = load_unsigned_i ? {16'b0, selected_half} :
                         {{16{selected_half[15]}}, selected_half};
  assign load_data_o = byte_access ? byte_extended :
                       half_access ? half_extended : memory_rdata_i;

endmodule
