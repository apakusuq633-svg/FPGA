`ifndef RV32_DEFINES_VH
`define RV32_DEFINES_VH

`define RV32_XLEN 32

`define ALU_ADD  5'd0
`define ALU_SUB  5'd1
`define ALU_SLL  5'd2
`define ALU_SLT  5'd3
`define ALU_SLTU 5'd4
`define ALU_XOR  5'd5
`define ALU_SRL  5'd6
`define ALU_SRA  5'd7
`define ALU_OR   5'd8
`define ALU_AND  5'd9

// M 扩展。乘法四条在 ALU 里单拍出结果；除法四条只是编码，运算在 rv32_div_unit 里。
`define ALU_MUL    5'd10
`define ALU_MULH   5'd11
`define ALU_MULHU  5'd12
`define ALU_MULHSU 5'd13
`define ALU_DIV    5'd14
`define ALU_DIVU   5'd15
`define ALU_REM    5'd16
`define ALU_REMU   5'd17

// OP-V 自定义指令（opcode 0x0B = custom-0），由 rv32_vec_unit 的 SIMD-MAC 阵列执行。
// 这四条不提高峰值算力，提高的是**指令密度**：一条 VRED 顶 64 条标量乘累加。
// 机器码的位域（LEN 6 位 + acc/coef/data/ch 各 1 位）见 rv32_decoder.v 里 `is_op_v`
// 那一段；抽头映射与逐拍流水见 rtl/vec/rv32_vec_unit.v 头部。
`define ALU_VPUSH 5'd18   // 推进延迟线（写一个样本）
`define ALU_VVRED 5'd19   // 归约：加法树接通
`define ALU_VVUPD 5'd20   // 逐元素：加法树旁路
`define ALU_VVMUL 5'd21   // Σ|x|，块浮点归一化用

// ── 声学 DSP 扩展（funct3[2] = 1 那半边，由 rv32_acoustic_ext 执行）──────────
// 前四条是通用 DSP 形状，这四条是**照声学算法的计算模式**设计的：
// 互谱是复数乘、PHAT 是幅值归一化、SRP 是「查表+插值+归约」、
// 波束形成与 NLMS 都要在**同一趟数据上同时产出点积和能量**。
`define ALU_VCMUL 5'd22   // 复数乘：8 lane 并行，lane 内打包 {re,im} 两个 16 位
`define ALU_VPHAT 5'd23   // 归一化互谱：|G| 近似 + 倒数 LUT + 限带，一条顶整条 PHAT 链
`define ALU_VSUB  5'd24   // 复数共轭乘（G = X_i · conj(X_j)），互谱专用
`define ALU_VRED2 5'd25   // **对偶归约**：一趟同时产出 Σa·b 和 Σb²，NLMS 少算一半

// VFFT：核内的 512 点复数 FFT **及其逆变换**（rtl/acoustic/rv32_fft_bfly.v）。
// 与 VRED2 **共用 funct3=111**，靠 instr[31] 区分（0 = VRED2，1 = VFFT）。
// instr[31] 本来就是「声学半边的 io 选择位」，VFFT 把整条指令都当 io 用：
// instr[28] = 0 → PUSH 灌输入帧，1 → POP 取结果。
//
// funct7 = {instr[31], instr[30], instr[29], instr[28], 27, 26, 25}：
//     0x40 PUSH 输入帧      0x50 RUN（正变换）      0x48 POP 结果
//     0x60 PUSH ψ（逆变换）  0x70 RUN（逆变换）      0x68 POP 结果
// instr[30] 是 VFFT 编码里最后空着的一位：1 = 逆变换（ifft512_real 的形态）。
// 逆变换灌 **513** 条、出 **512** 条，正变换灌 512 条、出 513 条。
`define ALU_VFFT 5'd26

// ── 定位加速器的**门铃**（opcode 0x2B = custom-1，与上面 0x0B 是两块编码空间）──
// 为什么不塞进 0x0B：那里的 funct3 已经用满（000–111 全占，111 还被 VRED2/VFFT
// 靠 instr[31] 分），要加一条就得从既有指令手里抢一格，或者给 valid_op_v 加条件
// —— 后者会波及整条 OP-V 通路。而 **0x2B 之前是非法指令（走 trap）**，整块空着，
// 用它是**零碰撞**。
//
// funct3 选目标块：000 = SRP 空间扫描，001 = 互谱 + PHAT，010 = 波束转向
// （rv32_steer_regs，核 MMIO 页 0xA000 / PS AXI 窗口 0x600）。其余值（011–111）
// 保持非法（`valid_op_v3` 只放这三个）—— 多一个"保留但可译"的编码，
// 就是多一处静默面。门铃的目标块由 rv32_core.v 按 idex_instr[14:12] 分派。
// rd/rs1/rs2 都不用：它只发起，不产生结果（结果由 lw 从各块的窗口读）。
// 发起是**恰好一拍**且**不 stall**，理由见 rv32_core.v 里那一段。
`define ALU_VLOC 5'd27

`define BR_NONE 3'd0
`define BR_EQ   3'd1
`define BR_NE   3'd2
`define BR_LT   3'd3
`define BR_GE   3'd4
`define BR_LTU  3'd5
`define BR_GEU  3'd6

`define WB_ALU 2'd0
`define WB_MEM 2'd1
`define WB_PC4 2'd2

`define MEM_BYTE 2'd0
`define MEM_HALF 2'd1
`define MEM_WORD 2'd2

`define FAULT_NONE        4'd0
`define FAULT_ILLEGAL     4'd1
`define FAULT_LOAD_ALIGN  4'd2
`define FAULT_ST_ALIGN    4'd3
`define FAULT_INSTR_ALIGN 4'd4
`define FAULT_ECALL       4'd5
`define FAULT_EBREAK      4'd6

// mcause 取值（异常，最高位恒 0：未接中断源）
`define MCAUSE_INSTR_ALIGN 4'd0
`define MCAUSE_ILLEGAL     4'd2
`define MCAUSE_EBREAK      4'd3
`define MCAUSE_LOAD_ALIGN  4'd4
`define MCAUSE_ST_ALIGN    4'd6
`define MCAUSE_ECALL_M     4'd11

// CSR 读改写方式
`define CSR_RW 2'd0
`define CSR_RS 2'd1
`define CSR_RC 2'd2

`define CSR_MSTATUS   12'h300
`define CSR_MISA      12'h301
`define CSR_MIE       12'h304
`define CSR_MTVEC     12'h305
`define CSR_MSCRATCH  12'h340
`define CSR_MEPC      12'h341
`define CSR_MCAUSE    12'h342
`define CSR_MTVAL     12'h343
`define CSR_MIP       12'h344
`define CSR_MCYCLE    12'hB00
`define CSR_MINSTRET  12'hB02
`define CSR_MCYCLEH   12'hB80
`define CSR_MINSTRETH 12'hB82
`define CSR_CYCLE     12'hC00
`define CSR_TIME      12'hC01
`define CSR_INSTRET   12'hC02
`define CSR_CYCLEH    12'hC80
`define CSR_TIMEH     12'hC81
`define CSR_INSTRETH  12'hC82
`define CSR_MVENDORID 12'hF11
`define CSR_MARCHID   12'hF12
`define CSR_MIMPID    12'hF13
`define CSR_MHARTID   12'hF14

`endif
