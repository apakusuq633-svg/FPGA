`include "rv32_defines.vh"

module rv32_execute_stage (
  input         valid_i,
  input  [31:0] pc_i,
  input  [31:0] instr_i,
  input  [31:0] rs1_value_i,
  input  [31:0] rs2_value_i,
  input  [31:0] imm_i,
  input  [4:0]  rs1_i,
  input  [4:0]  rs2_i,
  input  [4:0]  rd_i,
  input  [4:0]  alu_op_i,
  input  [2:0]  branch_op_i,
  input  [1:0]  wb_sel_i,
  input  [1:0]  mem_size_i,
  input         op_a_pc_i,
  input         op_a_zero_i,
  input         op_b_imm_i,
  input         reg_write_i,
  input         mem_read_i,
  input         mem_write_i,
  input         load_unsigned_i,
  input         branch_i,
  input         jal_i,
  input         jalr_i,
  input         is_call_i,
  input         is_return_i,
  input         pred_taken_i,
  input  [31:0] pred_target_i,
  input  [5:0]  pht_index_i,
  input  [3:0]  fault_i,
  input         csr_valid_i,
  input  [11:0] csr_addr_i,
  input  [1:0]  csr_op_i,
  input         csr_imm_i,
  input         csr_write_i,
  input  [31:0] csr_rdata_i,
  input         exmem_write_i,
  input  [4:0]  exmem_rd_i,
  input  [31:0] exmem_forward_data_i,
  input         memwb_write_i,
  input  [4:0]  memwb_rd_i,
  input  [31:0] memwb_forward_data_i,
  input  [31:0] div_result_i,
  input         div_done_i,
  output [31:0] div_a_o,
  output [31:0] div_b_o,
  // 向量阵列（OP-V）的结果与完成标志。和除法一样住在核里、不在 EX 级里，
  // 这样 EX 仍然保持纯组合、无时钟端口。
  input  [31:0] vec_result_i,
  input         vec_done_i,
  output [31:0] vec_scalar_o,
  // 声学扩展单元（funct3[2]=1 那半边）的结果与完成标志，同一套形状。
  input  [31:0] acou_result_i,
  input         acou_done_i,
  output [31:0] acou_scalar_o,
  // VFFT（核内 FFT 单元）的结果与完成标志，同一套形状。
  input  [31:0] fft_result_i,
  input         fft_done_i,
  output [31:0] fft_scalar_o,
  output [31:0] alu_result_o,
  output [31:0] store_data_o,
  output [31:0] pc_plus4_o,
  output [4:0]  rd_o,
  output [1:0]  wb_sel_o,
  output [1:0]  mem_size_o,
  output        reg_write_o,
  output        mem_read_o,
  output        mem_write_o,
  output        load_unsigned_o,
  output [3:0]  fault_o,
  output [11:0] csr_addr_o,
  output        csr_we_o,
  output [31:0] csr_wdata_o,
  output        redirect_o,
  output [31:0] redirect_pc_o,
  output        bp_update_valid_o,
  output [31:0] bp_update_pc_o,
  output [31:0] bp_update_target_o,
  output [5:0]  bp_update_pht_index_o,
  output        bp_update_taken_o,
  output        bp_update_branch_o,
  output        bp_update_call_o,
  output        bp_update_return_o,
  output [31:0] bp_update_return_address_o
);

  wire [31:0] forwarded_rs1;
  wire [31:0] forwarded_rs2;
  wire [31:0] operand_a;
  wire [31:0] operand_b;
  wire actual_taken;
  wire [31:0] actual_target;
  wire control_flow;
  wire direction_mismatch;
  wire target_mismatch;
  wire target_misaligned;
  wire [31:0] alu_result;
  wire [31:0] csr_src;
  wire [31:0] csr_write_value;
  wire        div_sel;

  rv32_forward_unit u_forward_unit (
    .rs1_i          (rs1_i),
    .rs2_i          (rs2_i),
    .rs1_data_i     (rs1_value_i),
    .rs2_data_i     (rs2_value_i),
    .exmem_write_i  (exmem_write_i),
    .exmem_rd_i     (exmem_rd_i),
    .exmem_data_i   (exmem_forward_data_i),
    .memwb_write_i  (memwb_write_i),
    .memwb_rd_i     (memwb_rd_i),
    .memwb_data_i   (memwb_forward_data_i),
    .rs1_forward_o  (forwarded_rs1),
    .rs2_forward_o  (forwarded_rs2)
  );

  assign operand_a = op_a_zero_i ? 32'b0 :
                     op_a_pc_i ? pc_i : forwarded_rs1;
  assign operand_b = op_b_imm_i ? imm_i : forwarded_rs2;

  // 除法指令的 op_a_zero/op_a_pc/op_b_imm 都是 0，所以这两个就是前递后的 rs1/rs2。
  // 导出给核里的 rv32_div_unit 在 start 那拍锁存。
  assign div_a_o = operand_a;
  assign div_b_o = operand_b;

  // 阵列的标量操作数（VUPD 的 g = mu*e）也走同一个前递后的 operand_a —— 这样它在
  // start 那拍锁存的就是前递后的值，理由和除法器一模一样（见 rv32_div_unit.v 头部）。
  assign vec_scalar_o = operand_a;
  assign acou_scalar_o = operand_a;   // PUSH 的数据也取前递后的 rs1
  assign fft_scalar_o  = operand_a;   // 同上：PUSH 输入帧也走前递后的 rs1

  rv32_alu u_alu (
    .operand_a_i (operand_a),
    .operand_b_i (operand_b),
    .alu_op_i    (alu_op_i),
    .result_o    (alu_result)
  );

  rv32_branch_unit u_branch_unit (
    .pc_i        (pc_i),
    .rs1_i       (forwarded_rs1),
    .rs2_i       (forwarded_rs2),
    .imm_i       (imm_i),
    .branch_op_i (branch_op_i),
    .branch_i    (branch_i),
    .jal_i       (jal_i),
    .jalr_i      (jalr_i),
    .taken_o     (actual_taken),
    .target_o    (actual_target)
  );

  assign control_flow      = branch_i | jal_i | jalr_i;
  assign direction_mismatch = pred_taken_i ^ actual_taken;
  assign target_mismatch    = actual_taken & (pred_target_i != actual_target);

  // 跳转目标非 4 字节对齐时本指令自己不重定向，改由 MEM 级的陷入送到 mtvec。
  assign target_misaligned  = actual_taken & (actual_target[1:0] != 2'b00);

  assign redirect_o         = valid_i & ~target_misaligned & control_flow &
                              (direction_mismatch | target_mismatch);
  assign redirect_pc_o      = actual_taken ? actual_target : pc_i + 32'd4;

  // 除法结果由 rv32_div_unit 多拍产出，只有 done 那拍有效；其余拍 alu_result 里是中间值，
  // 但 stall 期间 EX/MEM 不收（见 rv32_core 的 valid_i 门控），所以不会被提交。
  assign div_sel            = div_done_i &
                              ((alu_op_i == `ALU_DIV) | (alu_op_i == `ALU_DIVU) |
                               (alu_op_i == `ALU_REM) | (alu_op_i == `ALU_REMU));

  // 向量阵列的结果走**独立的 2:1**，摆在下面那条 4 路优先级 mux 的**前面**，不塞进去。
  // 理由是可测的：40 MHz 那条 WNS 最差路径是
  //   EX/MEM → dmem_mmio0 → mmio_read → dmem_rdata → selected_half → mem_forward_data
  //          → 乘法器 → 回到 EX/MEM
  // 一整条**环**，而 MMIO 读 mux 就在环里（音频前端加进去时已经吃掉了 1.06 ns，
  // 余量从 +1.749 掉到 +0.689）。往那条路上再加一级 LUT 就是负 slack。
  // vec_result_i 是阵列的寄存器输出，所以这里新增的路径只是「寄存器 → 1 个 LUT →
  // EX/MEM」，约 0.5 ns，而且不改动 div_sel / csr_valid_i 各自那条网。
  // **vec_sel 必须与 vec_done_i 相与**（照 div_sel 的写法）：不等 done 的话，
  // 多趟归约的中间趟会漏进 EX/MEM，而部分和是个完全合理的数字 —— 静默错。
  assign vec_sel            = vec_done_i &
                              ((alu_op_i == `ALU_VVRED) | (alu_op_i == `ALU_VVMUL));

  // 声学扩展的结果同样走独立的 2:1，串在 vec_sel **前面**（理由同上：那条 40 MHz
  // 的关键路径是一整条环，不能再往里塞 LUT）。
  // **必须与 acou_done_i 相与**：不等 done 的话，多拍运算的中间结果会漏进 EX/MEM，
  // 而"算了一半的数"是个完全合理的数字 —— 静默错。
  // 只有 VRED2 与 POP 会写 rd（见 rv32_decoder.v 的 acou_writes_rd），
  // 其余几条这里选不中也没关系：它们 reg_write=0，结果不会落到寄存器堆。
  assign acou_sel           = acou_done_i &
                              ((alu_op_i == `ALU_VRED2) | (alu_op_i == `ALU_VSUB) |
                               (alu_op_i == `ALU_VCMUL) | (alu_op_i == `ALU_VPHAT));

  // VFFT 的结果同样串在最前面。**必须与 fft_done_i 相与** —— 不等 done 的话
  // 多拍运算的中间结果会漏进 EX/MEM，而"算了一半的数"看着完全合理。
  assign fft_sel            = fft_done_i & (alu_op_i == `ALU_VFFT);

  // ⚠ 必须显式声明位宽。Verilog 对 assign 里没声明的标识符会**隐式建一条 1 位线**，
  // 而 iverilog 既不报错也不告警 —— 结果就是每条非向量指令的 alu_result_o 高 31 位
  // 被截成 0，整个核全乱（实测：冒烟测试从 771 拍变成 1501 拍超时，PS/流水灯/音频
  // 回环一起红）。这条踩过一次，别再删。
  wire acou_sel;
  wire fft_sel;
  wire [31:0] alu_result_pre;

  assign alu_result_pre     = div_sel ? div_result_i :
                              target_misaligned ? actual_target :
                              csr_valid_i ? csr_rdata_i : alu_result;

  // CSR 指令的 rd 取旧值，直接借用 alu_result 这条通路送到 WB 与前递。
  // 目标非对齐时同理借用它把故障地址带到 MEM 级做 mtval。
  assign alu_result_o       = fft_sel  ? fft_result_i  :
                              acou_sel ? acou_result_i :
                              vec_sel  ? vec_result_i : alu_result_pre;

  assign csr_src         = csr_imm_i ? {27'b0, rs1_i} : forwarded_rs1;
  assign csr_write_value = (csr_op_i == `CSR_RS) ? (csr_rdata_i | csr_src) :
                           (csr_op_i == `CSR_RC) ? (csr_rdata_i & ~csr_src) :
                                                   csr_src;

  assign csr_addr_o      = csr_addr_i;
  assign csr_we_o        = valid_i & csr_valid_i & csr_write_i &
                           (fault_i == `FAULT_NONE);
  assign csr_wdata_o     = csr_write_value;

  assign store_data_o    = forwarded_rs2;
  assign pc_plus4_o       = pc_i + 32'd4;
  assign rd_o             = rd_i;
  assign wb_sel_o         = wb_sel_i;
  assign mem_size_o       = mem_size_i;
  assign reg_write_o      = reg_write_i;
  assign mem_read_o       = mem_read_i;
  assign mem_write_o      = mem_write_i;
  assign load_unsigned_o  = load_unsigned_i;
  assign fault_o          = target_misaligned ? `FAULT_INSTR_ALIGN : fault_i;

  assign bp_update_valid_o          = valid_i & ~target_misaligned & control_flow;
  assign bp_update_pc_o             = pc_i;
  assign bp_update_target_o         = actual_target;
  assign bp_update_pht_index_o      = pht_index_i;
  assign bp_update_taken_o          = actual_taken;
  assign bp_update_branch_o         = branch_i;
  assign bp_update_call_o           = is_call_i;
  assign bp_update_return_o         = is_return_i;
  assign bp_update_return_address_o = pc_i + 32'd4;

endmodule
