// OP-V 的**核级**测试：四条自定义指令从取指一路走到写回。
//
// 与 tb_vec_unit.v 的分工：那个测阵列内部（直接捅 bank，验抽头映射和跨趟借位），
// 这个测**核**——译码认不认 0x0B、rs1 的前递能不能进阵列、多拍期间流水冻不冻、
// 结果从哪条通路写回、以及它会不会被退休两遍。两边的失效模式不重叠：
// 阵列里错一个 bank 是"数算错了"，核里错一拍是"这条指令根本没跑"或"跑了两遍"。
//
// 系数 bank 由 TB 直接预装（和 tb_vec_unit 同样的层次引用）。**不能省**：BRAM
// 未写的字是 X，而 X 乘出来还是 X —— 结果既不等于期望值也不报错，只表现为"算错了"。
//
// 判据（先证明观测有效，再断言）：
//   1. 四条指令都真的退休过，条数与程序里写死的一致（40 条）；
//   2. 一条都没多 —— 重复执行会让条数翻倍；
//   3. 全程只该有 t8 那一次**故意**踩的陷入，而且故障码是加载非对齐 ——
//      OP-V 若被译码器当成非法指令，这里会变成别的数；
//   4. DTCM 里八个结果逐位相等；
//   5. 每笔 store 恰好写一个周期（dtcm_write_cycles == retired_stores）；
//   6. vec_stall 的拍数与理论值相等 —— 内环的拍数预算就是拿这个数算的。
//
// VMUL 的语义容易记错：它出的是 **Σ|x| 的原始整数**（块浮点归一化用），不乘系数、
// 不过 Q15，所以 t1/t4/t6 的期望值是 3600 / 360 / 360，不是 Q30。VRED 才是 Q30。
//
// **t4 与 t6 之间隔着 8 次 x'[ch0] 的写入，这不是啰嗦，是 t6 的全部意义**：
// 光测一次 ch1 抓不到通道位接错 —— push 和读用的是同一个 ch，接错时两边一起错，
// 数据落在 ch0 线上、又从 ch0 线上读回来，结果照样对。要让两条 x' 线**同时持有
// 不同的数据**再看 ch1 还是不是原来的值，错位才会露出来。
`timescale 1ns/1ps

module tb_vec_core;

  localparam integer MAX_CYCLES = 20000;

  // 每种 OP-V 在程序里出现几次，收尾时逐条核对。
  // PUSH 33 = t1/t2/t4/t5 各 8 次 + t8 那条（陷入返回后重跑的那一次）。
  localparam integer N_PUSH = 33, N_VRED = 2, N_VUPD = 1, N_VMUL = 4;
  localparam integer N_TRAP = 1;   // 只该有 t8 那一次非对齐 load 陷入
  // 理论 stall 拍数：PUSH 2 拍（IDLE&start 与 DRAIN 各一拍，tree 被跳过）；
  // 归约 1(start) + 1(RUN) + 7(DRAIN) = 9 拍，DRAIN 的 7 拍 = 等累加落地 3 +
  // 三级加法树 3 + 进 DONE 1；双趟再加 1 拍。
  // 32*2 + VMUL(9+10+9+9) + VRED(9+9) + VUPD(9) + t8 的 vpush(2) = 130。
  localparam integer N_STALL = 32*2 + 9 + 10 + 9 + 9 + 9 + 9 + 9 + 2;   // 130

  reg         clk, rst_n;
  wire        retire_valid;
  wire [31:0] retire_pc, retire_instr;
  wire [3:0]  retire_fault;

  integer cycle_count, errors, i;
  integer run_cycles;

  // 探针
  integer vec_stall_cycles, vec_stall_runs, trap_pulses;
  integer dtcm_write_cycles, retired_stores;
  integer n_push, n_vred, n_vupd, n_vmul, n_badf3;
  integer n_faults;
  reg [3:0] fault_code;
  reg     vec_stall_d;

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

  task check;
    input            cond;
    input [8*76-1:0] what;
    begin
      if (!cond) begin
        $display("ERROR: %0s", what);
        errors = errors + 1;
      end
    end
  endtask

  // 预装一个系数：val 是存储格式（Q15 << 8）。generate 的层次下标必须是常量，
  // 所以展开成 case —— 变量下标 iverilog 直接报 "Scope index expression is not constant"。
  task poke_w;
    input integer bank;
    input integer word;
    input [23:0]  val;
    begin
      case (bank)
        0: u_dut.u_core.u_vec_unit.g_lane[0].u_cbank.mem_q[word] = val;
        1: u_dut.u_core.u_vec_unit.g_lane[1].u_cbank.mem_q[word] = val;
        2: u_dut.u_core.u_vec_unit.g_lane[2].u_cbank.mem_q[word] = val;
        3: u_dut.u_core.u_vec_unit.g_lane[3].u_cbank.mem_q[word] = val;
        4: u_dut.u_core.u_vec_unit.g_lane[4].u_cbank.mem_q[word] = val;
        5: u_dut.u_core.u_vec_unit.g_lane[5].u_cbank.mem_q[word] = val;
        6: u_dut.u_core.u_vec_unit.g_lane[6].u_cbank.mem_q[word] = val;
        7: u_dut.u_core.u_vec_unit.g_lane[7].u_cbank.mem_q[word] = val;
        default: ;
      endcase
    end
  endtask

  task check_word;
    input integer index;
    input [31:0]  expected;
    begin
      if (u_dut.u_dtcm.memory[index] !== expected) begin
        $display("ERROR: DTCM[%0d] expected %0d (0x%08x), got 0x%08x",
                 index, expected, expected, u_dut.u_dtcm.memory[index]);
        errors = errors + 1;
      end
    end
  endtask

  // 机器码由一份一次性的 Python 编码器产出（不参与构建）：
  //   LEN = {instr[25], instr[24:20]}，模式字 = instr[29:26] = {CH, DATA, COEF, ACC}。
  // 常数一律用 lui 装：addi 的 12 位立即数是**符号扩展**的，addi x1, x0, 0x4000
  // 只会取到低 12 位 = 0，寄存器静默变成 0，而整段程序照样跑完、照样退休。
  initial begin
    clk         = 1'b0;
    rst_n       = 1'b0;
    cycle_count = 0;
    errors      = 0;
    run_cycles  = 0;
    vec_stall_cycles = 0;
    vec_stall_runs   = 0;
    trap_pulses      = 0;
    dtcm_write_cycles = 0;
    retired_stores    = 0;
    n_push = 0; n_vred = 0; n_vupd = 0; n_vmul = 0; n_badf3 = 0;
    n_faults = 0; fault_code = 4'd0;
    vec_stall_d = 1'b0;

    // 全填 NOP / 全清 DTCM：只喂十几行的话其余字仍是 X，取指拿到未知量会把核带飞。
    for (i = 0; i < 4096; i = i + 1) begin
      u_dut.u_itcm.memory[i] = 32'h0000_0013;
      u_dut.u_dtcm.memory[i] = 32'h0000_0000;
    end

    // 系数 bank 全清，再装 t3 用的两个：w[0]=0.5、w[1]=0.25（Q15<<8）。
    // 其余 6 个 bank 若留着 X，t3 的加法树整条变 X。
    for (i = 0; i < 8; i = i + 1) begin
      poke_w(i, 0, 24'h000000);
    end
    poke_w(0, 0, 24'h400000);   // w[0] = 0.5
    poke_w(1, 0, 24'h200000);   // w[1] = 0.25
    // ── 先把陷入向量装好：t8 会故意踩一次非对齐 load（处理程序在字 220）──────
    u_dut.u_itcm.memory[0]  = 32'h37000093; // addi x1, x0, 0x370      mtvec = 220*4（处理程序在字 220）
    u_dut.u_itcm.memory[1]  = 32'h30509073; // csrw mtvec, x1
    u_dut.u_itcm.memory[2]  = 32'h00000193; // addi x3, x0, 0            DTCM 字基址
    // ── t1：x 线，VMUL 单趟 ────────────────────────────────────────────────
    u_dut.u_itcm.memory[3]  = 32'h06400093; // addi x1, x0, 100
    u_dut.u_itcm.memory[4]  = 32'h0000800b; // vpush x0, x1                x(0)=100
    u_dut.u_itcm.memory[5]  = 32'h0c800093; // addi x1, x0, 200
    u_dut.u_itcm.memory[6]  = 32'h0000800b; // vpush x0, x1                x(1)=200
    u_dut.u_itcm.memory[7]  = 32'h12c00093; // addi x1, x0, 300
    u_dut.u_itcm.memory[8]  = 32'h0000800b; // vpush x0, x1                x(2)=300
    u_dut.u_itcm.memory[9]  = 32'h19000093; // addi x1, x0, 400
    u_dut.u_itcm.memory[10] = 32'h0000800b; // vpush x0, x1                x(3)=400
    u_dut.u_itcm.memory[11] = 32'h1f400093; // addi x1, x0, 500
    u_dut.u_itcm.memory[12] = 32'h0000800b; // vpush x0, x1                x(4)=500
    u_dut.u_itcm.memory[13] = 32'h25800093; // addi x1, x0, 600
    u_dut.u_itcm.memory[14] = 32'h0000800b; // vpush x0, x1                x(5)=600
    u_dut.u_itcm.memory[15] = 32'h2bc00093; // addi x1, x0, 700
    u_dut.u_itcm.memory[16] = 32'h0000800b; // vpush x0, x1                x(6)=700
    u_dut.u_itcm.memory[17] = 32'h32000093; // addi x1, x0, 800
    u_dut.u_itcm.memory[18] = 32'h0000800b; // vpush x0, x1                x(7)=800
    u_dut.u_itcm.memory[19] = 32'h0000310b; // vmul x2, x0, len=0          t1
    u_dut.u_itcm.memory[20] = 32'h0021a023; // sw x2, 0(x3)                DTCM[0] = 3600
    // ── t2：x 线，VMUL 双趟 + 结果立刻被消费 ────────────────────────────────
    u_dut.u_itcm.memory[21] = 32'h38400093; // addi x1, x0, 900
    u_dut.u_itcm.memory[22] = 32'h0000800b; // vpush x0, x1                x(8)=900
    u_dut.u_itcm.memory[23] = 32'h3e800093; // addi x1, x0, 1000
    u_dut.u_itcm.memory[24] = 32'h0000800b; // vpush x0, x1                x(9)=1000
    u_dut.u_itcm.memory[25] = 32'h44c00093; // addi x1, x0, 1100
    u_dut.u_itcm.memory[26] = 32'h0000800b; // vpush x0, x1                x(10)=1100
    u_dut.u_itcm.memory[27] = 32'h4b000093; // addi x1, x0, 1200
    u_dut.u_itcm.memory[28] = 32'h0000800b; // vpush x0, x1                x(11)=1200
    u_dut.u_itcm.memory[29] = 32'h51400093; // addi x1, x0, 1300
    u_dut.u_itcm.memory[30] = 32'h0000800b; // vpush x0, x1                x(12)=1300
    u_dut.u_itcm.memory[31] = 32'h57800093; // addi x1, x0, 1400
    u_dut.u_itcm.memory[32] = 32'h0000800b; // vpush x0, x1                x(13)=1400
    u_dut.u_itcm.memory[33] = 32'h5dc00093; // addi x1, x0, 1500
    u_dut.u_itcm.memory[34] = 32'h0000800b; // vpush x0, x1                x(14)=1500
    u_dut.u_itcm.memory[35] = 32'h64000093; // addi x1, x0, 1600
    u_dut.u_itcm.memory[36] = 32'h0000800b; // vpush x0, x1                x(15)=1600
    u_dut.u_itcm.memory[37] = 32'h0010310b; // vmul x2, x0, len=1          t2
    u_dut.u_itcm.memory[38] = 32'h00110213; // addi x4, x2, 1
    u_dut.u_itcm.memory[39] = 32'h0041a223; // sw x4, 4(x3)                DTCM[1] = 13601
    // ── t3：VRED，系数由 TB 预装（w0=0.5 / w1=0.25，其余 0）─────────────────
    u_dut.u_itcm.memory[40] = 32'h0000110b; // vred x2, x0, len=0          t3
    u_dut.u_itcm.memory[41] = 32'h0021a423; // sw x2, 8(x3)                DTCM[2] = 38502400
    // ── t4：x'[ch1] 线，写入 10..80 ────────────────────────────────────────
    u_dut.u_itcm.memory[42] = 32'h00a00093; // addi x1, x0, 10
    u_dut.u_itcm.memory[43] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(0)=10
    u_dut.u_itcm.memory[44] = 32'h01400093; // addi x1, x0, 20
    u_dut.u_itcm.memory[45] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(1)=20
    u_dut.u_itcm.memory[46] = 32'h01e00093; // addi x1, x0, 30
    u_dut.u_itcm.memory[47] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(2)=30
    u_dut.u_itcm.memory[48] = 32'h02800093; // addi x1, x0, 40
    u_dut.u_itcm.memory[49] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(3)=40
    u_dut.u_itcm.memory[50] = 32'h03200093; // addi x1, x0, 50
    u_dut.u_itcm.memory[51] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(4)=50
    u_dut.u_itcm.memory[52] = 32'h03c00093; // addi x1, x0, 60
    u_dut.u_itcm.memory[53] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(5)=60
    u_dut.u_itcm.memory[54] = 32'h04600093; // addi x1, x0, 70
    u_dut.u_itcm.memory[55] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(6)=70
    u_dut.u_itcm.memory[56] = 32'h05000093; // addi x1, x0, 80
    u_dut.u_itcm.memory[57] = 32'h3000800b; // vpush x0, x1 data=1 ch=1      xp1(7)=80
    u_dut.u_itcm.memory[58] = 32'h3000310b; // vmul x2, x0, data=1 ch=1    t4
    u_dut.u_itcm.memory[59] = 32'h0021a623; // sw x2, 12(x3)               DTCM[3] = 360
    // ── t5：往 x'[ch0] 写 8 个 0.5（t6/t7 都要用），把两条 x' 线的指针分开 ───
    u_dut.u_itcm.memory[60] = 32'h000040b7; // lui  x1, 4                  xp0(0) = 0x4000
    u_dut.u_itcm.memory[61] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[62] = 32'h000040b7; // lui  x1, 4                  xp0(1) = 0x4000
    u_dut.u_itcm.memory[63] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[64] = 32'h000040b7; // lui  x1, 4                  xp0(2) = 0x4000
    u_dut.u_itcm.memory[65] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[66] = 32'h000040b7; // lui  x1, 4                  xp0(3) = 0x4000
    u_dut.u_itcm.memory[67] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[68] = 32'h000040b7; // lui  x1, 4                  xp0(4) = 0x4000
    u_dut.u_itcm.memory[69] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[70] = 32'h000040b7; // lui  x1, 4                  xp0(5) = 0x4000
    u_dut.u_itcm.memory[71] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[72] = 32'h000040b7; // lui  x1, 4                  xp0(6) = 0x4000
    u_dut.u_itcm.memory[73] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    u_dut.u_itcm.memory[74] = 32'h000040b7; // lui  x1, 4                  xp0(7) = 0x4000
    u_dut.u_itcm.memory[75] = 32'h1000800b; // vpush x0, x1 data=1 ch=0
    // ── t6：ch0 刚被写脏，再读一次 ch1 —— 通道位接错时这里会读到 0x4000 那批 ─
    u_dut.u_itcm.memory[76] = 32'h3000310b; // vmul x2, x0, data=1 ch=1    t6：ch0 写脏后再读 ch1
    u_dut.u_itcm.memory[77] = 32'h0021ac23; // sw x2, 24(x3)               DTCM[6] = 360
    // ── t7：VUPD 写系数，再用 VRED 读回来 ─────────────────────────────────
    u_dut.u_itcm.memory[78] = 32'h000022b7; // lui x5, 2                   g = 0.25 (Q15)
    u_dut.u_itcm.memory[79] = 32'h1002a00b; // vupd x0, x5 data=1 ch=0     t7
    u_dut.u_itcm.memory[80] = 32'h0000110b; // vred x2, x0, len=0          t7 读回
    u_dut.u_itcm.memory[81] = 32'h0021a823; // sw x2, 16(x3)               DTCM[4] = 79462400
    // ── t8：让一条非对齐 load 陷入，**紧跟**一条 vpush —— trap 那一拍这条
    // vpush 正在 ID/EX，start 必须被压住：PUSH 的写和指针自增在 start 当拍就
    // 生效，冲掉之后没人撤。处理程序把 mepc +4 跳过陷入指令，返回之后这条
    // vpush 会重新取指、真正执行一次 —— 所以 x'[ch1] 的指针只该 +1。
    // 没压住的话它在 trap 那拍已经加过一次，指针会 +2。──────────────────
    u_dut.u_itcm.memory[82] = 32'h05500093; // addi x1, x0, 0x55           标记值
    u_dut.u_itcm.memory[83] = 32'h00202303; // lw   x6, 2(x0)              非对齐 load → fault 2，陷入
    u_dut.u_itcm.memory[84] = 32'h3000800b; // vpush x0, x1 data=1 ch=1    t8：trap 那拍它在 ID/EX，必须被压掉
    u_dut.u_itcm.memory[85] = 32'h0011ae23; // sw   x1, 28(x3)             DTCM[7] = 0x55，证明陷入返回走通了
    // ── 完成标志 + 原地打转 ────────────────────────────────────────────────
    u_dut.u_itcm.memory[86] = 32'h00100093; // addi x1, x0, 1
    u_dut.u_itcm.memory[87] = 32'h0011aa23; // sw x1, 20(x3)               DTCM[5] = 1 (done)
    u_dut.u_itcm.memory[88] = 32'h0000006f; // jal x0, 0

    // 陷入处理程序（mtvec = 0x370，字 220 起）：记下 mcause 再跳过陷入指令。
    u_dut.u_itcm.memory[220] = 32'h34202373; // csrr x6, mcause
    u_dut.u_itcm.memory[221] = 32'h0261a023; // sw   x6, 32(x3)             DTCM[8] = 2
    u_dut.u_itcm.memory[222] = 32'h34102373; // csrr x6, mepc
    u_dut.u_itcm.memory[223] = 32'h00430313; // addi x6, x6, 4              跳过陷入指令
    u_dut.u_itcm.memory[224] = 32'h34131073; // csrw mepc, x6
    u_dut.u_itcm.memory[225] = 32'h30200073; // mret

    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // 轮询完成标志。卡死也要收场，不能挂在那儿。
    while (u_dut.u_dtcm.memory[5] !== 32'h0000_0001 && run_cycles < MAX_CYCLES) begin
      @(negedge clk);
      run_cycles = run_cycles + 1;
    end

    // 标志是 store 在 MEM 级写下的，那条指令还要一拍才退休。不等这几拍就核对，
    // "store 拍数 == 退休 store 数"永远差最后那条。
    repeat (20) @(negedge clk);

    // ── 1/2. 四条指令都退休过，且一条不多 ────────────────────────────────
    check(run_cycles < MAX_CYCLES, "0 run: the program must reach its done flag");
    check(n_push === N_PUSH, "1 count: every vpush must retire exactly once");
    check(n_vred === N_VRED, "1 count: every vred must retire exactly once");
    check(n_vupd === N_VUPD, "1 count: every vupd must retire exactly once");
    check(n_vmul === N_VMUL, "1 count: every vmul must retire exactly once");
    check(n_badf3 === 0,     "1 count: no OP-V with funct3 outside 000..011");
    check(n_push + n_vred + n_vupd + n_vmul ===
          N_PUSH + N_VRED + N_VUPD + N_VMUL, "2 count: no extra OP-V retirement");

    // ── 3. 译码 / 陷入 ───────────────────────────────────────────────────
    // t8 那一次是**故意**踩的，所以这里不能断言"零陷入"：断言的是"只有那一次、
    // 且故障码就是加载非对齐"。OP-V 若被当成非法指令，n_faults 会是别的数。
    check(trap_pulses === N_TRAP, "3 trap: exactly the one deliberate misaligned load");
    check(n_faults === N_TRAP && fault_code === 4'd2,
          "3 trap: the only retired fault must be the misaligned load (code 2)");

    // ── 4. 结果 ──────────────────────────────────────────────────────────
    check_word(0, 32'd3600);       // t1 Σ|x(7..0)|，原始整数
    check_word(1, 32'd13601);      // t2 Σ|x(15..0)|+1
    check_word(2, 32'd38502400);   // t3 Q30
    check_word(3, 32'd360);        // t4 x'[ch1]
    check_word(4, 32'd79462400);   // t7 Q30，VUPD 之后的系数
    check_word(6, 32'd360);        // t6 x'[ch1] 在 ch0 被写脏之后仍是原值
    // ── 观测有效性：t8 的陷阱真的发生过、处理程序真的跑过 ────────────────
    // 没有这两条，t8 的指针断言会假绿 —— trap 若压根没发生，vpush 只会正常执行一次。
    check_word(7, 32'h0000_0055);  // 处理程序返回后那条 sw 退休了
    check_word(8, 32'd4);          // 处理程序记下的 mcause = 4（加载地址非对齐）

    // ── t8 本体：trap 那拍被压掉的 vpush 不许留下副作用 ──────────────────
    // x'[ch1] 的指针只该被写过一次（t4 的 8 次 + 陷入返回后重跑的 1 次 = 9）。
    // 没压住的话它在 trap 当拍就自增过，这里是 10。
    check(u_dut.u_core.u_vec_unit.n_p_q[1] === 16'd9,
          "t8: a vpush squashed by a trap must not advance the delay-line pointer");

    // ── 5. store 不重复执行 ──────────────────────────────────────────────
    check(dtcm_write_cycles === retired_stores,
          "5 store: each sw must write for exactly one cycle");

    // ── 6. 多拍停顿的拍数 ────────────────────────────────────────────────
    check(vec_stall_runs === N_PUSH + N_VRED + N_VUPD + N_VMUL,
          "6 stall: one stall run per OP-V instruction");
    check(vec_stall_cycles === N_STALL,
          "6 stall: total stall cycles must match the FSM");

    if (errors == 0) begin
      $display("PASS: OP-V through the core (%0d ops, %0d stall cycles, %0d cycles total)",
               N_PUSH + N_VRED + N_VUPD + N_VMUL, vec_stall_cycles, cycle_count);
    end else begin
      $display("FAIL: %0d error(s) after %0d cycles", errors, cycle_count);
    end
    $finish;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cycle_count = cycle_count + 1;

      if (u_dut.u_core.vec_stall) begin
        vec_stall_cycles = vec_stall_cycles + 1;
      end
      if (u_dut.u_core.vec_stall & ~vec_stall_d) begin
        vec_stall_runs = vec_stall_runs + 1;
      end
      vec_stall_d = u_dut.u_core.vec_stall;

      if (u_dut.u_core.trap_taken) begin
        trap_pulses = trap_pulses + 1;
      end

      // 每笔 store 恰好写一个周期：dmem_write_o 少了 ready 门控这里会翻倍。
      if (u_dut.u_dtcm.write_enable) begin
        dtcm_write_cycles = dtcm_write_cycles + 1;
      end

      if (retire_valid) begin
        // 故障不在这里报错：t8 故意踩了一次，收尾时按**条数与故障码**核对。
        // 每条都当场报错的话，那条故意踩的就没法表达。
        if (retire_fault !== 4'd0) begin
          n_faults   = n_faults + 1;
          fault_code = retire_fault;
        end
        if (retire_instr[6:0] == 7'b0001011) begin
          case (retire_instr[14:12])
            3'd0: n_push = n_push + 1;
            3'd1: n_vred = n_vred + 1;
            3'd2: n_vupd = n_vupd + 1;
            3'd3: n_vmul = n_vmul + 1;
            default: begin
              n_badf3 = n_badf3 + 1;
              $display("ERROR: OP-V retired with funct3 = %0d at 0x%08x",
                       retire_instr[14:12], retire_pc);
            end
          endcase
        end
        if (retire_instr[6:0] == 7'b0100011) begin
          retired_stores = retired_stores + 1;
        end
      end
    end
  end

  // 兜底：卡死也要以 FAIL 收场（裸 $finish 的退出码恒 0）。
  // 余量给足，别和 initial 里那个 bounded while 抢同一个阈值：
  // run_cycles 在 negedge 上走、cycle_count 在 posedge 上走，同阈值会看谁先到。
  always @(posedge clk) begin
    if (cycle_count > MAX_CYCLES + 500) begin
      $display("FAIL: OP-V core TB timed out after %0d cycles", cycle_count);
      $finish;
    end
  end

endmodule
