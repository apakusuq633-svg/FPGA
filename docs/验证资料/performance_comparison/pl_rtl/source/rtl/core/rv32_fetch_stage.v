module rv32_fetch_stage #(
  parameter RESET_PC = 32'h0000_0000
) (
  input         clk_i,
  input         rst_n_i,
  input         test_en_i,
  input         stall_i,
  input         redirect_i,
  input  [31:0] redirect_pc_i,
  output        imem_req_o,
  output [31:0] imem_addr_o,
  input         imem_ready_i,
  input  [31:0] imem_rdata_i,
  output        fetch_pending_o,
  output        fetch_valid_o,
  output [31:0] fetch_pc_o,
  output [31:0] fetch_instr_o,
  output        fetch_pred_taken_o,
  output [31:0] fetch_pred_target_o,
  output [5:0]  fetch_pht_index_o,
  input         bp_update_valid_i,
  input  [31:0] bp_update_pc_i,
  input  [31:0] bp_update_target_i,
  input  [5:0]  bp_update_pht_index_i,
  input         bp_update_taken_i,
  input         bp_update_branch_i,
  input         bp_update_call_i,
  input         bp_update_return_i,
  input  [31:0] bp_update_return_address_i
);

  wire [31:0] pc_q;
  wire [31:0] pc_d;
  wire pc_enable;
  wire [31:0] fetch_imm;
  wire fetch_branch;
  wire fetch_jal;
  wire fetch_jalr;
  wire fetch_return;
  wire predicted_taken;
  wire [31:0] predicted_target;

  // Keep synchronous ITCM warm; stall still forbids PC advance and consumption.
  assign imem_req_o   = 1'b1;
  assign fetch_valid_o = imem_ready_i & ~stall_i;
  assign fetch_pc_o    = pc_q;
  assign fetch_instr_o = imem_rdata_i;
  assign pc_enable     = redirect_i | fetch_valid_o;
  assign pc_d          = redirect_i ? redirect_pc_i :
                         predicted_taken ? predicted_target : pc_q + 32'd4;

  // 指令存储器（ITCM/BRAM）在本拍采样地址、下一拍才给出数据，
  // 所以这里送出的必须是"下一拍的 PC"：PC 要更新就送 pc_d，PC 保持就送 pc_q。
  // 存储器里打的那一拍正好和 PC 寄存器同步，回来的数据与 pc_q 天然对齐。
  // （若直接送 pc_q，PC 与 rdata 会错开一拍：pc_q 已跳到 A+4，数据还是 mem[A]。）
  assign imem_addr_o   = pc_enable ? pc_d : pc_q;

  // 请求已发出但数据还没回来：本拍前端产不出新指令，IF/ID 必须冻结，
  // 否则 IF/ID 会被写成 valid=0，把上一拍已经取到、还等着进 ID 的指令挤掉。
  assign fetch_pending_o = ~stall_i & ~imem_ready_i;

  rv_dffr #(
    .WIDTH       (32),
    .RESET_VALUE (RESET_PC)
  ) u_pc_dff (
    .clk_i   (clk_i),
    .rst_n_i (rst_n_i),
    .en_i    (pc_enable),
    .d_i     (pc_d),
    .q_o     (pc_q)
  );

  // Reuse the complete decoder for fetch-time control-flow predecode.
  rv32_decoder u_fetch_decoder (
    .instr_i          (imem_rdata_i),
    .rs1_o            (),
    .rs2_o            (),
    .rd_o             (),
    .imm_o            (fetch_imm),
    .alu_op_o         (),
    .branch_op_o      (),
    .wb_sel_o         (),
    .mem_size_o       (),
    .op_a_pc_o        (),
    .op_a_zero_o      (),
    .op_b_imm_o       (),
    .uses_rs1_o       (),
    .uses_rs2_o       (),
    .reg_write_o      (),
    .mem_read_o       (),
    .mem_write_o      (),
    .load_unsigned_o  (),
    .branch_o         (fetch_branch),
    .jal_o            (fetch_jal),
    .jalr_o           (fetch_jalr),
    .is_call_o        (),
    .is_return_o      (fetch_return),
    .illegal_o        ()
  );

  rv32_branch_predictor u_branch_predictor (
    .clk_i                   (clk_i),
    .rst_n_i                 (rst_n_i),
    .test_en_i               (test_en_i),
    .fetch_pc_i              (pc_q),
    .fetch_imm_i             (fetch_imm),
    .fetch_branch_i          (fetch_branch),
    .fetch_jal_i             (fetch_jal),
    .fetch_jalr_i            (fetch_jalr),
    .fetch_return_i          (fetch_return),
    .predict_taken_o         (predicted_taken),
    .predict_target_o        (predicted_target),
    .predict_pht_index_o     (fetch_pht_index_o),
    .update_valid_i          (bp_update_valid_i),
    .update_pc_i             (bp_update_pc_i),
    .update_target_i         (bp_update_target_i),
    .update_pht_index_i      (bp_update_pht_index_i),
    .update_taken_i          (bp_update_taken_i),
    .update_branch_i         (bp_update_branch_i),
    .update_call_i           (bp_update_call_i),
    .update_return_i         (bp_update_return_i),
    .update_return_address_i (bp_update_return_address_i)
  );

  assign fetch_pred_taken_o  = predicted_taken;
  assign fetch_pred_target_o = predicted_target;

endmodule
