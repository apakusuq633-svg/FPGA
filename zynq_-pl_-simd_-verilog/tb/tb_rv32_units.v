`timescale 1ns/1ps
`include "rv32_defines.vh"

module tb_rv32_units;

  reg [31:0] instr;
  wire [31:0] imm;
  wire [4:0] dec_rs1;
  wire [4:0] dec_rs2;
  wire [4:0] dec_rd;
  wire [4:0] dec_alu_op;
  wire [2:0] dec_branch_op;
  wire [1:0] dec_wb_sel;
  wire [1:0] dec_mem_size;
  wire dec_op_a_pc;
  wire dec_op_a_zero;
  wire dec_op_b_imm;
  wire dec_uses_rs1;
  wire dec_uses_rs2;
  wire dec_reg_write;
  wire dec_mem_read;
  wire dec_mem_write;
  wire dec_load_unsigned;
  wire dec_branch;
  wire dec_jal;
  wire dec_jalr;
  wire dec_call;
  wire dec_return;
  wire dec_ecall;
  wire dec_ebreak;
  wire dec_mret;
  wire dec_csr_valid;
  wire [11:0] dec_csr_addr;
  wire [1:0] dec_csr_op;
  wire dec_csr_imm;
  wire dec_csr_write;
  wire dec_illegal;

  reg         csr_clk = 1'b0;
  reg         csr_rst_n;
  reg  [11:0] csr_addr;
  wire [31:0] csr_rdata;
  reg         csr_we;
  reg  [31:0] csr_wdata;
  reg         csr_trap;
  reg  [31:0] csr_trap_pc;
  reg  [3:0]  csr_trap_cause;
  reg  [31:0] csr_trap_value;
  reg         csr_mret;
  reg         csr_retire;
  wire [31:0] csr_mtvec;
  wire [31:0] csr_mepc;
  reg  [31:0] cyc_mark;
  reg  [31:0] inst_mark;

  reg [31:0] alu_a;
  reg [31:0] alu_b;
  reg [4:0] alu_op;
  wire [31:0] alu_result;

  reg [31:0] branch_pc;
  reg [31:0] branch_rs1;
  reg [31:0] branch_rs2;
  reg [31:0] branch_imm;
  reg [2:0] branch_op;
  reg branch_en;
  reg jal_en;
  reg jalr_en;
  wire branch_taken;
  wire [31:0] branch_target;

  reg [31:0] lsu_address;
  reg [31:0] lsu_store_data;
  reg [1:0] lsu_size;
  reg lsu_unsigned;
  reg lsu_read;
  reg lsu_write;
  reg [31:0] lsu_rdata;
  wire [31:0] lsu_mem_addr;
  wire [31:0] lsu_mem_wdata;
  wire [3:0] lsu_mem_wstrb;
  wire lsu_mem_req;
  wire [31:0] lsu_load_data;
  wire lsu_misaligned;

  integer errors;

  always #5 csr_clk = ~csr_clk;

  rv32_decoder u_decoder (
    .instr_i         (instr),
    .rs1_o           (dec_rs1),
    .rs2_o           (dec_rs2),
    .rd_o            (dec_rd),
    .imm_o           (imm),
    .alu_op_o        (dec_alu_op),
    .branch_op_o     (dec_branch_op),
    .wb_sel_o        (dec_wb_sel),
    .mem_size_o      (dec_mem_size),
    .op_a_pc_o       (dec_op_a_pc),
    .op_a_zero_o     (dec_op_a_zero),
    .op_b_imm_o      (dec_op_b_imm),
    .uses_rs1_o      (dec_uses_rs1),
    .uses_rs2_o      (dec_uses_rs2),
    .reg_write_o     (dec_reg_write),
    .mem_read_o      (dec_mem_read),
    .mem_write_o     (dec_mem_write),
    .load_unsigned_o (dec_load_unsigned),
    .branch_o        (dec_branch),
    .jal_o           (dec_jal),
    .jalr_o          (dec_jalr),
    .is_call_o       (dec_call),
    .is_return_o     (dec_return),
    .ecall_o         (dec_ecall),
    .ebreak_o        (dec_ebreak),
    .mret_o          (dec_mret),
    .csr_valid_o     (dec_csr_valid),
    .csr_addr_o      (dec_csr_addr),
    .csr_op_o        (dec_csr_op),
    .csr_imm_o       (dec_csr_imm),
    .csr_write_o     (dec_csr_write),
    .illegal_o       (dec_illegal)
  );

  rv32_csr u_csr (
    .clk_i        (csr_clk),
    .rst_n_i      (csr_rst_n),
    .addr_i       (csr_addr),
    .rdata_o      (csr_rdata),
    .we_i         (csr_we),
    .wdata_i      (csr_wdata),
    .trap_i       (csr_trap),
    .trap_pc_i    (csr_trap_pc),
    .trap_cause_i (csr_trap_cause),
    .trap_value_i (csr_trap_value),
    .mret_i       (csr_mret),
    .retire_i     (csr_retire),
    .mtvec_o      (csr_mtvec),
    .mepc_o       (csr_mepc)
  );

  rv32_alu u_alu (
    .operand_a_i (alu_a),
    .operand_b_i (alu_b),
    .alu_op_i    (alu_op),
    .result_o    (alu_result)
  );

  // 除法器是唯一需要时钟的 M 扩展单元，单开一路时钟，别蹭 csr_clk 那个名字。
  reg         du_clk;
  reg         du_rst_n;
  reg         du_start;
  reg         du_keep;
  reg         du_commit;
  reg         du_signed;
  reg         du_rem;
  reg  [31:0] du_dividend;
  reg  [31:0] du_divisor;
  wire        du_stall;
  wire        du_done;
  wire [31:0] du_result;
  reg  [31:0] du_captured;
  integer     du_cycles;

  always #5 du_clk = ~du_clk;

  rv32_div_unit u_div_unit (
    .clk_i      (du_clk),
    .rst_n_i    (du_rst_n),
    .start_i    (du_start),
    .keep_i     (du_keep),
    .commit_i   (du_commit),
    .signed_i   (du_signed),
    .is_rem_i   (du_rem),
    .dividend_i (du_dividend),
    .divisor_i  (du_divisor),
    .stall_o    (du_stall),
    .done_o     (du_done),
    .result_o   (du_result)
  );

  // 跑一次除法并查结果。顺带断言 stall 的形状和多拍长度 —— 光比结果的话，
  // 一个恒 0 的"除法器"也能骗过一半向量。
  task div_check;
    input        is_signed;
    input        is_rem;
    input [31:0] a;
    input [31:0] b;
    input [31:0] expected;
    input [8*40-1:0] name;
    begin
      @(negedge du_clk);
      du_dividend = a;
      du_divisor  = b;
      du_signed   = is_signed;
      du_rem      = is_rem;
      du_start    = 1'b1;
      du_keep     = 1'b1;
      du_commit   = 1'b0;
      #1;
      // start 那拍不 stall 的话，ID/EX 会在沿上跑掉，除法指令直接丢。
      if (du_stall !== 1'b1) begin
        $display("ERROR: %0s did not stall on the start cycle", name);
        errors = errors + 1;
      end

      @(negedge du_clk);
      du_start = 1'b0;
      du_cycles = 0;
      while (du_done !== 1'b1) begin
        if (du_stall !== 1'b1) begin
          $display("ERROR: %0s dropped stall before done", name);
          errors = errors + 1;
        end
        du_cycles = du_cycles + 1;
        @(negedge du_clk);
      end
      // done 拍必须撤 stall，否则 EX/MEM 的 valid 被压掉，结果永远捕获不进去。
      if (du_stall !== 1'b0) begin
        $display("ERROR: %0s still stalls on the done cycle", name);
        errors = errors + 1;
      end
      du_captured = du_result;

      if (du_captured !== expected) begin
        $display("ERROR: %0s expected %08x, got %08x", name, expected, du_captured);
        errors = errors + 1;
      end
      // 反证多拍真的发生了：恢复余数法 32 次迭代，少一拍都说明状态机没跑对。
      if (du_cycles < 32) begin
        $display("ERROR: %0s only %0d stall cycles, expected 32", name, du_cycles);
        errors = errors + 1;
      end

      du_commit = 1'b1;
      @(negedge du_clk);
      du_commit = 1'b0;
    end
  endtask

  rv32_branch_unit u_branch_unit (
    .pc_i        (branch_pc),
    .rs1_i       (branch_rs1),
    .rs2_i       (branch_rs2),
    .imm_i       (branch_imm),
    .branch_op_i (branch_op),
    .branch_i    (branch_en),
    .jal_i       (jal_en),
    .jalr_i      (jalr_en),
    .taken_o     (branch_taken),
    .target_o    (branch_target)
  );

  rv32_lsu u_lsu (
    .address_i       (lsu_address),
    .store_data_i    (lsu_store_data),
    .size_i          (lsu_size),
    .load_unsigned_i (lsu_unsigned),
    .mem_read_i      (lsu_read),
    .mem_write_i     (lsu_write),
    .memory_rdata_i  (lsu_rdata),
    .memory_addr_o   (lsu_mem_addr),
    .memory_wdata_o  (lsu_mem_wdata),
    .memory_wstrb_o  (lsu_mem_wstrb),
    .memory_req_o    (lsu_mem_req),
    .load_data_o     (lsu_load_data),
    .misaligned_o    (lsu_misaligned)
  );

  task check32;
    input [31:0] actual;
    input [31:0] expected;
    input [8*40-1:0] name;
    begin
      if (actual !== expected) begin
        $display("ERROR: %0s expected %08x, got %08x", name, expected, actual);
        errors = errors + 1;
      end
    end
  endtask

  task check1;
    input actual;
    input expected;
    input [8*40-1:0] name;
    begin
      if (actual !== expected) begin
        $display("ERROR: %0s expected %b, got %b", name, expected, actual);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;
    du_clk = 1'b0;
    du_rst_n = 1'b0;
    du_start = 1'b0;
    du_keep = 1'b0;
    du_commit = 1'b0;
    du_dividend = 32'b0;
    du_divisor = 32'b0;
    du_signed = 1'b0;
    du_rem = 1'b0;
    instr = 32'hfff0_0093;
    alu_a = 0;
    alu_b = 0;
    alu_op = `ALU_ADD;
    branch_pc = 32'h100;
    branch_rs1 = 0;
    branch_rs2 = 0;
    branch_imm = 0;
    branch_op = `BR_NONE;
    branch_en = 0;
    jal_en = 0;
    jalr_en = 0;
    lsu_address = 0;
    lsu_store_data = 0;
    lsu_size = `MEM_WORD;
    lsu_unsigned = 0;
    lsu_read = 0;
    lsu_write = 0;
    lsu_rdata = 32'h80ff_7f01;
    #1;

    check32(imm, 32'hffff_ffff, "I immediate sign extension");
    check1(dec_reg_write, 1'b1, "ADDI register write");
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_ADD}, "ADDI ALU select");

    instr = 32'hfe30_2e23; #1;
    check32(imm, 32'hffff_fffc, "S immediate sign extension");
    check1(dec_mem_write, 1'b1, "SW decode");

    instr = 32'hfe00_0ee3; #1;
    check32(imm, 32'hffff_fffc, "B immediate sign extension");
    check1(dec_branch, 1'b1, "BEQ decode");

    instr = 32'h1234_50b7; #1;
    check32(imm, 32'h1234_5000, "U immediate");
    check1(dec_op_a_zero, 1'b1, "LUI zero operand");

    instr = 32'h0080_006f; #1;
    check32(imm, 32'h0000_0008, "J immediate");
    check1(dec_jal, 1'b1, "JAL decode");

    instr = 32'h4020_81b3; #1;
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_SUB}, "SUB decode");
    instr = 32'h4031_5093; #1;
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_SRA}, "SRAI decode");
    instr = 32'h0000_0000; #1;
    check1(dec_illegal, 1'b1, "illegal instruction detect");
    check1(dec_reg_write, 1'b0, "illegal side-effect suppression");

    alu_a = 32'd9; alu_b = 32'd4; alu_op = `ALU_ADD; #1;
    check32(alu_result, 32'd13, "ALU ADD");
    alu_op = `ALU_SUB; #1; check32(alu_result, 32'd5, "ALU SUB");
    alu_op = `ALU_SLL; #1; check32(alu_result, 32'd144, "ALU SLL");
    alu_a = 32'hffff_ffff; alu_b = 32'd1; alu_op = `ALU_SLT; #1;
    check32(alu_result, 32'd1, "ALU signed SLT");
    alu_op = `ALU_SLTU; #1; check32(alu_result, 32'd0, "ALU unsigned SLTU");
    alu_a = 32'h8000_0000; alu_op = `ALU_SRA; #1;
    check32(alu_result, 32'hc000_0000, "ALU SRA");
    alu_op = `ALU_SRL; #1; check32(alu_result, 32'h4000_0000, "ALU SRL");
    alu_a = 32'h55aa_00ff; alu_b = 32'h0f0f_f0f0;
    alu_op = `ALU_XOR; #1; check32(alu_result, 32'h5aa5_f00f, "ALU XOR");
    alu_op = `ALU_OR;  #1; check32(alu_result, 32'h5faf_f0ff, "ALU OR");
    alu_op = `ALU_AND; #1; check32(alu_result, 32'h050a_00f0, "ALU AND");

    // ── M 扩展：解码 ──────────────────────────────────────────────────────
    // 8 条都是 opcode 0110011 + funct7 0000001，只用 funct3 分流。rd=1, rs1=2, rs2=3。
    instr = 32'h0231_00b3; #1;                   // mul x1, x2, x3
    check1(dec_illegal,   1'b0, "MUL is legal");
    check1(dec_reg_write, 1'b1, "MUL writes rd");
    check1(dec_uses_rs1,  1'b1, "MUL uses rs1");
    check1(dec_uses_rs2,  1'b1, "MUL uses rs2");
    check1(dec_op_b_imm,  1'b0, "MUL operand B is a register");
    check1(dec_mem_read,  1'b0, "MUL does not read memory");
    check1(dec_mem_write, 1'b0, "MUL does not write memory");
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_MUL}, "MUL ALU select");

    // 这条是 op_add 排除项的反证：原来只排 funct7 = 0100000，MUL 会同时命中
    // add 和 mul 两路掩码。改成排"funct7 非 0000000"之后只剩一路。
    instr = 32'h0231_10b3; #1;                   // mulh x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_MULH}, "MULH ALU select");
    instr = 32'h0231_20b3; #1;                   // mulhsu x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_MULHSU}, "MULHSU ALU select");
    instr = 32'h0231_30b3; #1;                   // mulhu x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_MULHU}, "MULHU ALU select");
    instr = 32'h0231_40b3; #1;                   // div x1, x2, x3
    check1(dec_illegal, 1'b0, "DIV is legal");
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_DIV}, "DIV ALU select");
    instr = 32'h0231_50b3; #1;                   // divu x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_DIVU}, "DIVU ALU select");
    instr = 32'h0231_60b3; #1;                   // rem x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_REM}, "REM ALU select");
    instr = 32'h0231_70b3; #1;                   // remu x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_REMU}, "REMU ALU select");

    // funct7 = 0000010 仍未定义，别把整个 OP 空间放开了。
    instr = 32'h0431_00b3; #1;                   // funct7 = 0000010
    check1(dec_illegal, 1'b1, "funct7 = 0000010 is still illegal");

    // funct3 = 101 靠 funct7 分 SRL/SRA，两路掩码不能同时成立。
    instr = 32'h0031_50b3; #1;                   // srl x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_SRL}, "SRL ALU select");
    instr = 32'h4031_50b3; #1;                   // sra x1, x2, x3
    check32({27'b0, dec_alu_op}, {27'b0, `ALU_SRA}, "SRA ALU select");

    // ── M 扩展：乘法 ──────────────────────────────────────────────────────
    // 四条乘法的高半字靠符号位选出的修正项算出，所以向量要覆盖
    // "有符号标志置位但符号位为 0"和两个修正同时生效这两种形态。
    alu_a = 32'd3; alu_b = 32'd5; alu_op = `ALU_MUL; #1;
    check32(alu_result, 32'd15, "MUL 3 x 5");
    alu_a = 32'hffff_ffff; alu_b = 32'd3; #1;
    check32(alu_result, 32'hffff_fffd, "MUL -1 x 3 low word");

    alu_a = 32'h7fff_ffff; alu_b = 32'h7fff_ffff; alu_op = `ALU_MULH; #1;
    check32(alu_result, 32'h3fff_ffff, "MULH max x max");
    alu_a = 32'hffff_ffff; alu_b = 32'hffff_ffff; #1;
    check32(alu_result, 32'h0000_0000, "MULH -1 x -1 (both corrections)");
    alu_a = 32'h8000_0000; alu_b = 32'd2; #1;
    check32(alu_result, 32'hffff_ffff, "MULH INT_MIN x 2");

    alu_a = 32'hffff_ffff; alu_b = 32'hffff_ffff; alu_op = `ALU_MULHU; #1;
    check32(alu_result, 32'hffff_fffe, "MULHU max x max");
    alu_a = 32'h8000_0000; alu_b = 32'h8000_0000; #1;
    check32(alu_result, 32'h4000_0000, "MULHU 2^31 x 2^31");

    // mulhsu：只有 rs1 走有符号。符号位置位时要修正，符号位为 0 时不能修正。
    alu_a = 32'hffff_ffff; alu_b = 32'd2; alu_op = `ALU_MULHSU; #1;
    check32(alu_result, 32'hffff_ffff, "MULHSU -1 x 2 unsigned");
    alu_a = 32'h8000_0000; alu_b = 32'd2; #1;
    check32(alu_result, 32'hffff_ffff, "MULHSU INT_MIN x 2 unsigned");
    alu_a = 32'h7fff_ffff; alu_b = 32'hffff_ffff; #1;
    check32(alu_result, 32'h7fff_fffe, "MULHSU positive signed operand");

    // ── M 扩展：除法器 ────────────────────────────────────────────────────
    repeat (2) @(negedge du_clk);
    du_rst_n = 1'b1;

    // 正数基本盘
    div_check(1'b1, 1'b0, 32'd100, 32'd7, 32'd14,  "DIV 100 / 7");
    div_check(1'b1, 1'b1, 32'd100, 32'd7, 32'd2,   "REM 100 % 7");
    div_check(1'b0, 1'b0, 32'd100, 32'd7, 32'd14,  "DIVU 100 / 7");
    // 商截断趋零、余数符号跟被除数走 —— 这两条是 RISC-V 规范和 C 语义的分界。
    div_check(1'b1, 1'b0, -32'd100, 32'd7, -32'd14, "DIV -100 / 7");
    div_check(1'b1, 1'b1, -32'd100, 32'd7, -32'd2,  "REM -100 % 7");
    div_check(1'b1, 1'b0, 32'd100, -32'd7, -32'd14, "DIV 100 / -7");
    div_check(1'b1, 1'b1, 32'd100, -32'd7, 32'd2,   "REM 100 % -7");
    div_check(1'b1, 1'b0, -32'd100, -32'd7, 32'd14, "DIV -100 / -7");
    div_check(1'b1, 1'b1, -32'd100, -32'd7, -32'd2, "REM -100 % -7");

    // 同一个位模式在有符号和无符号下必须给出不同答案，否则说明符号处理没接上。
    div_check(1'b0, 1'b0, 32'hffff_ffff, 32'd2, 32'h7fff_ffff, "DIVU 0xFFFFFFFF / 2");
    div_check(1'b0, 1'b1, 32'hffff_ffff, 32'd2, 32'h0000_0001, "REMU 0xFFFFFFFF % 2");
    div_check(1'b1, 1'b0, 32'hffff_ffff, 32'd2, 32'h0000_0000, "DIV -1 / 2 truncates to 0");
    div_check(1'b1, 1'b1, 32'hffff_ffff, 32'd2, 32'hffff_ffff, "REM -1 % 2 is -1");

    // 商为 0、被除数小于除数
    div_check(1'b1, 1'b0, 32'd7, 32'd100, 32'd0, "DIV 7 / 100");
    div_check(1'b1, 1'b1, 32'd7, 32'd100, 32'd7, "REM 7 % 100");
    div_check(1'b0, 1'b0, 32'h1234_5678, 32'h10, 32'h0123_4567, "DIVU 0x12345678 / 16");
    div_check(1'b0, 1'b1, 32'h1234_5678, 32'h10, 32'h0000_0008, "REMU 0x12345678 % 16");

    // 规范强制的边界：除零返回全 1 商 + 被除数余数；INT_MIN / -1 不陷入。
    div_check(1'b1, 1'b0, 32'd5, 32'd0, 32'hffff_ffff, "DIV 5 / 0");
    div_check(1'b1, 1'b1, 32'd5, 32'd0, 32'd5, "REM 5 % 0 returns dividend");
    div_check(1'b1, 1'b1, 32'hffff_fffb, 32'd0, 32'hffff_fffb, "REM -5 % 0 returns dividend");
    div_check(1'b0, 1'b0, 32'hdead_beef, 32'd0, 32'hffff_ffff, "DIVU x / 0");
    div_check(1'b1, 1'b0, 32'h8000_0000, -32'd1, 32'h8000_0000, "DIV INT_MIN / -1");
    div_check(1'b1, 1'b1, 32'h8000_0000, -32'd1, 32'h0000_0000, "REM INT_MIN % -1");
    div_check(1'b1, 1'b0, 32'h8000_0000, 32'd2, 32'hc000_0000, "DIV INT_MIN / 2");

    // 背靠背：DONE 退出后必须能立刻接下一次，不能被 IDLE 握手吞掉。
    div_check(1'b1, 1'b0, 32'd100, 32'd7, 32'd14, "DIV back-to-back first");
    div_check(1'b1, 1'b0, 32'd200, 32'd7, 32'd28, "DIV back-to-back second");

    branch_rs1 = 32'hffff_ffff; branch_rs2 = 32'd1;
    branch_imm = 32'd16; branch_op = `BR_LT; branch_en = 1'b1; #1;
    check1(branch_taken, 1'b1, "signed branch comparison");
    check32(branch_target, 32'h0000_0110, "branch target");
    branch_op = `BR_LTU; #1;
    check1(branch_taken, 1'b0, "unsigned branch comparison");
    branch_en = 1'b0; jalr_en = 1'b1; branch_rs1 = 32'h101;
    branch_imm = 32'd4; #1;
    check1(branch_taken, 1'b1, "JALR taken");
    check32(branch_target, 32'h0000_0104, "JALR target bit zero");

    lsu_read = 1'b1; lsu_size = `MEM_BYTE; lsu_address = 32'd2;
    lsu_unsigned = 1'b0; #1;
    check32(lsu_load_data, 32'hffff_ffff, "LB sign extension");
    lsu_unsigned = 1'b1; #1;
    check32(lsu_load_data, 32'h0000_00ff, "LBU zero extension");
    lsu_size = `MEM_HALF; lsu_address = 32'd2; lsu_unsigned = 1'b0; #1;
    check32(lsu_load_data, 32'hffff_80ff, "LH sign extension");
    lsu_read = 1'b0; lsu_write = 1'b1; lsu_size = `MEM_BYTE;
    lsu_address = 32'd3; lsu_store_data = 32'h0000_00aa; #1;
    check32(lsu_mem_wdata, 32'haa00_0000, "SB data alignment");
    check32({28'b0, lsu_mem_wstrb}, 32'h0000_0008, "SB byte enable");
    lsu_size = `MEM_HALF; lsu_address = 32'd2;
    lsu_store_data = 32'h0000_beef; #1;
    check32(lsu_mem_wdata, 32'hbeef_0000, "SH data alignment");
    check32({28'b0, lsu_mem_wstrb}, 32'h0000_000c, "SH byte enable");
    lsu_size = `MEM_WORD; lsu_address = 32'd2; #1;
    check1(lsu_misaligned, 1'b1, "misaligned word detect");
    check1(lsu_mem_req, 1'b0, "misaligned request suppression");

    // ── CSR 堆 ────────────────────────────────────────────────────────────
    csr_rst_n = 1'b0;
    csr_addr = 12'd0; csr_we = 1'b0; csr_wdata = 32'd0;
    csr_trap = 1'b0; csr_trap_pc = 32'd0; csr_trap_cause = 4'd0;
    csr_trap_value = 32'd0; csr_mret = 1'b0; csr_retire = 1'b0;
    repeat (2) @(posedge csr_clk);
    #1; csr_rst_n = 1'b1; @(posedge csr_clk); #1;

    csr_addr = `CSR_MISA;    #1; check32(csr_rdata, 32'h4000_1100, "misa is RV32IM");
    csr_addr = `CSR_MSTATUS; #1; check32(csr_rdata, 32'h0000_1800, "mstatus reset: MPP=11, MIE=0");
    csr_addr = `CSR_MIP;     #1; check32(csr_rdata, 32'd0, "mip reads zero (no interrupt source)");
    csr_addr = `CSR_MTVEC;   #1; check32(csr_mtvec, 32'd0, "mtvec reset");

    csr_addr = `CSR_MSCRATCH; csr_we = 1'b1; csr_wdata = 32'hdead_beef;
    @(posedge csr_clk); #1; csr_we = 1'b0;
    check32(csr_rdata, 32'hdead_beef, "mscratch write then read");

    csr_addr = `CSR_MSTATUS; csr_we = 1'b1; csr_wdata = 32'hffff_ffff;
    @(posedge csr_clk); #1; csr_we = 1'b0;
    check32(csr_rdata, 32'h0000_1888, "mstatus only keeps MIE/MPIE, MPP stays 11");

    // 陷入入口
    csr_trap = 1'b1; csr_trap_pc = 32'h0000_0100;
    csr_trap_cause = `MCAUSE_ECALL_M; csr_trap_value = 32'h0000_001f;
    @(posedge csr_clk); #1; csr_trap = 1'b0;
    csr_addr = `CSR_MEPC;    #1; check32(csr_rdata, 32'h0000_0100, "mepc latched on trap");
    csr_addr = `CSR_MCAUSE;  #1; check32(csr_rdata, 32'd11, "mcause latched on trap");
    csr_addr = `CSR_MTVAL;   #1; check32(csr_rdata, 32'h0000_001f, "mtval latched on trap");
    csr_addr = `CSR_MSTATUS; #1; check32(csr_rdata, 32'h0000_1880, "trap clears MIE and saves it to MPIE");

    // mret 恢复
    csr_mret = 1'b1; @(posedge csr_clk); #1; csr_mret = 1'b0;
    check32(csr_rdata, 32'h0000_1888, "mret restores MIE from MPIE");

    // 低两位硬件清零
    csr_addr = `CSR_MEPC; csr_we = 1'b1; csr_wdata = 32'h0000_0107;
    @(posedge csr_clk); #1; csr_we = 1'b0;
    check32(csr_rdata, 32'h0000_0104, "mepc IALIGN=32 drops the low bits");
    check32(csr_mepc,  32'h0000_0104, "mepc output port matches");
    csr_addr = `CSR_MTVEC; csr_we = 1'b1; csr_wdata = 32'h0000_0203;
    @(posedge csr_clk); #1; csr_we = 1'b0;
    check32(csr_mtvec, 32'h0000_0200, "mtvec mode field forced to direct");

    // 计数器
    csr_addr = `CSR_CYCLE; #1; cyc_mark = csr_rdata;
    repeat (4) @(posedge csr_clk);
    #1; check32(csr_rdata - cyc_mark, 32'd4, "cycle ticks once per clock");

    csr_addr = `CSR_INSTRET; #1; inst_mark = csr_rdata;
    repeat (3) @(posedge csr_clk);
    #1; check32(csr_rdata, inst_mark, "instret holds without retire");
    csr_retire = 1'b1; @(posedge csr_clk); #1; csr_retire = 1'b0;
    check32(csr_rdata, inst_mark + 32'd1, "instret counts one retired instruction");

    // ── SYSTEM 译码 ───────────────────────────────────────────────────────
    instr = 32'h3401_10f3; #1;                   // csrrw x1, mscratch, x2
    check1(dec_csr_valid, 1'b1, "CSRRW is a valid CSR op");
    check1(dec_illegal,   1'b0, "CSRRW is legal");
    check1(dec_csr_write, 1'b1, "CSRRW always writes");
    check1(dec_csr_imm,   1'b0, "CSRRW source is a register");
    check1(dec_uses_rs1,  1'b1, "CSRRW uses rs1");
    check32({20'b0, dec_csr_addr}, 32'h0000_0340, "CSRRW CSR address");
    check32({30'b0, dec_csr_op}, {30'b0, `CSR_RW}, "CSRRW op = RW");

    instr = 32'h3400_20f3; #1;                   // csrrs x1, mscratch, x0
    check1(dec_csr_valid, 1'b1, "CSRRS is a valid CSR op");
    check1(dec_csr_write, 1'b0, "CSRRS with x0 source must not write");
    check32({30'b0, dec_csr_op}, {30'b0, `CSR_RS}, "CSRRS op = RS");

    instr = 32'h3401_20f3; #1;                   // csrrs x1, mscratch, x2
    check1(dec_csr_write, 1'b1, "CSRRS with a real source writes");

    instr = 32'h340f_d0f3; #1;                   // csrrwi x1, mscratch, 31
    check1(dec_csr_imm,   1'b1, "CSRRWI uses the immediate form");
    check1(dec_uses_rs1,  1'b0, "CSRRWI does not use rs1");
    check1(dec_csr_write, 1'b1, "CSRRWI always writes");

    instr = 32'hc000_20f3; #1;                   // csrr x1, cycle
    check1(dec_csr_valid, 1'b1, "rdcycle is a valid CSR op");
    check1(dec_illegal,   1'b0, "reading a read-only CSR is legal");
    check1(dec_csr_write, 1'b0, "rdcycle does not write");

    instr = 32'hc000_90f3; #1;                   // csrrw x0, cycle, x1
    check1(dec_illegal,   1'b1, "writing a read-only CSR is illegal");
    check1(dec_csr_valid, 1'b0, "illegal CSR op is not forwarded as valid");

    instr = 32'h9990_20f3; #1;                   // csrr x1, 0x999
    check1(dec_illegal,   1'b1, "unimplemented CSR address is illegal");

    instr = 32'h0000_0073; #1;                   // ecall
    check1(dec_ecall,   1'b1, "ECALL decode");
    check1(dec_illegal, 1'b0, "ECALL is not an illegal instruction");

    instr = 32'h0010_0073; #1;                   // ebreak
    check1(dec_ebreak,  1'b1, "EBREAK decode");
    check1(dec_illegal, 1'b0, "EBREAK is not an illegal instruction");

    instr = 32'h3020_0073; #1;                   // mret
    check1(dec_mret,    1'b1, "MRET decode");
    check1(dec_illegal, 1'b0, "MRET is not an illegal instruction");

    instr = 32'h1050_0073; #1;                   // wfi
    check1(dec_illegal, 1'b0, "WFI is accepted as a NOP");

    instr = 32'h0000_0000; #1;
    check1(dec_illegal, 1'b1, "all-zero word is illegal");

    if (errors == 0) begin
      $display("PASS: RV32I unit tests");
    end else begin
      $display("FAIL: %0d unit-test error(s)", errors);
    end
    $finish;
  end

endmodule
