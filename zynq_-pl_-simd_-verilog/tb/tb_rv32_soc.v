`timescale 1ns/1ps

module tb_rv32_soc;

  reg clk;
  reg rst_n;
  wire retire_valid;
  wire [31:0] retire_pc;
  wire [31:0] retire_instr;
  wire [3:0] retire_fault;
  integer cycle_count;
  integer error_count;
  integer i;

  // DTCM 探针：存储幂等，双写只有数写周期数才能发现，收尾时要求它等于退休的 store 数。
  integer dtcm_write_cycles;
  integer dtcm_acks;
  integer retired_stores;
  integer retired_loads;
  integer illegal_faults;
  integer load_align_faults;
  integer st_align_faults;
  integer instr_align_faults;
  integer ecall_faults;
  integer ebreak_faults;
  integer traps_taken;
  reg     ready_d;

  // 除法器探针：M 扩展那条多拍通路光比结果，分不出"真跑了 32 拍"还是"恰好算对了"。
  integer div_stall_cycles;
  integer div_stall_runs;
  reg     div_stall_d;

  // PS 侧的端口全部接死：这个 TB 只测核，halt 与 TCM 的 B 口都不参与。
  rv32_soc #(.DAS_ACTIVE_CHANNELS(8)) u_dut (
    .clk_i          (clk),
    .rst_n_i        (rst_n),
    .test_en_i      (1'b0),
    .halt_i         (1'b0),
    .retire_valid_o (retire_valid),
    .retire_pc_o    (retire_pc),
    .retire_instr_o (retire_instr),
    .retire_fault_o (retire_fault),
    .tohost_o       (),
    .tohost_we_o    (),
    .fromhost_i     (32'b0),
    .led_o          (),
    .ps_req_i       (1'b0),
    .ps_write_i     (1'b0),
    .ps_sel_i       (1'b0),
    .ps_addr_i      (32'b0),
    .ps_wdata_i     (32'b0),
    .ps_ready_o     (),
    .ps_rdata_o     (),
    // 阵列系数预装窗口：本 TB 不用它，但**输入必须显式接死** ——
    // 具名例化漏接的输入是悬空 z，进模块变 x（向量单元的写使能就是拿它选的）。
    .coef_we_i       (1'b0),
    .coef_re_i       (1'b0),
    .coef_src_i      (1'b0),
    .coef_ch_i       (1'b0),
    .coef_idx_i      (9'b0),
    .coef_wdata_i    (16'b0),
    .coef_rdata_o    (),
    
    .steer_cfg_wr_i   (1'b0),
    .steer_cfg_rd_i   (1'b0),
    .steer_cfg_addr_i  (7'b0),
    .steer_cfg_wdata_i  (32'b0),
    .steer_cfg_rdata_o  (),
    
    .tacho_i         (1'b0)
  );

  always #5 clk = ~clk;

  task check_word;
    input integer index;
    input [31:0] expected;
    begin
      if (u_dut.u_dtcm.memory[index] !== expected) begin
        $display("ERROR: DTCM[%0d] expected %08x, got %08x",
                 index, expected, u_dut.u_dtcm.memory[index]);
        error_count = error_count + 1;
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    cycle_count = 0;
    error_count = 0;
    dtcm_write_cycles = 0;
    dtcm_acks = 0;
    retired_stores = 0;
    retired_loads = 0;
    illegal_faults = 0;
    load_align_faults = 0;
    st_align_faults = 0;
    instr_align_faults = 0;
    ecall_faults = 0;
    ebreak_faults = 0;
    traps_taken = 0;
    ready_d = 1'b0;
    div_stall_cycles = 0;
    div_stall_runs = 0;
    div_stall_d = 1'b0;

    for (i = 0; i < 4096; i = i + 1) begin
      u_dut.u_itcm.memory[i] = 32'h0000_0013;
      u_dut.u_dtcm.memory[i] = 32'h0000_0000;
    end

    // ── 原有程序：算术前递、store/load、load-use、分支冲刷、RAS 返回 ──────────
    u_dut.u_itcm.memory[0]  = 32'h0050_0093; // addi x1,  x0, 5
    u_dut.u_itcm.memory[1]  = 32'h0070_0113; // addi x2,  x0, 7
    u_dut.u_itcm.memory[2]  = 32'h0020_81b3; // add  x3,  x1, x2
    u_dut.u_itcm.memory[3]  = 32'h0030_2023; // sw   x3,  0(x0)
    u_dut.u_itcm.memory[4]  = 32'h0000_2203; // lw   x4,  0(x0)
    u_dut.u_itcm.memory[5]  = 32'h0012_0293; // addi x5,  x4, 1
    u_dut.u_itcm.memory[6]  = 32'h0002_8463; // beq  x5,  x0, +8
    u_dut.u_itcm.memory[7]  = 32'h00d0_0313; // addi x6,  x0, 13
    u_dut.u_itcm.memory[8]  = 32'h0062_8463; // beq  x5,  x6, +8
    u_dut.u_itcm.memory[9]  = 32'h0630_0393; // wrong path
    u_dut.u_itcm.memory[10] = 32'h0080_046f; // jal  x8,  +8
    u_dut.u_itcm.memory[11] = 32'h0580_0393; // wrong path
    u_dut.u_itcm.memory[12] = 32'h02a0_0393; // addi x7,  x0, 42
    u_dut.u_itcm.memory[13] = 32'h00c0_00ef; // jal  x1,  +12
    u_dut.u_itcm.memory[14] = 32'h04d0_0493; // addi x9,  x0, 77
    u_dut.u_itcm.memory[15] = 32'h0100_006f; // jal  x0,  +16
    u_dut.u_itcm.memory[16] = 32'h0030_0513; // addi x10, x0, 3
    u_dut.u_itcm.memory[17] = 32'h0040_0613; // addi x12, x0, 4
    u_dut.u_itcm.memory[18] = 32'h0000_8067; // jalr x0,  x1, 0
    u_dut.u_itcm.memory[19] = 32'h0050_2223; // sw   x5,  4(x0)
    u_dut.u_itcm.memory[20] = 32'h0070_2423; // sw   x7,  8(x0)
    u_dut.u_itcm.memory[21] = 32'h0090_2623; // sw   x9, 12(x0)
    u_dut.u_itcm.memory[22] = 32'h00a0_2823; // sw   x10,16(x0)

    // done 标志挪到最后，中间插入访存定向测试；DTCM[5] 仍是触发条件，
    // 所以下面这段测试全部跑完才会置位。
    // 陷阱向量要赶在 T6 的非对齐访存之前装好，否则那两条会跳到复位向量 0 重跑程序。
    u_dut.u_itcm.memory[23] = 32'h3700_0093; // addi x1, x0, 0x370   mtvec（处理程序在字 220）
    u_dut.u_itcm.memory[24] = 32'h3050_9073; // csrw mtvec, x1
    u_dut.u_itcm.memory[25] = 32'h0040_006f; // jal  x0,  +4  → 落入 word 26

    // ── T1 背靠背 load：ready 若退化成延迟电平，第 2、3 条 lw 会串到上一条的数据 ──
    u_dut.u_itcm.memory[26] = 32'h0110_0093; // addi x1,  x0, 0x11
    u_dut.u_itcm.memory[27] = 32'h0410_2023; // sw   x1,  64(x0)   DTCM[16]
    u_dut.u_itcm.memory[28] = 32'h0220_0113; // addi x2,  x0, 0x22
    u_dut.u_itcm.memory[29] = 32'h0420_2223; // sw   x2,  68(x0)   DTCM[17]
    u_dut.u_itcm.memory[30] = 32'h0330_0193; // addi x3,  x0, 0x33
    u_dut.u_itcm.memory[31] = 32'h0430_2423; // sw   x3,  72(x0)   DTCM[18]
    u_dut.u_itcm.memory[32] = 32'h0400_2203; // lw   x4,  64(x0)
    u_dut.u_itcm.memory[33] = 32'h0440_2283; // lw   x5,  68(x0)   ← 连续三条，
    u_dut.u_itcm.memory[34] = 32'h0480_2303; // lw   x6,  72(x0)   ← 中间无气泡
    u_dut.u_itcm.memory[35] = 32'h0440_2623; // sw   x4,  76(x0)   DTCM[19]
    u_dut.u_itcm.memory[36] = 32'h0450_2823; // sw   x5,  80(x0)   DTCM[20]
    u_dut.u_itcm.memory[37] = 32'h0460_2a23; // sw   x6,  84(x0)   DTCM[21]

    // ── T2 store→load 同地址 + 覆盖写 ────────────────────────────────────
    // 覆盖写后必须读到新值，验证"写 → 读"的定序。
    u_dut.u_itcm.memory[38] = 32'h0aa0_0093; // addi x1,  x0, 0xAA
    u_dut.u_itcm.memory[39] = 32'h0410_2c23; // sw   x1,  88(x0)   DTCM[22]
    u_dut.u_itcm.memory[40] = 32'h0580_2103; // lw   x2,  88(x0)
    u_dut.u_itcm.memory[41] = 32'h0580_2183; // lw   x3,  88(x0)
    u_dut.u_itcm.memory[42] = 32'h0420_2e23; // sw   x2,  92(x0)   DTCM[23]
    u_dut.u_itcm.memory[43] = 32'h0630_2023; // sw   x3,  96(x0)   DTCM[24]
    u_dut.u_itcm.memory[44] = 32'h0bb0_0093; // addi x1,  x0, 0xBB
    u_dut.u_itcm.memory[45] = 32'h0410_2c23; // sw   x1,  88(x0)   覆盖 → 0xBB
    u_dut.u_itcm.memory[46] = 32'h0580_2203; // lw   x4,  88(x0)
    u_dut.u_itcm.memory[47] = 32'h0640_2223; // sw   x4, 100(x0)   DTCM[25]

    // ── T3 背靠背 store（不同地址）+ 双写探针 ────────────────────────────
    u_dut.u_itcm.memory[48] = 32'h05a0_0093; // addi x1,  x0, 0x5A
    u_dut.u_itcm.memory[49] = 32'h0610_2423; // sw   x1, 104(x0)   DTCM[26]
    u_dut.u_itcm.memory[50] = 32'h0a50_0113; // addi x2,  x0, 0xA5
    u_dut.u_itcm.memory[51] = 32'h0620_2623; // sw   x2, 108(x0)   DTCM[27] ← 连续两笔
    u_dut.u_itcm.memory[52] = 32'h0680_2183; // lw   x3, 104(x0)
    u_dut.u_itcm.memory[53] = 32'h06c0_2203; // lw   x4, 108(x0)
    u_dut.u_itcm.memory[54] = 32'h0630_2823; // sw   x3, 112(x0)   DTCM[28]
    u_dut.u_itcm.memory[55] = 32'h0640_2a23; // sw   x4, 116(x0)   DTCM[29]

    // ── T4 sb/sh 字节通道（SoC 级此前完全没测过）─────────────────────────
    // x1 = 256 作基址，四次 sb 拼出一个字，再用半字/字节访问验证 wstrb 四个通道。
    u_dut.u_itcm.memory[56] = 32'h1000_0093; // addi x1,  x0, 0x100
    u_dut.u_itcm.memory[57] = 32'h0110_0113; // addi x2,  x0, 0x11
    u_dut.u_itcm.memory[58] = 32'h0020_8023; // sb   x2,   0(x1)
    u_dut.u_itcm.memory[59] = 32'h0220_0193; // addi x3,  x0, 0x22
    u_dut.u_itcm.memory[60] = 32'h0030_80a3; // sb   x3,   1(x1)
    u_dut.u_itcm.memory[61] = 32'h0330_0213; // addi x4,  x0, 0x33
    u_dut.u_itcm.memory[62] = 32'h0040_8123; // sb   x4,   2(x1)
    u_dut.u_itcm.memory[63] = 32'h0440_0293; // addi x5,  x0, 0x44
    u_dut.u_itcm.memory[64] = 32'h0050_81a3; // sb   x5,   3(x1)
    u_dut.u_itcm.memory[65] = 32'h0000_a303; // lw   x6,   0(x1)   = 0x44332211
    u_dut.u_itcm.memory[66] = 32'h0060_a223; // sw   x6,   4(x1)   DTCM[65]
    u_dut.u_itcm.memory[67] = 32'h0ab0_0393; // addi x7,  x0, 0xAB
    u_dut.u_itcm.memory[68] = 32'h0070_9023; // sh   x7,   0(x1)   ← 半字写，
    u_dut.u_itcm.memory[69] = 32'h0000_d403; // lhu  x8,   0(x1)   ← 紧跟同地址读
    u_dut.u_itcm.memory[70] = 32'h0080_a423; // sw   x8,   8(x1)   DTCM[66] = 0xAB
    u_dut.u_itcm.memory[71] = 32'h0000_a483; // lw   x9,   0(x1)   = 0x443300AB
    u_dut.u_itcm.memory[72] = 32'h0090_a623; // sw   x9,  12(x1)   DTCM[67]
    u_dut.u_itcm.memory[73] = 32'h0030_c503; // lbu  x10,  3(x1)   = 0x44
    u_dut.u_itcm.memory[74] = 32'h00a0_a823; // sw   x10, 16(x1)   DTCM[68]

    // ── T5 load-use 三种形态 ────────────────────────────────────────────
    // (a) rs1/rs2 同时来自 load
    u_dut.u_itcm.memory[75] = 32'h0550_0093; // addi x1,  x0, 0x55
    u_dut.u_itcm.memory[76] = 32'h0810_2023; // sw   x1, 128(x0)   DTCM[32]
    u_dut.u_itcm.memory[77] = 32'h0800_2103; // lw   x2, 128(x0)
    u_dut.u_itcm.memory[78] = 32'h0021_01b3; // add  x3,  x2, x2   ← 立即消费者
    u_dut.u_itcm.memory[79] = 32'h0830_2223; // sw   x3, 132(x0)   DTCM[33] = 0xAA
    // (b) load 结果当 store 地址（错值会把数据写到别的字）
    u_dut.u_itcm.memory[80] = 32'h0980_0213; // addi x4,  x0, 152
    u_dut.u_itcm.memory[81] = 32'h0840_2423; // sw   x4, 136(x0)   DTCM[34] = 152
    u_dut.u_itcm.memory[82] = 32'h0880_2283; // lw   x5, 136(x0)
    u_dut.u_itcm.memory[83] = 32'h07e0_0313; // addi x6,  x0, 0x7E
    u_dut.u_itcm.memory[84] = 32'h0062_a023; // sw   x6,   0(x5)   DTCM[38]
    // (c) load → 分支（同时压 load-use、分支操作数和重定向）
    u_dut.u_itcm.memory[85] = 32'h0990_0393; // addi x7,  x0, 0x99
    u_dut.u_itcm.memory[86] = 32'h0870_2623; // sw   x7, 140(x0)   DTCM[35] = 0x99
    u_dut.u_itcm.memory[87] = 32'h08c0_2403; // lw   x8, 140(x0)
    u_dut.u_itcm.memory[88] = 32'h0074_0663; // beq  x8,  x7, +12  ← 相等，跳过两条
    u_dut.u_itcm.memory[89] = 32'h7ad0_0493; // addi x9,  x0, 0x7AD  错误路径标记
    u_dut.u_itcm.memory[90] = 32'h0890_2823; // sw   x9, 144(x0)     DTCM[36] 必须保持 0
    u_dut.u_itcm.memory[91] = 32'h0010_0513; // addi x10, x0, 1
    u_dut.u_itcm.memory[92] = 32'h08a0_2a23; // sw   x10,148(x0)     DTCM[37] = 1

    // ── T6 非对齐访问：不发请求、不写存储器、故障仍退休 ──────────────────
    u_dut.u_itcm.memory[93] = 32'h05a0_0093; // addi x1,  x0, 0x5A
    u_dut.u_itcm.memory[94] = 32'h0a10_2023; // sw   x1, 160(x0)   DTCM[40] = 0x5A
    u_dut.u_itcm.memory[95] = 32'h0020_2103; // lw   x2,   2(x0)   加载非对齐 → 故障 2
    u_dut.u_itcm.memory[96] = 32'h0030_2123; // sw   x3,   2(x0)   存储非对齐 → 故障 3
    // 非对齐 store 若漏写会落到 word 0，被 check_word(0, 12) 抓到。

    u_dut.u_itcm.memory[97] = 32'h0040_006f; // jal  x0, +4（原 addi x11 是死代码）陷阱当拍它在 EX

    // ── T7 CSR / 异常入口：词 100 起，陷阱处理程序在词 200（mtvec = 0x320）──────
    // done 标志跟着挪到词 153，所以 98/99 改成跳过 100 的空档。
    u_dut.u_itcm.memory[98] = 32'h0080_006f; // jal  x0,  +8   → 词 100
    u_dut.u_itcm.memory[99] = 32'h0000_0013; // nop

    // 处理程序把每次陷入的 mstatus/mtval/mcause/mepc 分别累加进 x25/x27/x29/x31，
    // 陷阱数进 x28，再把 mepc += 4 跳过陷阱指令后 mret。四路累加和一次性校验
    // mcause、mtval、mepc、MIE→MPIE 保存/清除，比逐个陷阱写存储器紧凑得多。
    u_dut.u_itcm.memory[100] = 32'h00000e13; // addi x28, x0, 0      # trap count
    u_dut.u_itcm.memory[101] = 32'h00000e93; // addi x29, x0, 0      # mcause sum
    u_dut.u_itcm.memory[102] = 32'h00000f93; // addi x31, x0, 0      # mepc sum
    u_dut.u_itcm.memory[103] = 32'h00000d93; // addi x27, x0, 0      # mtval sum
    u_dut.u_itcm.memory[104] = 32'h00000c93; // addi x25, x0, 0      # mstatus sum
    u_dut.u_itcm.memory[105] = 32'h00800093; // addi x1, x0, 8       # MIE
    u_dut.u_itcm.memory[106] = 32'h3000a073; // csrrs x0, mstatus, x1
    u_dut.u_itcm.memory[107] = 32'h12300113; // addi x2, x0, 0x123
    u_dut.u_itcm.memory[108] = 32'h340111f3; // csrrw x3, mscratch, x2
    u_dut.u_itcm.memory[109] = 32'h34002273; // csrrs x4, mscratch, x0
    u_dut.u_itcm.memory[110] = 32'h340fd2f3; // csrrwi x5, mscratch, 31
    u_dut.u_itcm.memory[111] = 32'h3400f373; // csrrci x6, mscratch, 1
    u_dut.u_itcm.memory[112] = 32'h340023f3; // csrr x7, mscratch
    u_dut.u_itcm.memory[113] = 32'h18302823; // sw x3, 400(x0)
    u_dut.u_itcm.memory[114] = 32'h18402a23; // sw x4, 404(x0)
    u_dut.u_itcm.memory[115] = 32'h18502c23; // sw x5, 408(x0)
    u_dut.u_itcm.memory[116] = 32'h18602e23; // sw x6, 412(x0)
    u_dut.u_itcm.memory[117] = 32'h1a702023; // sw x7, 416(x0)
    u_dut.u_itcm.memory[118] = 32'h30102473; // csrr x8, misa
    u_dut.u_itcm.memory[119] = 32'h1a802223; // sw x8, 420(x0)
    u_dut.u_itcm.memory[120] = 32'hc00024f3; // csrr x9, cycle
    u_dut.u_itcm.memory[121] = 32'h00000813; // addi x16, x0, 0      # 8 条填充，拉开两次 rdcycle
    u_dut.u_itcm.memory[122] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[123] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[124] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[125] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[126] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[127] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[128] = 32'h00180813; // addi x16, x16, 1
    u_dut.u_itcm.memory[129] = 32'hc0002573; // csrr x10, cycle
    u_dut.u_itcm.memory[130] = 32'h409505b3; // sub x11, x10, x9
    u_dut.u_itcm.memory[131] = 32'h1ab02423; // sw x11, 424(x0)
    u_dut.u_itcm.memory[132] = 32'h00000073; // ecall
    u_dut.u_itcm.memory[133] = 32'h00e00613; // addi x12, x0, 0xE
    u_dut.u_itcm.memory[134] = 32'h1ac02623; // sw x12, 428(x0)
    u_dut.u_itcm.memory[135] = 32'h00100073; // ebreak
    u_dut.u_itcm.memory[136] = 32'h00b00693; // addi x13, x0, 0xB
    u_dut.u_itcm.memory[137] = 32'h1ad02823; // sw x13, 432(x0)
    u_dut.u_itcm.memory[138] = 32'hffffffff; // .word 0xffffffff
    u_dut.u_itcm.memory[139] = 32'h01100713; // addi x14, x0, 0x11
    u_dut.u_itcm.memory[140] = 32'h1ae02a23; // sw x14, 436(x0)
    u_dut.u_itcm.memory[141] = 32'hbad00793; // addi x15, x0, 0xBAD  # 非对齐 store 若漏写会落到 word 0
    u_dut.u_itcm.memory[142] = 32'h00202783; // lw x15, 2(x0)
    u_dut.u_itcm.memory[143] = 32'h02200093; // addi x1, x0, 0x22
    u_dut.u_itcm.memory[144] = 32'h1a102c23; // sw x1, 440(x0)
    u_dut.u_itcm.memory[145] = 32'h00f02123; // sw x15, 2(x0)
    u_dut.u_itcm.memory[146] = 32'h03300113; // addi x2, x0, 0x33
    u_dut.u_itcm.memory[147] = 32'h1a202e23; // sw x2, 444(x0)
    u_dut.u_itcm.memory[148] = 32'hc0011073; // csrrw x0, cycle, x2
    u_dut.u_itcm.memory[149] = 32'h04400193; // addi x3, x0, 0x44
    u_dut.u_itcm.memory[150] = 32'h1c302023; // sw x3, 448(x0)
    u_dut.u_itcm.memory[151] = 32'h99902273; // csrr x4, 0x999
    u_dut.u_itcm.memory[152] = 32'h05500293; // addi x5, x0, 0x55
    u_dut.u_itcm.memory[153] = 32'h1c502223; // sw x5, 452(x0)
    u_dut.u_itcm.memory[154] = 32'h1dc02423; // sw x28, 456(x0)
    u_dut.u_itcm.memory[155] = 32'h1dd02623; // sw x29, 460(x0)
    u_dut.u_itcm.memory[156] = 32'h1df02823; // sw x31, 464(x0)
    u_dut.u_itcm.memory[157] = 32'h1db02a23; // sw x27, 468(x0)
    u_dut.u_itcm.memory[158] = 32'h1d902c23; // sw x25, 472(x0)
    u_dut.u_itcm.memory[159] = 32'h06400093; // addi x1, x0, 100
    u_dut.u_itcm.memory[160] = 32'h00700113; // addi x2, x0, 7
    u_dut.u_itcm.memory[161] = 32'h0220c1b3; // div  x3, x1, x2        # 100/7 = 14
    u_dut.u_itcm.memory[162] = 32'h1e302023; // sw x3, 480(x0)
    u_dut.u_itcm.memory[163] = 32'h0220e233; // rem  x4, x1, x2        # 100%7 = 2
    u_dut.u_itcm.memory[164] = 32'h1e402223; // sw x4, 484(x0)
    u_dut.u_itcm.memory[165] = 32'h022082b3; // mul  x5, x1, x2        # 700
    u_dut.u_itcm.memory[166] = 32'h1e502423; // sw x5, 488(x0)
    u_dut.u_itcm.memory[167] = 32'h00700a93; // addi x21, x0, 7       # 除数先备好
    u_dut.u_itcm.memory[168] = 32'h00700a13; // addi x20, x0, 7
    u_dut.u_itcm.memory[169] = 32'h06400a13; // addi x20, x0, 100     # DIV 的 rs1 来自这一条
    u_dut.u_itcm.memory[170] = 32'h04002c03; // lw   x24, 64(x0)      # 不相关访存，占住 MEM 两拍
    u_dut.u_itcm.memory[171] = 32'h035a4b33; // div  x22, x20, x21    # 必须是 14，退化成 1 就说明前递丢了
    u_dut.u_itcm.memory[172] = 32'h1f602623; // sw x22, 492(x0)
    u_dut.u_itcm.memory[173] = 32'h0220c533; // div  x10, x1, x2       # 14
    u_dut.u_itcm.memory[174] = 32'h022545b3; // div  x11, x10, x2     # 14/7 = 2
    u_dut.u_itcm.memory[175] = 32'h1eb02823; // sw x11, 496(x0)
    u_dut.u_itcm.memory[176] = 32'h02005633; // divu x12, x0, x0       # 除零 → 商全 1
    u_dut.u_itcm.memory[177] = 32'h1ec02a23; // sw x12, 500(x0)
    u_dut.u_itcm.memory[178] = 32'hffb00693; // addi x13, x0, -5
    u_dut.u_itcm.memory[179] = 32'h0206e733; // rem  x14, x13, x0     # 除零余数 = 被除数
    u_dut.u_itcm.memory[180] = 32'h1ee02c23; // sw x14, 504(x0)
    u_dut.u_itcm.memory[181] = 32'h800007b7; // lui  x15, 0x80000     # INT_MIN
    u_dut.u_itcm.memory[182] = 32'hfff00813; // addi x16, x0, -1
    u_dut.u_itcm.memory[183] = 32'h0307c8b3; // div  x17, x15, x16    # INT_MIN/-1 不陷入
    u_dut.u_itcm.memory[184] = 32'h1f102e23; // sw x17, 508(x0)
    u_dut.u_itcm.memory[185] = 32'h02f79933; // mulh x18, x15, x15    # 2^62 的高半字
    u_dut.u_itcm.memory[186] = 32'h21202023; // sw x18, 512(x0)
    u_dut.u_itcm.memory[187] = 32'h00200b93; // addi x23, x0, 2
    u_dut.u_itcm.memory[188] = 32'h0377a9b3; // mulhsu x19, x15, x23  # -2^32 的高半字
    u_dut.u_itcm.memory[189] = 32'h21302223; // sw x19, 516(x0)
    u_dut.u_itcm.memory[190] = 32'h00100593; // addi x11, x0, 1
    u_dut.u_itcm.memory[191] = 32'h00b02a23; // sw x11, 20(x0)
    u_dut.u_itcm.memory[192] = 32'h0000006f; // jal x0, 0

    u_dut.u_itcm.memory[220] = 32'h30002d73; // csrr x26, mstatus
    u_dut.u_itcm.memory[221] = 32'h01ac8cb3; // add x25, x25, x26
    u_dut.u_itcm.memory[222] = 32'h34302d73; // csrr x26, mtval
    u_dut.u_itcm.memory[223] = 32'h01ad8db3; // add x27, x27, x26
    u_dut.u_itcm.memory[224] = 32'h34202d73; // csrr x26, mcause
    u_dut.u_itcm.memory[225] = 32'h01ae8eb3; // add x29, x29, x26
    u_dut.u_itcm.memory[226] = 32'h001e0e13; // addi x28, x28, 1
    u_dut.u_itcm.memory[227] = 32'h34102f73; // csrr x30, mepc
    u_dut.u_itcm.memory[228] = 32'h01ef8fb3; // add x31, x31, x30
    u_dut.u_itcm.memory[229] = 32'h004f0f13; // addi x30, x30, 4
    u_dut.u_itcm.memory[230] = 32'h341f1073; // csrw mepc, x30
    u_dut.u_itcm.memory[231] = 32'h30200073; // mret

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle_count = cycle_count + 1;

      // DTCM 探针：写周期数与应答周期数。write_enable 和 ready_o 在时钟沿都是
      // 稳定的（寄存器或寄存器派生），计数是精确的。
      if (u_dut.u_dtcm.write_enable) begin
        dtcm_write_cycles = dtcm_write_cycles + 1;
      end
      if (u_dut.u_dtcm.req_i && u_dut.u_dtcm.ready_o) begin
        dtcm_acks = dtcm_acks + 1;
      end

      // 隔拍应答的结构不变量：ready 连高两拍说明它退化成了延迟电平（会串数据）。
      if (u_dut.u_dtcm.ready_o && ready_d) begin
        $display("ERROR: DTCM ready high two cycles in a row (cycle %0d)", cycle_count);
        error_count = error_count + 1;
      end
      ready_d = u_dut.u_dtcm.ready_o;

      // 直接数陷入入口的脉冲：与"带故障退休的指令数"互为不变量。
      if (u_dut.u_core.trap_taken) begin
        traps_taken = traps_taken + 1;
      end

      // 陷入成立那一拍，EX 里那条更年轻的指令马上就要被冲掉，它不许再更新预测器。
      // word 133 的跳转紧跟 ecall，就是为了让这一拍 EX 里真的有控制流指令。
      if (u_dut.u_core.trap_taken && u_dut.u_core.bp_update_valid) begin
        $display("ERROR: branch predictor updated on the trap cycle (cycle %0d)", cycle_count);
        error_count = error_count + 1;
      end

      // 除法器：数 stall 的拍数和"段"数。8 条除法指令各占一段 33 拍（启动 1 + 迭代 32），
      // 段数比拍数更能抓问题 —— 状态机若在 DONE 上重启会合成一段超长的，
      // 若漏了 start 那拍的 stall 则会少一段。
      if (u_dut.u_core.div_stall) begin
        div_stall_cycles = div_stall_cycles + 1;
      end
      if (u_dut.u_core.div_stall & ~div_stall_d) begin
        div_stall_runs = div_stall_runs + 1;
      end
      div_stall_d = u_dut.u_core.div_stall;

      // 从退休端口反推"应该发生多少次访存"，避免手数指令条数写死常量。
      if (retire_valid && (retire_fault == 4'd0)) begin
        if (retire_instr[6:0] == 7'b0100011) begin
          retired_stores = retired_stores + 1;
        end
        if (retire_instr[6:0] == 7'b0000011) begin
          retired_loads = retired_loads + 1;
        end
      end

      // 故障按编码分类：每种故障在 T6/T7 里都是故意制造的，收尾时逐个核对条数，
      // 顺带核对"带故障退休的指令数"和"真正进入陷阱的次数"一致。
      if (retire_valid && (retire_fault != 4'd0)) begin
        case (retire_fault)
          4'd1: illegal_faults     = illegal_faults + 1;
          4'd2: load_align_faults  = load_align_faults + 1;
          4'd3: st_align_faults    = st_align_faults + 1;
          4'd4: instr_align_faults = instr_align_faults + 1;
          4'd5: ecall_faults       = ecall_faults + 1;
          4'd6: ebreak_faults      = ebreak_faults + 1;
          default: begin
            $display("ERROR: unknown fault %0d at pc=%08x instr=%08x",
                     retire_fault, retire_pc, retire_instr);
            error_count = error_count + 1;
          end
        endcase
      end

      if (u_dut.u_dtcm.memory[5] === 32'd1) begin
        // 原有检查
        check_word(0, 32'd12);
        check_word(1, 32'd13);
        check_word(2, 32'd42);
        check_word(3, 32'd77);
        check_word(4, 32'd3);

        // T1 背靠背 load：三条 lw 必须各自拿到自己地址的数据
        check_word(16, 32'h0000_0011);
        check_word(17, 32'h0000_0022);
        check_word(18, 32'h0000_0033);
        check_word(19, 32'h0000_0011);
        check_word(20, 32'h0000_0022);
        check_word(21, 32'h0000_0033);

        // T2 store→load 同地址 + 覆盖写
        check_word(22, 32'h0000_00BB);
        check_word(23, 32'h0000_00AA);
        check_word(24, 32'h0000_00AA);
        check_word(25, 32'h0000_00BB);

        // T3 背靠背 store
        check_word(26, 32'h0000_005A);
        check_word(27, 32'h0000_00A5);
        check_word(28, 32'h0000_005A);
        check_word(29, 32'h0000_00A5);

        // T4：[64] 的终值是 sh 覆盖后的值，sb 拼出的 0x44332211 由 [65] 钉住。
        check_word(64, 32'h4433_00AB);
        check_word(65, 32'h4433_2211);
        check_word(66, 32'h0000_00AB);
        check_word(67, 32'h4433_00AB);
        check_word(68, 32'h0000_0044);

        // T5 load-use 三种形态
        check_word(32, 32'h0000_0055);
        check_word(33, 32'h0000_00AA);
        check_word(34, 32'd152);
        check_word(38, 32'h0000_007E);
        check_word(35, 32'h0000_0099);
        check_word(36, 32'h0000_0000);   // 分支走对时错误路径不该写这里
        check_word(37, 32'd1);

        // T6 非对齐 store 没有落地
        check_word(40, 32'h0000_005A);

        // ── T7 CSR 读改写语义 ──────────────────────────────────────────
        check_word(100, 32'd0);           // csrrw 读回的旧值
        check_word(101, 32'h0000_0123);   // csrrs rs1=x0 只读不写
        check_word(102, 32'h0000_0123);   // csrrwi 读回的旧值
        check_word(103, 32'd31);          // csrrci 读回的旧值
        check_word(104, 32'd30);          // 清除最低位后的终值
        check_word(105, 32'h4000_1100);   // misa: MXL=32 + 扩展 I + M

        // 两次 rdcycle 相隔 9 条指令，cycle 每拍 +1，所以差值是 9 加上流水气泡。
        // 只校验区间：计数器停摆（0）或速率不对都会掉出去，个别气泡不影响。
        if ((u_dut.u_dtcm.memory[106] < 32'd9) || (u_dut.u_dtcm.memory[106] > 32'd24)) begin
          $display("ERROR: rdcycle delta %0d out of [9,24]", u_dut.u_dtcm.memory[106]);
          error_count = error_count + 1;
        end

        // ── T7 异常入口：每次陷入后 mret 都回到 mepc+4 ──────────────────
        check_word(107, 32'h0000_000E);   // ecall 之后的那条指令确实执行了
        check_word(108, 32'h0000_000B);
        check_word(109, 32'h0000_0011);
        check_word(110, 32'h0000_0022);
        check_word(111, 32'h0000_0033);
        check_word(112, 32'h0000_0044);
        check_word(113, 32'h0000_0055);

        // ── T7 陷阱记录：计数、mcause 和、mepc 和、mtval 和、mstatus 和 ──
        check_word(114, 32'd7);           // 7 次陷进处理程序
        check_word(115, 32'd30);          // 11+3+2+4+6+2+2
        check_word(116, 32'h0000_0F7C);   // 七个 mepc 之和（0x210..0x25c）
        check_word(117, 32'h5991_32E9);   // ecall/ebreak 记 0；非法记指令码；
                                          // 非对齐记地址 2；另加两条非法 CSR 的指令码
        check_word(118, 32'h0000_AB80);   // 7 × 0x1880：MIE 存进 MPIE 后清零

        // ── T8：M 扩展 ─────────────────────────────────────────────────
        check_word(120, 32'd14);           // div 100/7
        check_word(121, 32'd2);            // rem 100%7
        check_word(122, 32'd700);          // mul 100*7
        // 这条是 start 限定条件的判别式：DIV 的 rs1 由隔着一条 lw 的前一条 addi 产生，
        // 若 start 被 memory_stall 推后一拍，前递源消失会算出 7/7 = 1。
        check_word(123, 32'd14);           // div，rs1 只能从 MEM/WB 前递拿到
        check_word(124, 32'd2);            // 背靠背 div 的第二条（吃到第一条的 rd）
        check_word(125, 32'hFFFF_FFFF);    // divu x/0 → 商全 1
        check_word(126, 32'hFFFF_FFFB);    // rem -5%0 → 余数 = 被除数
        check_word(127, 32'h8000_0000);    // div INT_MIN/-1 不陷入
        check_word(128, 32'h4000_0000);    // mulh 高半字
        check_word(129, 32'hFFFF_FFFF);    // mulhsu 高半字（只修正 rs1）

        // ── 结构与计数不变量 ───────────────────────────────────────────
        if (illegal_faults != 3) begin
          $display("ERROR: expected 3 illegal faults, got %0d", illegal_faults);
          error_count = error_count + 1;
        end
        if (load_align_faults != 2) begin
          $display("ERROR: expected 2 load-align faults, got %0d", load_align_faults);
          error_count = error_count + 1;
        end
        if (st_align_faults != 2) begin
          $display("ERROR: expected 2 store-align faults, got %0d", st_align_faults);
          error_count = error_count + 1;
        end
        if (instr_align_faults != 0) begin
          $display("ERROR: unexpected instruction-align fault %0d", instr_align_faults);
          error_count = error_count + 1;
        end
        if (ecall_faults != 1) begin
          $display("ERROR: expected 1 ecall, got %0d", ecall_faults);
          error_count = error_count + 1;
        end
        if (ebreak_faults != 1) begin
          $display("ERROR: expected 1 ebreak, got %0d", ebreak_faults);
          error_count = error_count + 1;
        end

        // 每条带故障退休的指令都必须恰好触发一次 trap_taken，一次不多一次不少。
        // 注意 T6 的两条非对齐访存也走这条通路，所以是 9 而不是 7。
        if ((illegal_faults + load_align_faults + st_align_faults +
             instr_align_faults + ecall_faults + ebreak_faults) !== traps_taken) begin
          $display("ERROR: fault retires %0d != trap_taken pulses %0d",
                   illegal_faults + load_align_faults + st_align_faults +
                   instr_align_faults + ecall_faults + ebreak_faults,
                   traps_taken);
          error_count = error_count + 1;
        end
        if (traps_taken !== 9) begin
          $display("ERROR: expected 9 trap entries, got %0d", traps_taken);
          error_count = error_count + 1;
        end

        // M 扩展：除法必须真的多拍。恒 0 的组合"除法器"能骗过一部分向量比对，
        // 但骗不过 stall 的拍数和段数。8 条除法指令 × 33 拍 = 264。
        if (div_stall_runs !== 8) begin
          $display("ERROR: expected 8 divider stall runs, got %0d", div_stall_runs);
          error_count = error_count + 1;
        end
        if (div_stall_cycles < 8 * 32) begin
          $display("ERROR: divider stalled only %0d cycles, expected >= %0d",
                   div_stall_cycles, 8 * 32);
          error_count = error_count + 1;
        end

        // 每笔 store 恰好写一个周期：dmem_write_o 少了 dmem_ready_i 门控这里会翻倍。
        if (dtcm_write_cycles !== retired_stores) begin
          $display("ERROR: DTCM write cycles %0d != retired stores %0d (double write?)",
                   dtcm_write_cycles, retired_stores);
          error_count = error_count + 1;
        end

        // 每个对齐访存恰好被应答一次：ready 编码改了而握手没跟着改这里会对不上。
        if (dtcm_acks !== retired_stores + retired_loads) begin
          $display("ERROR: DTCM acks %0d != retired mem ops %0d",
                   dtcm_acks, retired_stores + retired_loads);
          error_count = error_count + 1;
        end

        if (error_count == 0) begin
          $display("PASS: RV32I five-stage pipeline smoke test (%0d cycles, %0d stores, %0d loads)",
                   cycle_count, retired_stores, retired_loads);
        end else begin
          $display("FAIL: %0d error(s) after %0d cycles", error_count, cycle_count);
        end
        $finish;
      end

      if (cycle_count > 1500) begin
        $display("FAIL: timeout after %0d cycles", cycle_count);
        $finish;
      end
    end
  end

  initial begin
    $dumpfile("build/rv32_soc.vcd");
    $dumpvars(0, tb_rv32_soc);
  end

endmodule
