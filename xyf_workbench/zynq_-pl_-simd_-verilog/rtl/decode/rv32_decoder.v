`include "rv32_defines.vh"

module rv32_decoder (
  input  [31:0] instr_i,
  output [4:0]  rs1_o,
  output [4:0]  rs2_o,
  output [4:0]  rd_o,
  output [31:0] imm_o,
  output [4:0]  alu_op_o,
  output [2:0]  branch_op_o,
  output [1:0]  wb_sel_o,
  output [1:0]  mem_size_o,
  output        op_a_pc_o,
  output        op_a_zero_o,
  output        op_b_imm_o,
  output        uses_rs1_o,
  output        uses_rs2_o,
  output        reg_write_o,
  output        mem_read_o,
  output        mem_write_o,
  output        load_unsigned_o,
  output        branch_o,
  output        jal_o,
  output        jalr_o,
  output        is_call_o,
  output        is_return_o,
  output        ecall_o,
  output        ebreak_o,
  output        mret_o,
  output        csr_valid_o,
  output [11:0] csr_addr_o,
  output [1:0]  csr_op_o,
  output        csr_imm_o,
  output        csr_write_o,
  output        illegal_o
);

  wire [6:0] opcode;
  wire [2:0] funct3;
  wire [6:0] funct7;
  wire is_lui;
  wire is_auipc;
  wire is_jal;
  wire is_jalr;
  wire is_branch;
  wire is_load;
  wire is_store;
  wire is_op_imm;
  wire is_op;
  wire is_fence;
  wire valid_branch;
  wire valid_load;
  wire valid_store;
  wire valid_op_imm;
  wire is_op_base;
  wire valid_op_base;
  wire valid_op_m;
  wire valid_op;
  wire valid_instr;
  wire op_add;
  wire op_sub;
  wire op_sll;
  wire op_slt;
  wire op_sltu;
  wire op_xor;
  wire op_srl;
  wire op_sra;
  wire op_or;
  wire op_and;
  wire op_mul;
  wire op_mulh;
  wire op_mulhu;
  wire op_mulhsu;
  wire op_div;
  wire op_divu;
  wire op_rem;
  wire op_remu;

  wire is_system;
  wire [11:0] system_imm;
  wire [11:0] csr_addr;
  wire is_ecall;
  wire is_ebreak;
  wire is_mret;
  wire is_wfi;
  wire is_csr;
  wire csr_write_en;
  wire csr_addr_ok;
  wire csr_illegal;

  // 实现的 CSR 白名单：不在表内的地址按非法指令处理，写只读空间（[11:10] = 11）同理。
  function csr_known;
    input [11:0] addr;
    begin
      case (addr)
        `CSR_MSTATUS, `CSR_MISA, `CSR_MIE, `CSR_MTVEC, `CSR_MSCRATCH,
        `CSR_MEPC, `CSR_MCAUSE, `CSR_MTVAL, `CSR_MIP,
        `CSR_MCYCLE, `CSR_MINSTRET, `CSR_MCYCLEH, `CSR_MINSTRETH,
        `CSR_CYCLE, `CSR_TIME, `CSR_INSTRET,
        `CSR_CYCLEH, `CSR_TIMEH, `CSR_INSTRETH,
        `CSR_MVENDORID, `CSR_MARCHID, `CSR_MIMPID, `CSR_MHARTID:
          csr_known = 1'b1;
        default:
          csr_known = 1'b0;
      endcase
    end
  endfunction

  assign is_system  = (opcode == 7'b1110011);
  assign system_imm = instr_i[31:20];
  assign csr_addr   = instr_i[31:20];
  assign is_ecall   = is_system & (funct3 == 3'b000) & (system_imm == 12'h000);
  assign is_ebreak  = is_system & (funct3 == 3'b000) & (system_imm == 12'h001);
  assign is_mret    = is_system & (funct3 == 3'b000) & (system_imm == 12'h302);
  assign is_wfi     = is_system & (funct3 == 3'b000) & (system_imm == 12'h105);
  assign is_csr     = is_system & (funct3[1:0] != 2'b00);

  // CSRRW/CSRRWI 一定写；CSRRS/CSRRC 及其立即数形式在源操作数为 x0/0 时只读不写，
  // 因此对只读 CSR 也不构成非法访问（csrr rd, cycle 就走这条路）。
  assign csr_write_en = ((funct3 == 3'b001) | (funct3 == 3'b101)) |
                        (((funct3 == 3'b010) | (funct3 == 3'b110) |
                          (funct3 == 3'b011) | (funct3 == 3'b111)) &
                         (rs1_o != 5'd0));
  assign csr_addr_ok  = csr_known(csr_addr);
  assign csr_illegal  = is_csr & (~csr_addr_ok |
                                  (csr_write_en & (csr_addr[11:10] == 2'b11)));

  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct7 = instr_i[31:25];
  assign rs1_o  = instr_i[19:15];
  assign rs2_o  = instr_i[24:20];
  assign rd_o   = instr_i[11:7];

  wire [31:0] imm_gen_out;

  rv32_imm_gen u_imm_gen (
    .instr_i (instr_i),
    .imm_o   (imm_gen_out)
  );

  assign is_lui    = (opcode == 7'b0110111);
  assign is_auipc  = (opcode == 7'b0010111);
  assign is_jal    = (opcode == 7'b1101111);
  assign is_jalr   = (opcode == 7'b1100111) & (funct3 == 3'b000);
  assign is_branch = (opcode == 7'b1100011);
  assign is_load   = (opcode == 7'b0000011);
  assign is_store  = (opcode == 7'b0100011);
  assign is_op_imm = (opcode == 7'b0010011);
  assign is_op     = (opcode == 7'b0110011);
  assign is_fence  = (opcode == 7'b0001111) &
                     ((funct3 == 3'b000) | (funct3 == 3'b001));

  assign valid_branch = (funct3 == 3'b000) | (funct3 == 3'b001) |
                        (funct3 == 3'b100) | (funct3 == 3'b101) |
                        (funct3 == 3'b110) | (funct3 == 3'b111);
  assign valid_load = (funct3 == 3'b000) | (funct3 == 3'b001) |
                      (funct3 == 3'b010) | (funct3 == 3'b100) |
                      (funct3 == 3'b101);
  assign valid_store = (funct3 == 3'b000) | (funct3 == 3'b001) |
                       (funct3 == 3'b010);
  assign valid_op_imm = (funct3 != 3'b001) & (funct3 != 3'b101) |
                        ((funct3 == 3'b001) & (funct7 == 7'b0000000)) |
                        ((funct3 == 3'b101) &
                         ((funct7 == 7'b0000000) | (funct7 == 7'b0100000)));
  assign valid_op_base = ((funct7 == 7'b0000000) &
                          ((funct3 == 3'b000) | (funct3 == 3'b001) |
                           (funct3 == 3'b010) | (funct3 == 3'b011) |
                           (funct3 == 3'b100) | (funct3 == 3'b101) |
                           (funct3 == 3'b110) | (funct3 == 3'b111))) |
                         ((funct7 == 7'b0100000) &
                          ((funct3 == 3'b000) | (funct3 == 3'b101)));
  // M 扩展：funct7 = 0000001 时 funct3 的 8 种编码全部有定义（mul 到 remu）。
  assign valid_op_m = (funct7 == 7'b0000001);
  assign valid_op   = valid_op_base | valid_op_m;

  // ── OP-V：自定义指令（opcode 0x0B = custom-0），四条都由 SIMD-MAC 阵列执行 ──
  //   funct3 = 000 PUSH  001 VRED  010 VUPD  011 VMUL（只认 000..011，funct3[2]=0）
  //   LEN（趟数-1）**占 6 位**：{instr[25], instr[24:20]}，最大 64 趟。
  //   模式字只剩 4 位：instr[26..29] = acc / coef / data / ch。
  //   两者打包进 imm_o 往后带，**不动 ID/EX 的位宽**（imm_o 本来就是 32 位）。
  //   ⚠ 模式字**不是 5 位**：LEN 要 6 位，而 instr[29:20] 一共只有 10 位，装不下 6+5。
  //   按 5 位去取 imm[10] 会拿到恒 0（那个拼接只有 31 位，赋值时零扩展），通道号静默丢掉。
  //   **uses_rs2_o 必须保持 0** —— instr[24:20] 已经不是 rs2 了；照抄 is_op 让 rs2 参与
  //   冒险判定，会在阵列指令紧跟一条 load 之后凭空插一个气泡（不算错，但白等）。
  assign is_op_v    = (opcode == 7'b0001011);
  // custom-1（0x2B）：定位加速器的门铃。**不复用 0x0B** —— 见 rv32_defines.vh
  // 的 ALU_VLOC 注释（0x0B 的 funct3 已用满，而 0x2B 整块空着）。
  // funct3 只有 000（SRP）/001（XSPEC）/010（波束转向）合法；其余保持非法，
  // 让它走 trap，而不是"译成一个什么都不做的操作"。
  // ⚠ 加 010 之前，funct3=010 是靠这条规则**保持非法**的，tb_loc_core 的
  //   「程序 C」拿它当"保留编码必 trap"的样本（tb/tb_loc_core.v:183）。
  //   占掉之后那个 TB 得改用 011 —— 保留编码的存在性没变，只是换了一格。
  assign is_op_v3    = (opcode == 7'b0101011);
  assign valid_op_v3 = is_op_v3 & ((funct3 == 3'b000) |
                                   (funct3 == 3'b001) |
                                   (funct3 == 3'b010));
  // funct3[2] = 0 那半边（000..011）归 rv32_vec_unit 的 SIMD-MAC 阵列；
  // funct3[2] = 1 那半边（100..111）归 rv32_acoustic_ext 的声学扩展单元。
  // 两半边都合法，**不能再用 ~funct3[2] 把后四条挡掉**。
  assign valid_op_v = is_op_v;

  // ⚠ 这个拼接是 **32 位**，不是 31 位：{21'b0, instr[30], instr[29:20]} 正好 21+1+10。
  //   少一位会零扩展成「整体下移一格」，通道号静默丢掉（上面那段注释记的就是这个坑）。
  //   imm[10] = instr[30] 是给 x′ 延迟线的第 4 条通道用的 —— LEN 6 位 + ch 2 位刚好占满。
  assign imm_o = is_op_v ? {21'b0, instr_i[30], instr_i[29:20]} : imm_gen_out;

  assign valid_instr = is_lui | is_auipc | is_jal | is_jalr |
                       (is_branch & valid_branch) |
                       (is_load & valid_load) |
                       (is_store & valid_store) |
                       (is_op_imm & valid_op_imm) |
                       (is_op & valid_op) | is_fence |
                       is_ecall | is_ebreak | is_mret | is_wfi |
                       (is_csr & ~csr_illegal) |
                       (is_op_v & valid_op_v) |
                       (is_op_v3 & valid_op_v3);
  assign illegal_o = ~valid_instr;

  // OP 空间里只有 funct7 = 0000000 才是 ADD/SLL/SLT/SLTU/XOR/OR/AND 这几条。
  // 这个限定不能省：op_* 是一热掩码，互相重叠会被或歪。M 扩展的 funct7 = 0000001
  // 就按 funct3 撞上了这六路里的四路（001/010/011/100/110/111），
  // 例如 REM 的 funct3 = 110 会同时命中 op_or，ALU 结果变成 ALU_REM | ALU_OR。
  // OP-IMM 那边 funct7 是立即数的高位，由 valid_op_imm 负责合法性，这里不重复限。
  assign is_op_base = is_op & (funct7 == 7'b0000000);

  assign op_add  = is_lui | is_auipc | is_jal | is_jalr | is_load | is_store |
                   ((is_op_imm | is_op_base) & (funct3 == 3'b000));
  assign op_sub  = is_op & (funct3 == 3'b000) & (funct7 == 7'b0100000);
  assign op_sll  = (is_op_imm | is_op_base) & (funct3 == 3'b001);
  assign op_slt  = (is_op_imm | is_op_base) & (funct3 == 3'b010);
  assign op_sltu = (is_op_imm | is_op_base) & (funct3 == 3'b011);
  assign op_xor  = (is_op_imm | is_op_base) & (funct3 == 3'b100);
  // funct3 = 101 这两条本来就要靠 funct7 分 SRLI/SRAI，保持原样即可 —— 那个
  // funct7 = 0000000 顺带也把 M 扩展的 0000001 排掉了。
  assign op_srl  = (is_op_imm | is_op) & (funct3 == 3'b101) &
                   (funct7 == 7'b0000000);
  assign op_sra  = (is_op_imm | is_op) & (funct3 == 3'b101) &
                   (funct7 == 7'b0100000);
  assign op_or   = (is_op_imm | is_op_base) & (funct3 == 3'b110);
  assign op_and  = (is_op_imm | is_op_base) & (funct3 == 3'b111);

  // M 扩展：funct7 已经在 valid_op_m 里判过，这里只用 funct3 分流。
  assign op_mul    = is_op & valid_op_m & (funct3 == 3'b000);
  assign op_mulh   = is_op & valid_op_m & (funct3 == 3'b001);
  assign op_mulhsu = is_op & valid_op_m & (funct3 == 3'b010);
  assign op_mulhu  = is_op & valid_op_m & (funct3 == 3'b011);
  assign op_div    = is_op & valid_op_m & (funct3 == 3'b100);
  assign op_divu   = is_op & valid_op_m & (funct3 == 3'b101);
  assign op_rem    = is_op & valid_op_m & (funct3 == 3'b110);
  assign op_remu   = is_op & valid_op_m & (funct3 == 3'b111);

  assign alu_op_o = ({5{op_add}}    & `ALU_ADD)    |
                    ({5{op_sub}}    & `ALU_SUB)    |
                    ({5{op_sll}}    & `ALU_SLL)    |
                    ({5{op_slt}}    & `ALU_SLT)    |
                    ({5{op_sltu}}   & `ALU_SLTU)   |
                    ({5{op_xor}}    & `ALU_XOR)    |
                    ({5{op_srl}}    & `ALU_SRL)    |
                    ({5{op_sra}}    & `ALU_SRA)    |
                    ({5{op_or}}     & `ALU_OR)     |
                    ({5{op_and}}    & `ALU_AND)    |
                    ({5{op_mul}}    & `ALU_MUL)    |
                    ({5{op_mulh}}   & `ALU_MULH)   |
                    ({5{op_mulhu}}  & `ALU_MULHU)  |
                    ({5{op_mulhsu}} & `ALU_MULHSU) |
                    ({5{op_div}}    & `ALU_DIV)    |
                    ({5{op_divu}}   & `ALU_DIVU)   |
                    ({5{op_rem}}    & `ALU_REM)    |
                    ({5{op_remu}}   & `ALU_REMU)   |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b000)}} & `ALU_VPUSH) |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b001)}} & `ALU_VVRED) |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b010)}} & `ALU_VVUPD) |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b011)}} & `ALU_VVMUL) |
                    // ── 声学 DSP 扩展（funct3[2] = 1）──────────────────────
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b100)}} & `ALU_VCMUL) |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b101)}} & `ALU_VPHAT) |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b110)}} & `ALU_VSUB)  |
                    // funct3=111 被 VRED2 与 VFFT 共用，靠 instr[31] 分流。
                    // ⚠ 不加这一个判据的话，VFFT 会被译成 VRED2 —— 而 VRED2
                    //   是"对 X 做归约"，它会跑完 26 趟、把结果写进 rd，
                    //   全程不报错，只是 FFT 根本没发生。
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b111) & ~instr_i[31]}} & `ALU_VRED2) |
                    ({5{is_op_v & valid_op_v & (funct3 == 3'b111) &  instr_i[31]}} & `ALU_VFFT) |
                    // custom-1 的门铃。⚠ **这一项不能漏**：alu_op_o 是纯 OR 一热、
                    // 没有 default，漏了会落成 ALU_ADD 而被当成一条加法**静默执行**。
                    ({5{is_op_v3 & valid_op_v3}} & `ALU_VLOC);

  assign branch_op_o = ({3{is_branch & (funct3 == 3'b000)}} & `BR_EQ)  |
                       ({3{is_branch & (funct3 == 3'b001)}} & `BR_NE)  |
                       ({3{is_branch & (funct3 == 3'b100)}} & `BR_LT)  |
                       ({3{is_branch & (funct3 == 3'b101)}} & `BR_GE)  |
                       ({3{is_branch & (funct3 == 3'b110)}} & `BR_LTU) |
                       ({3{is_branch & (funct3 == 3'b111)}} & `BR_GEU);

  assign wb_sel_o = is_load ? `WB_MEM :
                    (is_jal | is_jalr) ? `WB_PC4 : `WB_ALU;
  assign mem_size_o      = funct3[1:0];
  assign op_a_pc_o       = is_auipc;
  assign op_a_zero_o     = is_lui;
  assign op_b_imm_o      = is_lui | is_auipc | is_jalr | is_load |
                           is_store | is_op_imm;
  assign uses_rs1_o      = is_jalr | is_branch | is_load | is_store |
                           is_op_imm | is_op | (is_csr & ~funct3[2]) | is_op_v;
  assign uses_rs2_o      = is_branch | is_store | is_op;
  // 阵列那半边：只有 VRED(001) 和 VMUL(011) 写 rd；PUSH/VUPD 不写。
  // 判据是 funct3[0]，不是 funct3[1] —— 001 的 bit1 是 0。
  //
  // 声学那半边的 rd 由 **instr[31] 与 funct3 共同**决定（编码见
  // rtl/acoustic/rv32_acoustic_ext.v 头部）：
  //     POP  (110, instr[31]=1) 写 rd      VRED2 (111, instr[31]=0) 写 rd
  //     PUSHA/PUSHB/VCMUL/VPHAT/VSUB 都不写 —— 它们只动内部的 X/Y/Z
  // ⚠ 漏掉这一条时：VRED2 的 rd 不写回（静默保留旧值），POP 读不到东西。
  //   反过来若一律写 rd，PUSH 那几条会把 rd 写成 0 —— 两种都不报错。
  wire acou_writes_rd = is_op_v & valid_op_v & funct3[2] &
                        ((instr_i[31] & (funct3 == 3'b110)) |
                         (~instr_i[31] & (funct3 == 3'b111)));

  // VFFT 的 rd 只在 **POP** 时写（instr[28]=1）；PUSH 不写。
  // 一律写的话 PUSH 会把 rd 清成 0，而"rd 变成 0"不报错、只是后面用它的
  // 指令算出一个看着合理的数。
  wire fft_writes_rd = is_op_v & valid_op_v & (funct3 == 3'b111) &
                       instr_i[31] & instr_i[28];

  assign reg_write_o     = valid_instr &
                           (is_lui | is_auipc | is_jal | is_jalr |
                            is_load | is_op_imm | is_op | is_csr |
                            (is_op_v & valid_op_v & ~funct3[2] & funct3[0]) |
                            acou_writes_rd | fft_writes_rd);
  assign mem_read_o      = is_load & valid_load;
  assign mem_write_o     = is_store & valid_store;
  assign load_unsigned_o = is_load & funct3[2];
  assign branch_o        = is_branch & valid_branch;
  assign jal_o           = is_jal;
  assign jalr_o          = is_jalr;
  assign is_call_o       = (is_jal | is_jalr) &
                           ((rd_o == 5'd1) | (rd_o == 5'd5));
  assign is_return_o     = is_jalr & (rd_o == 5'd0) &
                           ((rs1_o == 5'd1) | (rs1_o == 5'd5)) &
                           (imm_o == 32'b0);

  assign ecall_o     = is_ecall;
  assign ebreak_o    = is_ebreak;
  assign mret_o      = is_mret;
  assign csr_valid_o = is_csr & ~csr_illegal;
  assign csr_addr_o  = csr_addr;
  assign csr_op_o    = ((funct3 == 3'b001) | (funct3 == 3'b101)) ? `CSR_RW :
                       ((funct3 == 3'b010) | (funct3 == 3'b110)) ? `CSR_RS :
                                                                   `CSR_RC;
  assign csr_imm_o   = funct3[2];
  assign csr_write_o = csr_write_en;

endmodule
