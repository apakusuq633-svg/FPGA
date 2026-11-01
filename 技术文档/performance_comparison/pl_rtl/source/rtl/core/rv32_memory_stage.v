`include "rv32_defines.vh"

module rv32_memory_stage (
  input         valid_i,
  input  [31:0] pc_i,
  input  [31:0] instr_i,
  input  [31:0] alu_result_i,
  input  [31:0] store_data_i,
  input  [31:0] pc_plus4_i,
  input  [4:0]  rd_i,
  input  [1:0]  wb_sel_i,
  input  [1:0]  mem_size_i,
  input         reg_write_i,
  input         mem_read_i,
  input         mem_write_i,
  input         load_unsigned_i,
  input  [3:0]  fault_i,
  output        dmem_req_o,
  output        dmem_write_o,
  output [31:0] dmem_addr_o,
  output [31:0] dmem_wdata_o,
  output [3:0]  dmem_wstrb_o,
  input         dmem_ready_i,
  input  [31:0] dmem_rdata_i,
  output        memory_stall_o,
  output [31:0] forward_data_o,
  output [31:0] load_data_o,
  output [4:0]  rd_o,
  output [1:0]  wb_sel_o,
  output        reg_write_o,
  output [3:0]  fault_o
);

  wire lsu_req;
  wire [31:0] lsu_load_data;
  wire misaligned;
  wire memory_operation;
  wire [3:0] align_fault;

  rv32_lsu u_lsu (
    .address_i        (alu_result_i),
    .store_data_i     (store_data_i),
    .size_i           (mem_size_i),
    .load_unsigned_i  (load_unsigned_i),
    .mem_read_i       (valid_i & mem_read_i),
    .mem_write_i      (valid_i & mem_write_i),
    .memory_rdata_i   (dmem_rdata_i),
    .memory_addr_o    (dmem_addr_o),
    .memory_wdata_o   (dmem_wdata_o),
    .memory_wstrb_o   (dmem_wstrb_o),
    .memory_req_o     (lsu_req),
    .load_data_o      (lsu_load_data),
    .misaligned_o     (misaligned)
  );

  assign memory_operation = mem_read_i | mem_write_i;
  assign dmem_req_o       = lsu_req;

  // 写只在从机应答那一拍拉高：DTCM 一个操作占两拍，否则同一笔 store 会写两次。
  assign dmem_write_o     = valid_i & mem_write_i & ~misaligned & dmem_ready_i;

  // 数据端口反压：等待拍冻结 EX/MEM 才能保住读地址，读数据与地址因此始终对齐。
  assign memory_stall_o   = valid_i & memory_operation & ~misaligned &
                            ~dmem_ready_i;
  assign align_fault      = mem_read_i ? `FAULT_LOAD_ALIGN :
                            `FAULT_ST_ALIGN;
  assign fault_o          = (fault_i != `FAULT_NONE) ? fault_i :
                            misaligned ? align_fault : `FAULT_NONE;
  assign load_data_o      = lsu_load_data;
  assign rd_o             = rd_i;
  assign wb_sel_o         = wb_sel_i;
  assign reg_write_o      = reg_write_i & ~misaligned;
  assign forward_data_o   = (wb_sel_i == `WB_MEM) ? lsu_load_data :
                            (wb_sel_i == `WB_PC4) ? pc_plus4_i : alu_result_i;

endmodule
