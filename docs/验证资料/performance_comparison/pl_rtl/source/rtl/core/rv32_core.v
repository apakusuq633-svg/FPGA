`include "rv32_defines.vh"

module rv32_core #(
  parameter RESET_PC = 32'h0000_0000,
  parameter AUDIO_STREAM = 0,
  parameter ACOU_LANES = 8,
  parameter ACOU_CACHE_N = 208,
  parameter ACOU_BAND_HI = 203,
  parameter FFT_SPARSE_LO = 0,
  parameter FFT_SPARSE_COUNT = 513,
  parameter LOCAL_TRANSFER = 0
) (
  input         clk_i,
  input         rst_n_i,
  input         test_en_i,
  input         halt_i,
  output        imem_req_o,
  output [31:0] imem_addr_o,
  input         imem_ready_i,
  input  [31:0] imem_rdata_i,
  output        dmem_req_o,
  output        dmem_write_o,
  output [31:0] dmem_addr_o,
  output [31:0] dmem_wdata_o,
  output [3:0]  dmem_wstrb_o,
  input         dmem_ready_i,
  input  [31:0] dmem_rdata_i,
  output        retire_valid_o,
  output [31:0] retire_pc_o,
  output [31:0] retire_instr_o,
  output [3:0]  retire_fault_o,
  // 阵列系数 bank 的预装口（PS 侧），穿透到 u_vec_unit。按逻辑抽头号寻址、Q15 进出。
  // 写保护由 PS 寄存器堆那层用 halt_q 做，核这边不复核。
  input         coef_we_i,
  input         coef_re_i,
  input         coef_src_i,
  input         coef_ch_i,
  input  [8:0]  coef_idx_i,
  input  [15:0] coef_wdata_i,
  output        simd_active_o,
  output [15:0] coef_rdata_o,
  // 定位/转向加速器的门铃（custom-1，见 rv32_defines.vh 的 ALU_VLOC）。
  // 恰好一拍、不 stall —— 理由见下面给它们赋值那一段。
  // 目标块由 funct3 分：000 = SRP，001 = XSPEC，010 = 波束转向。
  output reg    srp_start_o,
  output reg    xsp_start_o,
  output reg    steer_start_o,
  input audio_valid_i, input [15:0] audio_sample_i,
  output audio_ready_o, output audio_done_o, output [15:0] audio_result_o,
  input transfer_enable_i,input [2:0] transfer_request_i,
  input transfer_fft_start_i,input transfer_fft_inv_i,input transfer_fft_pop_i,
  input transfer_fft_seek_i,input [31:0] transfer_fft_data_i,
  output transfer_fft_ready_o,output transfer_fft_done_o,output [31:0] transfer_fft_result_o,
  input transfer_ac_start_i,input [1:0] transfer_ac_sel_i,input [31:0] transfer_ac_data_i,
  output transfer_ac_ready_o,output transfer_ac_done_o,output [31:0] transfer_ac_result_o
);

  wire fetch_stall;
  wire fetch_pending;
  wire fetch_valid;
  wire [31:0] fetch_pc;
  wire [31:0] fetch_instr;
  wire fetch_pred_taken;
  wire [31:0] fetch_pred_target;
  wire [5:0] fetch_pht_index;

  wire ifid_hold;
  wire ifid_flush;
  wire ifid_valid;
  wire [31:0] ifid_pc;
  wire [31:0] ifid_instr;
  wire ifid_pred_taken;
  wire [31:0] ifid_pred_target;
  wire [5:0] ifid_pht_index;

  wire [31:0] id_rs1_value;
  wire [31:0] id_rs2_value;
  wire [31:0] id_imm;
  wire [4:0] id_rs1;
  wire [4:0] id_rs2;
  wire [4:0] id_rd;
  wire [4:0] id_alu_op;
  wire [2:0] id_branch_op;
  wire [1:0] id_wb_sel;
  wire [1:0] id_mem_size;
  wire id_op_a_pc;
  wire id_op_a_zero;
  wire id_op_b_imm;
  wire id_uses_rs1;
  wire id_uses_rs2;
  wire id_reg_write;
  wire id_mem_read;
  wire id_mem_write;
  wire id_load_unsigned;
  wire id_branch;
  wire id_jal;
  wire id_jalr;
  wire id_is_call;
  wire id_is_return;
  wire id_pred_taken;
  wire [31:0] id_pred_target;
  wire [5:0] id_pht_index;
  wire [3:0] id_fault;
  wire [31:0] id_ra_value;
  wire id_mret;
  wire id_csr_valid;
  wire [11:0] id_csr_addr;
  wire [1:0] id_csr_op;
  wire id_csr_imm;
  wire id_csr_write;

  wire idex_hold;
  wire idex_flush;
  wire idex_valid;
  wire [31:0] idex_pc;
  wire [31:0] idex_instr;
  wire [31:0] idex_rs1_value;
  wire [31:0] idex_rs2_value;
  wire [31:0] idex_imm;
  wire [4:0] idex_rs1;
  wire [4:0] idex_rs2;
  wire [4:0] idex_rd;
  wire [4:0] idex_alu_op;
  wire [2:0] idex_branch_op;
  wire [1:0] idex_wb_sel;
  wire [1:0] idex_mem_size;
  wire idex_op_a_pc;
  wire idex_op_a_zero;
  wire idex_op_b_imm;
  wire idex_reg_write;
  wire idex_mem_read;
  wire idex_mem_write;
  wire idex_load_unsigned;
  wire idex_branch;
  wire idex_jal;
  wire idex_jalr;
  wire idex_is_call;
  wire idex_is_return;
  wire idex_pred_taken;
  wire [31:0] idex_pred_target;
  wire [5:0] idex_pht_index;
  wire [3:0] idex_fault;
  wire idex_mret;
  wire idex_csr_valid;
  wire [11:0] idex_csr_addr;
  wire [1:0] idex_csr_op;
  wire idex_csr_imm;
  wire idex_csr_write;

  wire load_use_stall;
  wire ex_stage_valid;
  wire [31:0] ex_alu_result;
  wire [31:0] ex_store_data;
  wire [31:0] ex_pc_plus4;
  wire [4:0] ex_rd;
  wire [1:0] ex_wb_sel;
  wire [1:0] ex_mem_size;
  wire ex_reg_write;
  wire ex_mem_read;
  wire ex_mem_write;
  wire ex_load_unsigned;
  wire [3:0] ex_fault;
  wire [11:0] ex_csr_addr;
  wire ex_csr_we;
  wire [31:0] ex_csr_wdata;
  wire [31:0] csr_rdata;
  wire [31:0] csr_mtvec;
  wire [31:0] csr_mepc;
  wire ex_redirect_raw;
  wire ex_redirect;
  wire [31:0] ex_redirect_pc;
  wire mem_dmem_req;
  wire mem_dmem_write;
  wire ex_mret;
  wire trap_taken;
  wire [3:0] trap_cause;
  wire [31:0] trap_value;
  wire redirect;
  wire [31:0] redirect_pc;
  wire ex_bp_update_valid;
  wire bp_update_valid;
  wire [31:0] bp_update_pc;
  wire [31:0] bp_update_target;
  wire [5:0] bp_update_pht_index;
  wire bp_update_taken;
  wire bp_update_branch;
  wire bp_update_call;
  wire bp_update_return;
  wire [31:0] bp_update_return_address;

  wire exmem_hold;
  wire exmem_valid;
  wire [31:0] exmem_pc;
  wire [31:0] exmem_instr;
  wire [31:0] exmem_alu_result;
  wire [31:0] exmem_store_data;
  wire [31:0] exmem_pc_plus4;
  wire [4:0] exmem_rd;
  wire [1:0] exmem_wb_sel;
  wire [1:0] exmem_mem_size;
  wire exmem_reg_write;
  wire exmem_mem_read;
  wire exmem_mem_write;
  wire exmem_load_unsigned;
  wire [3:0] exmem_fault;

  wire [31:0] ex_div_a;
  wire [31:0] ex_div_b;
  wire [31:0] div_result;
  wire        div_done;
  wire        div_stall;
  wire        div_start;
  wire        div_commit;
  wire        idex_div_op;
  wire        idex_div_signed;
  wire        idex_div_rem;

  // 向量阵列（OP-V）。和除法同一套形状：状态机在核里，EX 保持纯组合。
  wire [31:0] ex_vec_scalar;
  wire [31:0] vec_result;
  wire        vec_done;
  wire        vec_stall;
  wire        vec_start;
  wire        vec_commit;
  wire        idex_vec_op;
  wire        idex_vec_push;
  wire [5:0]  idex_vec_len;
  wire        idex_vec_acc, idex_vec_coef, idex_vec_data;
  wire [1:0]  idex_vec_ch;      // 2 位：x′ 延迟线有 4 条（2×2 MIMO 的 filtered-x）

  // 声学扩展单元（OP-V 的 funct3[2]=1 那半边）。与阵列并存、各用各的存储 ——
  // 见 rtl/acoustic/rv32_acoustic_ext.v 头部的分工说明。
  wire [31:0] acou_result;
  wire [31:0] ex_acou_scalar;
  wire        acou_done;
  wire        acou_stall;
  wire        acou_start;
  wire        acou_commit;
  wire        idex_acou_op;
  wire [1:0]  idex_acou_io_sel;

  // VFFT：核内的 512 点复数 FFT（rtl/acoustic/rv32_fft_bfly.v）。
  // 与声学扩展同一套握手，只是运算在另一个单元里 —— 数据布局完全不同
  // （512 条复数 × 8 bank 2R2W vs 208 条 Ï复数 × 顺序），所以并存不合并。
  wire [31:0] fft_result;
  wire [31:0] ex_fft_scalar;
  wire        fft_done;
  wire        fft_stall;
  wire        fft_start;
  wire        fft_commit;
  wire        idex_fft_op;
  wire        idex_fft_pop;
  wire        idex_fft_io;
  wire        idex_fft_inv;
  wire        idex_acou_is_io;

  wire memory_stall;
  wire [31:0] mem_forward_data;
  wire [31:0] mem_load_data;
  wire [4:0] mem_rd;
  wire [1:0] mem_wb_sel;
  wire mem_reg_write;
  wire [3:0] mem_fault;

  wire memwb_valid;
  wire [31:0] memwb_pc;
  wire [31:0] memwb_instr;
  wire [31:0] memwb_alu_result;
  wire [31:0] memwb_load_data;
  wire [31:0] memwb_pc_plus4;
  wire [4:0] memwb_rd;
  wire [1:0] memwb_wb_sel;
  wire memwb_reg_write;
  wire [3:0] memwb_fault;
  wire wb_write_en;
  wire [4:0] wb_write_addr;
  wire [31:0] wb_write_data;

  assign ex_stage_valid = idex_valid & ~memory_stall;

  // ── 异常入口 ──────────────────────────────────────────────────────────────
  // 陷入在 MEM 级成立：更老的指令当拍正从 WB 提交，更年轻的还停在 EX/ID/IF，
  // 只需冲刷 ID/EX 与 IF/ID，陷入指令自己继续走下去（带故障码退休，不写寄存器）。
  // 反压期间 memory_stall 拉高，EX/MEM 冻结，陷入要等到应答拍才成立。
  // 故障码要取 MEM 级的 mem_fault 而不是 EX/MEM 里的 exmem_fault：非对齐故障是
  // LSU 在 MEM 级组合判出来的，exmem_fault 那时还是 NONE。
  // halt 期间必须压掉 trap：故障指令冻结在 EX/MEM 里，trap_taken 会一直成立，
  // 每拍重新写一次 mepc/mcause。压掉之后故障还在，解除 halt 那拍重新成立一次，语义不变。
  assign trap_taken = exmem_valid & (mem_fault != `FAULT_NONE) & ~memory_stall & ~halt_i;
  assign trap_cause = (mem_fault == `FAULT_ILLEGAL)     ? `MCAUSE_ILLEGAL :
                      (mem_fault == `FAULT_INSTR_ALIGN) ? `MCAUSE_INSTR_ALIGN :
                      (mem_fault == `FAULT_LOAD_ALIGN)  ? `MCAUSE_LOAD_ALIGN :
                      (mem_fault == `FAULT_ST_ALIGN)    ? `MCAUSE_ST_ALIGN :
                      (mem_fault == `FAULT_EBREAK)      ? `MCAUSE_EBREAK :
                      (mem_fault == `FAULT_ECALL)       ? `MCAUSE_ECALL_M :
                                                          `MCAUSE_ILLEGAL;
  // mtval 复用已有流水字段：非法指令取指令码，地址类故障取 alu_result（EX 级已把
  // 非对齐跳转目标塞进这条路），ecall/ebreak 为 0。
  assign trap_value = (mem_fault == `FAULT_ILLEGAL) ? exmem_instr :
                      (mem_fault == `FAULT_ECALL)   ? 32'b0 :
                      (mem_fault == `FAULT_EBREAK)  ? 32'b0 :
                                                      exmem_alu_result;

  // 陷入优先于 EX 级的分支重定向和 mret：EX 里那条更年轻的指令会被 id_ex_flush 冲掉，
  // 它的 CSR 写和 mret 副作用也必须同时压掉。
  // halt 期间 EX 冻结，这三个源持续成立，必须一起压掉 —— 否则 halt 期间还会挪 PC
  // （跟着 redirect 走的 flush 会把冻结中的指令冲掉，解除后凭空少执行一条）。
  // 它们都来自冻结中的 EX/MEM，解除 halt 后重新求值，不会丢。
  assign ex_mret     = ex_stage_valid & idex_mret & ~halt_i;
  assign ex_redirect = ex_redirect_raw & ~halt_i;

  // 陷阱当拍 EX 里那条控制流指令马上就要被 id_ex_flush 冲掉，不许它更新预测器。
  // 漏在这里不会错功能（预测器只是性能提示），但会让错误路径污染 BTB/PHT/RAS。
  // halt 期间同理要压掉：EX 冻结时 update_valid 恒高，而 RAS 是电平触发
  // （if (push_i) stack[sp] <= ...），冻结的 jal 会每拍压一次栈，8 项指针跑飞、
  // 恢复后返回地址全错。这同样是"只掉准确率不算错结果"，但没必要白受这个损失。
  assign bp_update_valid = ex_bp_update_valid & ~trap_taken & ~halt_i;

  assign redirect    = trap_taken | ex_redirect | ex_mret;
  assign redirect_pc = trap_taken ? csr_mtvec :
                       ex_mret    ? csr_mepc   : ex_redirect_pc;

  rv32_csr u_csr (
    .clk_i        (clk_i),
    .rst_n_i      (rst_n_i),
    .addr_i       (ex_csr_addr),
    .rdata_o      (csr_rdata),
    .we_i         (ex_csr_we & ~trap_taken),
    .wdata_i      (ex_csr_wdata),
    .trap_i       (trap_taken),
    .trap_pc_i    (exmem_pc),
    .trap_cause_i (trap_cause),
    .trap_value_i (trap_value),
    .mret_i       (ex_mret & ~trap_taken),
    .retire_i     (memwb_valid & ~memory_stall & ~halt_i),
    .mtvec_o      (csr_mtvec),
    .mepc_o       (csr_mepc)
  );

  rv32_fetch_stage #(.RESET_PC(RESET_PC)) u_fetch_stage (
    .clk_i                      (clk_i),
    .rst_n_i                    (rst_n_i),
    .test_en_i                  (test_en_i),
    .stall_i                    (fetch_stall),
    .redirect_i                 (redirect),
    .redirect_pc_i              (redirect_pc),
    .imem_req_o                 (imem_req_o),
    .imem_addr_o                (imem_addr_o),
    .imem_ready_i               (imem_ready_i),
    .imem_rdata_i               (imem_rdata_i),
    .fetch_pending_o            (fetch_pending),
    .fetch_valid_o              (fetch_valid),
    .fetch_pc_o                 (fetch_pc),
    .fetch_instr_o              (fetch_instr),
    .fetch_pred_taken_o         (fetch_pred_taken),
    .fetch_pred_target_o        (fetch_pred_target),
    .fetch_pht_index_o          (fetch_pht_index),
    .bp_update_valid_i          (bp_update_valid),
    .bp_update_pc_i             (bp_update_pc),
    .bp_update_target_i         (bp_update_target),
    .bp_update_pht_index_i      (bp_update_pht_index),
    .bp_update_taken_i          (bp_update_taken),
    .bp_update_branch_i         (bp_update_branch),
    .bp_update_call_i           (bp_update_call),
    .bp_update_return_i         (bp_update_return),
    .bp_update_return_address_i (bp_update_return_address)
  );

  rv_if_id_reg u_if_id_reg (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    .hold_i        (ifid_hold),
    .flush_i       (ifid_flush),
    .valid_i       (fetch_valid),
    .pc_i          (fetch_pc),
    .instr_i       (fetch_instr),
    .pred_taken_i  (fetch_pred_taken),
    .pred_target_i (fetch_pred_target),
    .pht_index_i   (fetch_pht_index),
    .valid_o       (ifid_valid),
    .pc_o          (ifid_pc),
    .instr_o       (ifid_instr),
    .pred_taken_o  (ifid_pred_taken),
    .pred_target_o (ifid_pred_target),
    .pht_index_o   (ifid_pht_index)
  );

  rv32_decode_stage u_decode_stage (
    .clk_i             (clk_i),
    .instr_i           (ifid_instr),
    .pc_i              (ifid_pc),
    .pred_taken_i      (ifid_pred_taken),
    .pred_target_i     (ifid_pred_target),
    .pht_index_i       (ifid_pht_index),
    .wb_write_en_i     (wb_write_en),
    .wb_write_addr_i   (wb_write_addr),
    .wb_write_data_i   (wb_write_data),
    .rs1_value_o       (id_rs1_value),
    .rs2_value_o       (id_rs2_value),
    .imm_o             (id_imm),
    .rs1_o             (id_rs1),
    .rs2_o             (id_rs2),
    .rd_o              (id_rd),
    .alu_op_o          (id_alu_op),
    .branch_op_o       (id_branch_op),
    .wb_sel_o          (id_wb_sel),
    .mem_size_o        (id_mem_size),
    .op_a_pc_o         (id_op_a_pc),
    .op_a_zero_o       (id_op_a_zero),
    .op_b_imm_o        (id_op_b_imm),
    .uses_rs1_o        (id_uses_rs1),
    .uses_rs2_o        (id_uses_rs2),
    .reg_write_o       (id_reg_write),
    .mem_read_o        (id_mem_read),
    .mem_write_o       (id_mem_write),
    .load_unsigned_o   (id_load_unsigned),
    .branch_o          (id_branch),
    .jal_o             (id_jal),
    .jalr_o            (id_jalr),
    .is_call_o         (id_is_call),
    .is_return_o       (id_is_return),
    .mret_o            (id_mret),
    .csr_valid_o       (id_csr_valid),
    .csr_addr_o        (id_csr_addr),
    .csr_op_o          (id_csr_op),
    .csr_imm_o         (id_csr_imm),
    .csr_write_o       (id_csr_write),
    .pred_taken_o      (id_pred_taken),
    .pred_target_o     (id_pred_target),
    .pht_index_o       (id_pht_index),
    .fault_o           (id_fault),
    .ra_value_o        (id_ra_value)
  );

  rv32_hazard_unit u_hazard_unit (
    .id_valid_i       (ifid_valid),
    .id_uses_rs1_i    (id_uses_rs1),
    .id_uses_rs2_i    (id_uses_rs2),
    .id_rs1_i         (id_rs1),
    .id_rs2_i         (id_rs2),
    .ex_valid_i       (idex_valid),
    .ex_mem_read_i    (idex_mem_read),
    .ex_rd_i          (idex_rd),
    .load_use_stall_o (load_use_stall)
  );

  rv32_pipeline_control u_pipeline_control (
    .memory_stall_i   (memory_stall),
    .load_use_stall_i (load_use_stall),
    .fetch_pending_i  (fetch_pending),
    .redirect_i       (redirect),
    .trap_i           (trap_taken),
    .halt_i           (halt_i),
    .div_stall_i      (div_stall),
    .vec_stall_i      (vec_stall),
    .acou_stall_i     (acou_stall),
    .fft_stall_i      (fft_stall),
    .fetch_stall_o    (fetch_stall),
    .if_id_hold_o     (ifid_hold),
    .if_id_flush_o    (ifid_flush),
    .id_ex_hold_o     (idex_hold),
    .id_ex_flush_o    (idex_flush),
    .ex_mem_hold_o    (exmem_hold)
  );

  rv_id_ex_reg u_id_ex_reg (
    .clk_i            (clk_i),
    .rst_n_i          (rst_n_i),
    .hold_i           (idex_hold),
    .flush_i          (idex_flush),
    .valid_i          (ifid_valid),
    .pc_i             (ifid_pc),
    .instr_i          (ifid_instr),
    .rs1_value_i      (id_rs1_value),
    .rs2_value_i      (id_rs2_value),
    .imm_i            (id_imm),
    .rs1_i            (id_rs1),
    .rs2_i            (id_rs2),
    .rd_i             (id_rd),
    .alu_op_i         (id_alu_op),
    .branch_op_i      (id_branch_op),
    .wb_sel_i         (id_wb_sel),
    .mem_size_i       (id_mem_size),
    .op_a_pc_i        (id_op_a_pc),
    .op_a_zero_i      (id_op_a_zero),
    .op_b_imm_i       (id_op_b_imm),
    .reg_write_i      (id_reg_write),
    .mem_read_i       (id_mem_read),
    .mem_write_i      (id_mem_write),
    .load_unsigned_i  (id_load_unsigned),
    .branch_i         (id_branch),
    .jal_i            (id_jal),
    .jalr_i           (id_jalr),
    .is_call_i        (id_is_call),
    .is_return_i      (id_is_return),
    .mret_i           (id_mret),
    .csr_valid_i      (id_csr_valid),
    .csr_addr_i       (id_csr_addr),
    .csr_op_i         (id_csr_op),
    .csr_imm_i        (id_csr_imm),
    .csr_write_i      (id_csr_write),
    .pred_taken_i     (id_pred_taken),
    .pred_target_i    (id_pred_target),
    .pht_index_i      (id_pht_index),
    .fault_i          (id_fault),
    .valid_o          (idex_valid),
    .pc_o             (idex_pc),
    .instr_o          (idex_instr),
    .rs1_value_o      (idex_rs1_value),
    .rs2_value_o      (idex_rs2_value),
    .imm_o            (idex_imm),
    .rs1_o            (idex_rs1),
    .rs2_o            (idex_rs2),
    .rd_o             (idex_rd),
    .alu_op_o         (idex_alu_op),
    .branch_op_o      (idex_branch_op),
    .wb_sel_o         (idex_wb_sel),
    .mem_size_o       (idex_mem_size),
    .op_a_pc_o        (idex_op_a_pc),
    .op_a_zero_o      (idex_op_a_zero),
    .op_b_imm_o       (idex_op_b_imm),
    .reg_write_o      (idex_reg_write),
    .mem_read_o       (idex_mem_read),
    .mem_write_o      (idex_mem_write),
    .load_unsigned_o  (idex_load_unsigned),
    .branch_o         (idex_branch),
    .jal_o            (idex_jal),
    .jalr_o           (idex_jalr),
    .is_call_o        (idex_is_call),
    .is_return_o      (idex_is_return),
    .mret_o           (idex_mret),
    .csr_valid_o      (idex_csr_valid),
    .csr_addr_o       (idex_csr_addr),
    .csr_op_o         (idex_csr_op),
    .csr_imm_o        (idex_csr_imm),
    .csr_write_o      (idex_csr_write),
    .pred_taken_o     (idex_pred_taken),
    .pred_target_o    (idex_pred_target),
    .pht_index_o      (idex_pht_index),
    .fault_o          (idex_fault)
  );

  rv32_execute_stage u_execute_stage (
    .valid_i                    (ex_stage_valid),
    .pc_i                       (idex_pc),
    .instr_i                    (idex_instr),
    .rs1_value_i                (idex_rs1_value),
    .rs2_value_i                (idex_rs2_value),
    .imm_i                      (idex_imm),
    .rs1_i                      (idex_rs1),
    .rs2_i                      (idex_rs2),
    .rd_i                       (idex_rd),
    .alu_op_i                   (idex_alu_op),
    .branch_op_i                (idex_branch_op),
    .wb_sel_i                   (idex_wb_sel),
    .mem_size_i                 (idex_mem_size),
    .op_a_pc_i                  (idex_op_a_pc),
    .op_a_zero_i                (idex_op_a_zero),
    .op_b_imm_i                 (idex_op_b_imm),
    .reg_write_i                (idex_reg_write),
    .mem_read_i                 (idex_mem_read),
    .mem_write_i                (idex_mem_write),
    .load_unsigned_i            (idex_load_unsigned),
    .branch_i                   (idex_branch),
    .jal_i                      (idex_jal),
    .jalr_i                     (idex_jalr),
    .is_call_i                  (idex_is_call),
    .is_return_i                (idex_is_return),
    .pred_taken_i               (idex_pred_taken),
    .pred_target_i              (idex_pred_target),
    .pht_index_i                (idex_pht_index),
    .fault_i                    (idex_fault),
    .csr_valid_i                (idex_csr_valid),
    .csr_addr_i                 (idex_csr_addr),
    .csr_op_i                   (idex_csr_op),
    .csr_imm_i                  (idex_csr_imm),
    .csr_write_i                (idex_csr_write),
    .csr_rdata_i                (csr_rdata),
    .exmem_write_i              (exmem_valid & mem_reg_write),
    .exmem_rd_i                 (exmem_rd),
    .exmem_forward_data_i       (mem_forward_data),
    .memwb_write_i              (memwb_valid & memwb_reg_write &
                                  (memwb_fault == `FAULT_NONE)),
    .memwb_rd_i                 (memwb_rd),
    .memwb_forward_data_i       (wb_write_data),
    .div_result_i               (div_result),
    .div_done_i                 (div_done),
    .div_a_o                    (ex_div_a),
    .vec_result_i               (vec_result),
    .vec_done_i                 (vec_done),
    .vec_scalar_o               (ex_vec_scalar),
    .acou_result_i              (acou_result),
    .acou_done_i                (acou_done),
    .acou_scalar_o              (ex_acou_scalar),
    .fft_result_i               (fft_result),
    .fft_done_i                 (fft_done),
    .fft_scalar_o               (ex_fft_scalar),
    .div_b_o                    (ex_div_b),
    .alu_result_o               (ex_alu_result),
    .store_data_o               (ex_store_data),
    .pc_plus4_o                 (ex_pc_plus4),
    .rd_o                       (ex_rd),
    .wb_sel_o                   (ex_wb_sel),
    .mem_size_o                 (ex_mem_size),
    .reg_write_o                (ex_reg_write),
    .mem_read_o                 (ex_mem_read),
    .mem_write_o                (ex_mem_write),
    .load_unsigned_o            (ex_load_unsigned),
    .fault_o                    (ex_fault),
    .csr_addr_o                 (ex_csr_addr),
    .csr_we_o                   (ex_csr_we),
    .csr_wdata_o                (ex_csr_wdata),
    .redirect_o                 (ex_redirect_raw),
    .redirect_pc_o              (ex_redirect_pc),
    .bp_update_valid_o          (ex_bp_update_valid),
    .bp_update_pc_o             (bp_update_pc),
    .bp_update_target_o         (bp_update_target),
    .bp_update_pht_index_o      (bp_update_pht_index),
    .bp_update_taken_o          (bp_update_taken),
    .bp_update_branch_o         (bp_update_branch),
    .bp_update_call_o           (bp_update_call),
    .bp_update_return_o         (bp_update_return),
    .bp_update_return_address_o (bp_update_return_address)
  );

  // ── M 扩展的除法器 ────────────────────────────────────────────────────────
  // 状态机住在核里而不是 EX 级里，沿用 rv32_csr 的先例：EX 保持纯组合、无时钟端口。
  assign idex_div_op     = (idex_alu_op == `ALU_DIV) | (idex_alu_op == `ALU_DIVU) |
                           (idex_alu_op == `ALU_REM) | (idex_alu_op == `ALU_REMU);
  assign idex_div_signed = (idex_alu_op == `ALU_DIV) | (idex_alu_op == `ALU_REM);
  assign idex_div_rem    = (idex_alu_op == `ALU_REM) | (idex_alu_op == `ALU_REMU);

  // start 只看 ID/EX 里是不是除法指令，不能带 ~memory_stall：除法启动那拍 MEM 里可能
  // 正有一笔 load 在排空，带上就会把 start 推后一拍，而那时唯一能给出正确 rs1 的
  // MEM/WB 前递源已经消失 —— 锁进来的是陈旧值，且会真的提交。
  // 指令在 ID/EX 里待多久，start 就拉多久；什么时候真正开始由 div_unit 的状态决定。
  assign div_start  = idex_valid & idex_div_op;
  // 与 EX/MEM 的捕获条件保持一致：EX/MEM 真把结果收下才算完成，DONE 才能回 IDLE。
  assign div_commit = ex_stage_valid & ~halt_i;

  rv32_div_unit u_div_unit (
    .clk_i      (clk_i),
    .rst_n_i    (rst_n_i),
    .start_i    (div_start),
    .keep_i     (idex_valid),
    .commit_i   (div_commit),
    .signed_i   (idex_div_signed),
    .is_rem_i   (idex_div_rem),
    .dividend_i (ex_div_a),
    .divisor_i  (ex_div_b),
    .stall_o    (div_stall),
    .done_o     (div_done),
    .result_o   (div_result)
  );

  // ── OP-V：SIMD-MAC 阵列 ───────────────────────────────────────────────────
  // 与除法器同构：start 只看 ID/EX 里是不是 OP-V（不带 ~memory_stall，理由同除法器
  // 那一段 —— 带了会把 start 推后一拍，锁进已经蒸发的前递源）；commit 与 EX/MEM 的
  // 捕获条件一致，这样 DONE 只在结果真被收下之后才回 IDLE。
  // 模式字和 LEN 是译码器打包进 imm_o 的，布局是 **LEN 占 6 位**（imm[5:0] =
  // {instr[25], instr[24:20]}），模式字只剩 4 位：acc/coef/data/ch 落在 imm[6..9]。
  // 别按"模式字 5 位"去读 imm[10] —— imm_o 那个拼接只有 31 位，imm[10] 恒 0，
  // 写进去的通道号会静默丢掉，x'[ch1] 那条延迟线永远选不中。
  // （曾经还有个 line 位，阵列根本没有这个端口，已删。）
  assign idex_vec_op   = (idex_alu_op == `ALU_VPUSH) | (idex_alu_op == `ALU_VVRED) |
                         (idex_alu_op == `ALU_VVUPD) | (idex_alu_op == `ALU_VVMUL);
  assign idex_vec_push = (idex_alu_op == `ALU_VPUSH);
  assign idex_vec_len  = idex_imm[5:0];
  assign idex_vec_acc  = idex_imm[6];
  assign idex_vec_coef = idex_imm[7];
  assign idex_vec_data = idex_imm[8];
  assign idex_vec_ch   = idex_imm[10:9];

  // trap 那拍 ID/EX 这条 OP-V 下一拍就被冲掉。start 必须一起压住：PUSH 的写和
  // 指针自增是在 start 当拍就生效的，冲掉之后没人来撤 —— 延迟线里会多出一个
  // 幽灵样本，而滤波器照样"收敛"，只是收敛到错的序列上。RUN 那三条靠 keep_i
  // 下一拍中止，PUSH 没有这个后悔药。（trap_taken 自带 ~halt_i。）
  // ── 声学扩展：唯一的模式位是 instr[31]（编码已经用满，见 defines 的位域表）
  //   instr[31]=0 → 计算类（VCMUL/VPHAT/VSUB/VRED2）
  //   instr[31]=1 -> PUSHA/PUSHB/POP, selected by funct3 low bits 00/01/10.
  // VPHAT 的限带上下界**不在编码里**：它由 fs 和 N 定死（200 Hz..8000 Hz
  // → bin 6..209），写死在 rv32_acoustic_ext 的参数里，改采样率要一起改
  // —— 与 scripts/golden/fw_gcc_model.py 的 BAND_LO_BIN/BAND_HI_BIN 必须一致。
  assign idex_acou_op     = (idex_alu_op == `ALU_VCMUL) | (idex_alu_op == `ALU_VPHAT) |
                            (idex_alu_op == `ALU_VSUB)  | (idex_alu_op == `ALU_VRED2);
  assign idex_acou_is_io  = idex_instr[31];
  assign idex_acou_io_sel = idex_instr[13:12];

  // ── VFFT：instr[28] 选 PUSH(0)/POP(1)，与声学单元的 io_sel 同一形状 ──
  assign idex_fft_op  = (idex_alu_op == `ALU_VFFT);
  // ⚠ VFFT 需要**三种**动作（灌/算/读），一位选不过来：
  //     instr[29]=1        → 运算（跑完整台 FFT）
  //     instr[29]=0, [28]=0 → PUSH 输入帧
  //     instr[29]=0, [28]=1 → POP 取 bin
  //   写成"是 VFFT 就当 io"的话，运算那一档永远不会被执行 ——
  //   固件发一条"跑 FFT"，单元却当 PUSH 处理，结果是一路安静地什么都不算。
  assign idex_fft_io  = ~idex_instr[29];
  assign idex_fft_pop = idex_instr[28];
  // instr[30] 选正/逆变换（正变换的编码不用它，一直是 0）。它是 VFFT 编码里
  // 唯一还空着的那一位 —— 见 rtl/rv32_defines.vh 的 funct7 表。
  assign idex_fft_inv = idex_instr[30];
  assign fft_start  = idex_valid & idex_fft_op & ~trap_taken;
  assign fft_commit = ex_stage_valid & ~halt_i;

  assign simd_active_o  = audio_own | vec_hw_stall | vec_hw_done | acou_stall | acou_done |
                          fft_stall | fft_done;
  assign vec_start  = idex_valid & idex_vec_op & ~trap_taken;
  assign vec_commit = ex_stage_valid & ~halt_i;
  assign acou_start  = idex_valid & idex_acou_op & ~trap_taken;
  assign acou_commit = ex_stage_valid & ~halt_i;

  // ── 定位加速器的门铃（custom-1，opcode 0x2B）───────────────────────────────
  // **不 stall**：它不写 rd、不产生结果，没有任何东西需要等它。若让它 stall 到
  // 加速器做完，rv32_pipeline_control 会把 fetch/IF-ID/ID-EX 一起冻住 ——
  // 全尺寸 SRP 一趟要 143,360 拍，等于把"把活搬出核"的收益原样还回去。
  // 等待由固件轮询各块的 STATUS.BUSY 表达。
  //
  // **恰好一拍**：idex_valid 是电平，指令在 ID/EX 停多久它就拉多久 —— 直接拿它
  // 当 start 会每拍重复触发一次；被 trap 冲掉的那拍也会触发，而门铃在加速器里
  // 已经生效、没人来撤（同 PUSH 那个坑，见上面 :652-655）。所以照 div/vec 的
  // commit 写法门控，三种停顿各自都不触发：
  //   memory_stall ⇒ ex_stage_valid=0 ⇒ 不触发，解冻那拍触发一次
  //   halt         ⇒ ~halt_i 压掉
  //   load_use     ⇒ id_ex_flush 清掉 ID/EX ⇒ 下一拍 idex_valid=0
  wire idex_loc_op, loc_commit, loc_fire;
  assign idex_loc_op = (idex_alu_op == `ALU_VLOC);
  assign loc_commit  = ex_stage_valid & ~halt_i;
  assign loc_fire    = idex_valid & idex_loc_op & ~trap_taken & loc_commit;

  // 打一拍再送出去：一是把它变成干净的单拍脉冲，二是别让组合路径从 ID/EX 的
  // 触发器一路穿到加速器状态机 —— 本设计 WNS 只剩 +0.461 ns（25 ns 周期的
  // 1.8%），任何长组合穿线都要先付时序的账。
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      srp_start_o   <= 1'b0;
      xsp_start_o   <= 1'b0;
      steer_start_o <= 1'b0;
    end else begin
      srp_start_o   <= loc_fire & (idex_instr[14:12] == 3'b000);
      xsp_start_o   <= loc_fire & (idex_instr[14:12] == 3'b001);
      steer_start_o <= loc_fire & (idex_instr[14:12] == 3'b010);
    end
  end

  wire vec_hw_stall, vec_hw_done;
  wire [31:0] vec_hw_result;
  reg [2:0] audio_state;
  reg [15:0] audio_sample;
  localparam A_IDLE=0, A_PUSH=1, A_PUSH_WAIT=2, A_RED=3, A_RED_WAIT=4;
  wire audio_own = AUDIO_STREAM && audio_state != A_IDLE;
  assign audio_ready_o = AUDIO_STREAM && audio_state==A_IDLE &&
                         !vec_start && !vec_hw_stall && !vec_hw_done &&
                         !coef_we_i && !coef_re_i;
  assign audio_done_o = audio_state==A_RED_WAIT && vec_hw_done;
  wire signed [31:0] audio_scaled = $signed(vec_hw_result) >>> 15;
  assign audio_result_o = audio_scaled > 32767 ? 16'h7fff :
                          audio_scaled < -32768 ? 16'h8000 : audio_scaled[15:0];
  assign vec_stall = audio_own ? vec_start : vec_hw_stall;
  assign vec_done = !audio_own && vec_hw_done;
  assign vec_result = vec_hw_result;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin audio_state<=A_IDLE; audio_sample<=0; end
    else case (audio_state)
      A_IDLE: if (audio_valid_i && audio_ready_o) begin
        audio_sample<=audio_sample_i; audio_state<=A_PUSH;
      end
      A_PUSH: audio_state<=A_PUSH_WAIT;
      A_PUSH_WAIT: if (vec_hw_done) audio_state<=A_RED;
      A_RED: audio_state<=A_RED_WAIT;
      A_RED_WAIT: if (vec_hw_done) audio_state<=A_IDLE;
      default: audio_state<=A_IDLE;
    endcase
  end
  rv32_vec_unit u_vec_unit (
    .clk_i       (clk_i),
    .rst_n_i     (rst_n_i),
    .start_i     (audio_own ? (audio_state==A_PUSH || audio_state==A_RED) : vec_start),
    .keep_i      (audio_own ? 1'b1 : idex_valid),
    .commit_i    (audio_own ? 1'b1 : vec_commit),
    .op_i        (audio_own ? (audio_state==A_PUSH ? 2'd0 : 2'd1) : idex_vec_push ? 2'd0 :
                  (idex_alu_op == `ALU_VVRED) ? 2'd1 :
                  (idex_alu_op == `ALU_VVUPD) ? 2'd2 : 2'd3),
    .len_i       (audio_own ? 6'd3 : idex_vec_len),
    .scalar_i    (ex_vec_scalar),
    .acc_i       (audio_own ? 1'b0 : idex_vec_acc),
    .wsel_i      (audio_own ? 1'b0 : idex_vec_coef),
    .data_i      (audio_own ? 1'b1 : idex_vec_data),
    .ch_i        (audio_own ? 2'd3 : idex_vec_ch),
    .coef_we_i    (coef_we_i),
    .coef_re_i    (coef_re_i),
    .coef_src_i   (coef_src_i),
    .coef_ch_i    (coef_ch_i),
    .coef_idx_i   (coef_idx_i),
    .coef_wdata_i (coef_wdata_i),
    .coef_rdata_o (coef_rdata_o),
    // PUSH 的样本取自 rs1（前递后），所以固件要先把样本算进一个寄存器再 push。
    .xin_i       (audio_own ? audio_sample : ex_vec_scalar[15:0]),
    .stall_o     (vec_hw_stall),
    .done_o      (vec_hw_done),
    .result_o    (vec_hw_result),
    .norm_sh_o   (),
    .n_x_o       (),
    .lane0_acc_o ()
  );

  wire transfer_enabled=LOCAL_TRANSFER?transfer_enable_i:1'b0;
  wire fft_hw_stall,fft_hw_done,fft_hw_ready,ac_hw_stall,ac_hw_done,ac_hw_ready;
  wire [31:0] fft_hw_result,ac_hw_result;
  wire fft_allowed=!transfer_enabled||(!idex_fft_io&&
    ((transfer_request_i==1&&!idex_fft_inv)||(transfer_request_i==2&&idex_fft_inv)));
  wire ac_allowed=!transfer_enabled||(!idex_acou_is_io&&
    ((transfer_request_i==3&&idex_alu_op==`ALU_VSUB)||
     (transfer_request_i==4&&idex_alu_op==`ALU_VPHAT)));
  wire take_fft=LOCAL_TRANSFER&&transfer_fft_start_i&&fft_hw_ready&&!(fft_start&&fft_allowed);
  wire take_ac=LOCAL_TRANSFER&&transfer_ac_start_i&&ac_hw_ready&&!(acou_start&&ac_allowed);
  assign fft_stall=fft_hw_stall|(fft_start&&!fft_allowed);
  assign fft_done=fft_hw_done&&!take_fft;
  assign fft_result=fft_hw_result;
  assign acou_stall=ac_hw_stall|(acou_start&&!ac_allowed);
  assign acou_done=ac_hw_done&&!take_ac;
  assign acou_result=ac_hw_result;
  assign transfer_fft_ready_o=fft_hw_ready&&!(fft_start&&fft_allowed);
  // The autonomous consumer may change ownership only after architectural retirement.
  wire retired_custom0=retire_valid_o&&retire_instr_o[6:0]==7'h0b;
  assign transfer_fft_done_o=transfer_enabled&&retired_custom0&&retire_instr_o[14:12]==7&&retire_instr_o[31]&&retire_instr_o[29];
  assign transfer_fft_result_o=fft_hw_result;
  assign transfer_ac_ready_o=ac_hw_ready&&!(acou_start&&ac_allowed);
  assign transfer_ac_done_o=transfer_enabled&&retired_custom0&&!retire_instr_o[31]&&
    ((transfer_request_i==3&&retire_instr_o[14:12]==6)||(transfer_request_i==4&&retire_instr_o[14:12]==5));
  assign transfer_ac_result_o=ac_hw_result;

  rv32_acoustic_ext #(.LANES(ACOU_LANES),.CN(ACOU_CACHE_N),.BAND_HI(ACOU_BAND_HI)) u_acoustic_ext (
    .clk_i     (clk_i),
    .rst_n_i   (rst_n_i),
    .start_i   (take_ac?1'b1:acou_start&&ac_allowed),
    .keep_i    (take_ac?1'b1:idex_valid),
    .commit_i  (take_ac?1'b1:acou_commit),
    // ⚠ 三元表达式在端口连接里必须**整体加一层括号**：不加时 iverilog 会在
    //   最后一个 `3'd4)` 处报 syntax error，指向的是实例的上一行，很难找。
    .op_i      ((idex_alu_op == `ALU_VCMUL) ? 3'd0 :
                (idex_alu_op == `ALU_VPHAT) ? 3'd1 :
                (idex_alu_op == `ALU_VSUB)  ? 3'd2 :
                (idex_alu_op == `ALU_VRED2) ? 3'd3 : 3'd4),
    .is_io_i   (take_ac?1'b1:idex_acou_is_io),
    .io_sel_i  (take_ac?transfer_ac_sel_i:idex_acou_io_sel),
    .scalar_i  (take_ac?transfer_ac_data_i:ex_acou_scalar),
    .stall_o   (ac_hw_stall),
    .done_o    (ac_hw_done),
    .result_o  (ac_hw_result),.io_ready_o(ac_hw_ready)
  );

  rv32_fft_bfly #(.INV_BAND_LO(FFT_SPARSE_LO),.INV_BAND_COUNT(FFT_SPARSE_COUNT)) u_fft_bfly (
    .clk_i    (clk_i),
    .rst_n_i  (rst_n_i),
    .start_i  (take_fft?1'b1:fft_start&&fft_allowed),
    .keep_i   (take_fft?1'b1:idex_valid),
    .commit_i (take_fft?1'b1:fft_commit),
    .inv_i    (take_fft?transfer_fft_inv_i:idex_fft_inv),
      .sparse_inv_i(transfer_enabled),
    .is_io_i  (take_fft?1'b1:idex_fft_op & idex_fft_io),
    .io_sel_i (take_fft?transfer_fft_pop_i:idex_fft_pop),
    .io_seek_i(take_fft?transfer_fft_seek_i:idex_instr[27]),
    .scalar_i (take_fft?transfer_fft_data_i:ex_fft_scalar),
    .stall_o  (fft_hw_stall),
    .done_o   (fft_hw_done),
    .result_o (fft_hw_result),.io_ready_o(fft_hw_ready)
  );

  rv_ex_mem_reg u_ex_mem_reg (
    .clk_i            (clk_i),
    .rst_n_i          (rst_n_i),
    .hold_i           (exmem_hold),
    // 除法期间给 EX/MEM 灌气泡，而不是像 halt 那样冻住它。冻住会把 halt 那三个坑
    // （重复退休、store 重复执行、重复陷阱）一起继承过来，得多加三道门控；
    // 灌气泡的话被冻结的是气泡不是指令，那三道一道都不用加。
    // ~trap_taken：陷入当拍 EX 里那条更年轻的指令必须一起压掉。id_ex_flush 只把
    // ID/EX 的 valid 清在下一次装载，而这一拍 EX/MEM 采的正是清之前那个 valid ——
    // 于是它会溜进 MEM 退休一次，等处理程序 mret 回来再退休一次（寄存器写两遍、
    // store 写两遍）。CSR 写和 mret 早就用 ~trap_taken 单独堵过，通用通路漏了。
    // **不能扩成 ~redirect**：分支预测错误的当拍，redirect 的发起者正是 ID/EX 里
    // 那条分支自己，压掉它等于把分支吞了。
    .valid_i          (ex_stage_valid & ~div_stall & ~vec_stall & ~acou_stall &
                       ~fft_stall & ~trap_taken),
    .pc_i             (idex_pc),
    .instr_i          (idex_instr),
    .alu_result_i     (ex_alu_result),
    .store_data_i     (ex_store_data),
    .pc_plus4_i       (ex_pc_plus4),
    .rd_i             (ex_rd),
    .wb_sel_i         (ex_wb_sel),
    .mem_size_i       (ex_mem_size),
    .reg_write_i      (ex_reg_write),
    .mem_read_i       (ex_mem_read),
    .mem_write_i      (ex_mem_write),
    .load_unsigned_i  (ex_load_unsigned),
    .fault_i          (ex_fault),
    .valid_o          (exmem_valid),
    .pc_o             (exmem_pc),
    .instr_o          (exmem_instr),
    .alu_result_o     (exmem_alu_result),
    .store_data_o     (exmem_store_data),
    .pc_plus4_o       (exmem_pc_plus4),
    .rd_o             (exmem_rd),
    .wb_sel_o         (exmem_wb_sel),
    .mem_size_o       (exmem_mem_size),
    .reg_write_o      (exmem_reg_write),
    .mem_read_o       (exmem_mem_read),
    .mem_write_o      (exmem_mem_write),
    .load_unsigned_o  (exmem_load_unsigned),
    .fault_o          (exmem_fault)
  );

  rv32_memory_stage u_memory_stage (
    .valid_i          (exmem_valid),
    .pc_i             (exmem_pc),
    .instr_i          (exmem_instr),
    .alu_result_i     (exmem_alu_result),
    .store_data_i     (exmem_store_data),
    .pc_plus4_i       (exmem_pc_plus4),
    .rd_i             (exmem_rd),
    .wb_sel_i         (exmem_wb_sel),
    .mem_size_i       (exmem_mem_size),
    .reg_write_i      (exmem_reg_write),
    .mem_read_i       (exmem_mem_read),
    .mem_write_i      (exmem_mem_write),
    .load_unsigned_i  (exmem_load_unsigned),
    .fault_i          (exmem_fault),
    .dmem_req_o       (mem_dmem_req),
    .dmem_write_o     (mem_dmem_write),
    .dmem_addr_o      (dmem_addr_o),
    .dmem_wdata_o     (dmem_wdata_o),
    .dmem_wstrb_o     (dmem_wstrb_o),
    .dmem_ready_i     (dmem_ready_i),
    .dmem_rdata_i     (dmem_rdata_i),
    .memory_stall_o   (memory_stall),
    .forward_data_o   (mem_forward_data),
    .load_data_o      (mem_load_data),
    .rd_o             (mem_rd),
    .wb_sel_o         (mem_wb_sel),
    .reg_write_o      (mem_reg_write),
    .fault_o          (mem_fault)
  );

  rv_mem_wb_reg u_mem_wb_reg (
    .clk_i         (clk_i),
    .rst_n_i       (rst_n_i),
    // Preserve the unretired WB instruction across HALT as well as memory waits.
    .hold_i        (memory_stall | halt_i),
    .valid_i       (exmem_valid & ~halt_i),
    .pc_i          (exmem_pc),
    .instr_i       (exmem_instr),
    .alu_result_i  (exmem_alu_result),
    .load_data_i   (mem_load_data),
    .pc_plus4_i    (exmem_pc_plus4),
    .rd_i          (mem_rd),
    .wb_sel_i      (mem_wb_sel),
    .reg_write_i   (mem_reg_write),
    .fault_i       (mem_fault),
    .valid_o       (memwb_valid),
    .pc_o          (memwb_pc),
    .instr_o       (memwb_instr),
    .alu_result_o  (memwb_alu_result),
    .load_data_o   (memwb_load_data),
    .pc_plus4_o    (memwb_pc_plus4),
    .rd_o          (memwb_rd),
    .wb_sel_o      (memwb_wb_sel),
    .reg_write_o   (memwb_reg_write),
    .fault_o       (memwb_fault)
  );

  rv32_writeback_stage u_writeback_stage (
    .valid_i       (memwb_valid),
    .alu_result_i  (memwb_alu_result),
    .load_data_i   (memwb_load_data),
    .pc_plus4_i    (memwb_pc_plus4),
    .rd_i          (memwb_rd),
    .wb_sel_i      (memwb_wb_sel),
    .reg_write_i   (memwb_reg_write),
    .fault_i       (memwb_fault),
    .write_en_o    (wb_write_en),
    .write_addr_o  (wb_write_addr),
    .write_data_o  (wb_write_data)
  );

  // halt 期间必须掐断存储器请求：EX/MEM 冻结时 dmem_write_o 仍是电平有效的，
  // 而 DTCM 是隔拍应答，req 保持高会让 ready 每两拍回来一次 —— 冻结的 store 会被
  // 反复执行、反复写。req 掐断后 ready 也回不来，正在等的 load 就地挂起，
  // 解除 halt 后重新应答，符合"原地冻结"的语义。
  assign dmem_req_o   = mem_dmem_req & ~halt_i;
  assign dmem_write_o = mem_dmem_write & ~halt_i;

  // 停顿期间 WB 被 hold 住（见 u_mem_wb_reg 的 hold_i 说明），memwb_valid 会**保持为 1**。
  // 若直接把它当退休信号，同一条指令会在停顿的每一拍重复退休一次 ——
  // minstret 狂涨、退休计数与 trap 脉冲数对不上（tb_rv32_soc 的 DTCM acks 对账就是这么抓到的）。
  // 所以：**内容保持给前递用，退休单独压掉**。
  assign retire_valid_o = memwb_valid & ~memory_stall & ~halt_i;
  assign retire_pc_o    = memwb_pc;
  assign retire_instr_o = memwb_instr;
  assign retire_fault_o = memwb_fault;

endmodule
