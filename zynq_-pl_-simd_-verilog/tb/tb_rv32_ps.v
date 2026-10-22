// PS-PL 接口测试：PS 侧 AXI 主机 BFM 走完整流程 —— 软复位 → 下载固件 → 放行 →
// 等中断 → 取结果，再反证两道防护（运行期写 TCM 被拒、halt 期间不重复退休）。
//
// 固件（PS 经 AXI 写进 ITCM，不是 $readmemh）：
//   lui  x5, 0x4      x5 = 0x4000 邮箱基址
//   lw   x6, 4(x5)    x6 = FROMHOST
//   addi x7, x0, 100
//   add  x7, x7, x6   x7 = 100 + FROMHOST
//   sw   x7, 0(x0)    DTCM[0] = x7
//   addi x8, x0, 1
//   sw   x8, 0(x5)    TOHOST = 1 → DONE + 中断
//   jal  x0, 0        原地自旋
`timescale 1ns/1ps

module tb_rv32_ps;

  localparam [11:0] R_CTRL       = 12'h000;
  localparam [11:0] R_STATUS     = 12'h004;
  localparam [11:0] R_IRQ_STAT   = 12'h018;
  localparam [11:0] R_IRQ_MASK   = 12'h01C;
  localparam [11:0] R_RETIRE_CNT = 12'h020;
  localparam [11:0] R_RETIRE_PC  = 12'h024;
  localparam [11:0] R_RETIRE_INS = 12'h028;
  localparam [11:0] R_RETIRE_INF = 12'h02C;
  localparam [11:0] R_TRAP_CNT   = 12'h030;
  localparam [11:0] R_TOHOST     = 12'h034;
  localparam [11:0] R_TOHOST_CNT = 12'h038;
  localparam [11:0] R_FROMHOST   = 12'h03C;
  localparam [11:0] R_CYC_TOTAL  = 12'h040;
  localparam [11:0] R_CYC_BUSY   = 12'h044;
  localparam [11:0] R_CYC_IDLE   = 12'h04C;
  localparam [11:0] R_MEM_ADDR   = 12'h080;
  localparam [11:0] R_MEM_WDATA  = 12'h084;
  localparam [11:0] R_MEM_RDATA  = 12'h088;
  localparam [11:0] R_MEM_CTRL   = 12'h08C;
  localparam [11:0] R_LED_STATE  = 12'h090;
  localparam [11:0] R_COEF_ADDR  = 12'h0C0;
  localparam [11:0] R_COEF_WDATA = 12'h0C4;
  localparam [11:0] R_COEF_RDATA = 12'h0C8;
  localparam [11:0] R_COEF_CTRL  = 12'h0CC;

  localparam [1:0] RESP_OKAY   = 2'b00;
  localparam [1:0] RESP_SLVERR = 2'b10;

  // SEL 位在 MEM_ADDR[31]：0 = ITCM，1 = DTCM。
  localparam [31:0] SEL_ITCM = 32'h0000_0000;
  localparam [31:0] SEL_DTCM = 32'h8000_0000;

  reg         clk;
  reg         rst_n;
  integer     errors;
  integer     cycle_count;

  reg  [11:0] awaddr;
  reg         awvalid;
  wire        awready;
  reg  [31:0] wdata;
  reg  [3:0]  wstrb;
  reg         wvalid;
  wire        wready;
  wire [1:0]  bresp;
  wire        bvalid;
  reg         bready;
  reg  [11:0] araddr;
  reg         arvalid;
  wire        arready;
  wire [31:0] rdata;
  wire [1:0]  rresp;
  wire        rvalid;
  reg         rready;
  wire        irq;
  wire        retire_valid;
  wire [31:0] retire_pc;
  wire [31:0] retire_instr;
  wire [3:0]  retire_fault;
  wire [2:0]  led;

  reg  [31:0] program [0:7];
  reg  [31:0] program2 [0:5];
  reg  [31:0] program3 [0:12];
  integer     i;
  integer     timeout;
  integer     steps;
  integer     prev_cnt;
  integer     cur_cnt;
  integer     delta;
  reg  [31:0] rd_val;
  reg  [1:0]  wr_resp;
  integer     halted_store_cycles;
  integer     halted_store_in_exmem;
  integer     running_store_cycles;
  // 灯出现过的中间态。只断言终值分不清"两次写都生效"和"第二次覆盖了第一次"，
  // 所以先证明中间态真的被观测到，再拿它当断言的前提。
  integer     led_seen_5;

  rv32_ps_top #(.DAS_ACTIVE_CHANNELS(8)) u_dut (
    .clk_i          (clk),
    .rst_n_i        (rst_n),
    .s_axi_awaddr   (awaddr),
    .s_axi_awvalid  (awvalid),
    .s_axi_awready  (awready),
    .s_axi_wdata    (wdata),
    .s_axi_wstrb    (wstrb),
    .s_axi_wvalid   (wvalid),
    .s_axi_wready   (wready),
    .s_axi_bresp    (bresp),
    .s_axi_bvalid   (bvalid),
    .s_axi_bready   (bready),
    .s_axi_araddr   (araddr),
    .s_axi_arvalid  (arvalid),
    .s_axi_arready  (arready),
    .s_axi_rdata    (rdata),
    .s_axi_rresp    (rresp),
    .s_axi_rvalid   (rvalid),
    .s_axi_rready   (rready),
    .irq_o          (irq),
    .led_o          (led),
    .tacho_i         (1'b0),
    .retire_valid_o (retire_valid),
    .retire_pc_o    (retire_pc),
    .retire_instr_o (retire_instr),
    .retire_fault_o (retire_fault)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n) begin
      cycle_count = cycle_count + 1;
      if (cycle_count > 20000) begin
        $display("FAIL: timeout after %0d cycles", cycle_count);
        $finish;
      end
    end
    // 核停住期间 DTCM 的写使能必须一次都不出现。数的是核侧那一根（ps_write_enable
    // 是 PS 自己的端口，不在此列）。按存储器的值来判是判不出来的：冻结的 store
    // 重复写的是同一个值，内容根本不变 —— 只有数写使能才看得见。
    if (u_dut.u_soc.halt_i && u_dut.u_soc.u_dtcm.write_enable) begin
      halted_store_cycles = halted_store_cycles + 1;
    end
    if (!u_dut.u_soc.halt_i && u_dut.u_soc.u_core.exmem_valid &&
        u_dut.u_soc.u_core.exmem_mem_write) begin
      running_store_cycles = running_store_cycles + 1;
    end
    if (u_dut.u_soc.halt_i && u_dut.u_soc.u_core.exmem_valid &&
        u_dut.u_soc.u_core.exmem_mem_write) begin
      halted_store_in_exmem = halted_store_in_exmem + 1;
    end
    // 每拍采样灯，粘滞记录中间态。DUT 是 NBA 更新、这里是阻塞采样，
    // 边沿 N 写进去的值最早在边沿 N+1 被采到 —— 只需确认采到过，不必关心差一拍。
    if (led === 4'h5) begin
      led_seen_5 = 1'b1;
    end
  end

  task check32;
    input [31:0] actual;
    input [31:0] expected;
    input [8*56-1:0] name;
    begin
      if (actual !== expected) begin
        $display("ERROR: %0s expected %08x, got %08x", name, expected, actual);
        errors = errors + 1;
      end
    end
  endtask

  task check_at_least;
    input integer actual;
    input integer minimum;
    input [8*56-1:0] name;
    begin
      if (actual < minimum) begin
        $display("ERROR: %0s expected >= %0d, got %0d", name, minimum, actual);
        errors = errors + 1;
      end
    end
  endtask

  // AXI 写：AW/W 一起发，等各自 ready，再收 B。resp 回响应码供反证用例断言。
  task axi_write;
    input  [11:0] addr;
    input  [31:0] data;
    output [1:0]  resp;
    begin
      @(posedge clk);
      awaddr  = addr;
      awvalid = 1'b1;
      wdata   = data;
      wstrb   = 4'hF;
      wvalid  = 1'b1;
      while (!(awready && wready)) begin
        @(posedge clk);
      end
      @(posedge clk);
      awvalid = 1'b0;
      wvalid  = 1'b0;
      bready  = 1'b1;
      while (!bvalid) begin
        @(posedge clk);
      end
      resp = bresp;
      @(posedge clk);
      bready = 1'b0;
    end
  endtask

  task axi_read;
    input  [11:0] addr;
    output [31:0] data;
    begin
      @(posedge clk);
      araddr  = addr;
      arvalid = 1'b1;
      while (!arready) begin
        @(posedge clk);
      end
      @(posedge clk);
      arvalid = 1'b0;
      rready  = 1'b1;
      while (!rvalid) begin
        @(posedge clk);
      end
      data = rdata;
      @(posedge clk);
      rready = 1'b0;
    end
  endtask

  // 第 15 段用的固件：16 个样本进 x 线，再用 **ŝ 那套系数**做一次**双趟**归约，
  // 结果落 DTCM[1]、完成标志落 DTCM[0]。
  //   期望 = ŝ[0]*x(15) + ŝ[1]*x(14) + ŝ[7]*x(8) + ŝ[8]*x(7)（其余 ŝ = 0）
  //        = 16384*1600 + 8192*1500 + 4096*900 + 2048*800 = 43827200
  // **必须双趟**：抽头 t 落在 word (t/8)，单趟只看 word 0 —— 抽头→word 的换算
  // 写错都看不出来（把 idx[8:3] 丢掉，8 个抽头全挤进 word 0，单趟结果一模一样）。
  // 这条是拆掉 coef_ext_word 里那一段做反向验证时发现的。
  // 机器码由一份一次性的 Python 编码器产出（LEN = {instr[25], instr[24:20]}，
  // 模式字 = instr[29:26] = {CH, DATA, COEF, ACC}）。
  localparam integer N_PROG4 = 37;
  reg [31:0] program4 [0:N_PROG4-1];
  initial begin
    program4[0]  = 32'h06400093; // addi x1, x0, 100
    program4[1]  = 32'h0000800b; // vpush x0, x1      x(0)
    program4[2]  = 32'h0c800093; // addi x1, x0, 200
    program4[3]  = 32'h0000800b; // vpush x0, x1      x(1)
    program4[4]  = 32'h12c00093; // addi x1, x0, 300
    program4[5]  = 32'h0000800b; // vpush x0, x1      x(2)
    program4[6]  = 32'h19000093; // addi x1, x0, 400
    program4[7]  = 32'h0000800b; // vpush x0, x1      x(3)
    program4[8]  = 32'h1f400093; // addi x1, x0, 500
    program4[9]  = 32'h0000800b; // vpush x0, x1      x(4)
    program4[10] = 32'h25800093; // addi x1, x0, 600
    program4[11] = 32'h0000800b; // vpush x0, x1      x(5)
    program4[12] = 32'h2bc00093; // addi x1, x0, 700
    program4[13] = 32'h0000800b; // vpush x0, x1      x(6)
    program4[14] = 32'h32000093; // addi x1, x0, 800
    program4[15] = 32'h0000800b; // vpush x0, x1      x(7)
    program4[16] = 32'h38400093; // addi x1, x0, 900
    program4[17] = 32'h0000800b; // vpush x0, x1      x(8)
    program4[18] = 32'h3e800093; // addi x1, x0, 1000
    program4[19] = 32'h0000800b; // vpush x0, x1      x(9)
    program4[20] = 32'h44c00093; // addi x1, x0, 1100
    program4[21] = 32'h0000800b; // vpush x0, x1      x(10)
    program4[22] = 32'h4b000093; // addi x1, x0, 1200
    program4[23] = 32'h0000800b; // vpush x0, x1      x(11)
    program4[24] = 32'h51400093; // addi x1, x0, 1300
    program4[25] = 32'h0000800b; // vpush x0, x1      x(12)
    program4[26] = 32'h57800093; // addi x1, x0, 1400
    program4[27] = 32'h0000800b; // vpush x0, x1      x(13)
    program4[28] = 32'h5dc00093; // addi x1, x0, 1500
    program4[29] = 32'h0000800b; // vpush x0, x1      x(14)
    program4[30] = 32'h64000093; // addi x1, x0, 1600
    program4[31] = 32'h0000800b; // vpush x0, x1      x(15)
    program4[32] = 32'h0810110b; // vred x2, x0, coef=1(ŝ) len=1（双趟）
    program4[33] = 32'h00202223; // sw   x2, 4(x0)    DTCM[1] = 结果
    program4[34] = 32'h00100193; // addi x3, x0, 1
    program4[35] = 32'h00302023; // sw   x3, 0(x0)    DTCM[0] = 1（完成标志）
    program4[36] = 32'h0000006f; // jal  x0, 0
  end

  // 第 15 段装进阵列的 ŝ。故意让 ŝ[7] 落在 bank 7、ŝ[8] 落在 bank 0 的**第二个 word**
  // —— 单趟只看得到 bank 0..7 的 word 0，双趟才用得上 word 1。
  reg [15:0] coef_s [0:15];
  initial begin
    coef_s[0]  = 16'h4000;   // 0.5
    coef_s[1]  = 16'h2000;   // 0.25
    coef_s[2]  = 16'h0000;
    coef_s[3]  = 16'h0000;
    coef_s[4]  = 16'h0000;
    coef_s[5]  = 16'h0000;
    coef_s[6]  = 16'h0000;
    coef_s[7]  = 16'h1000;   // 0.125 —— 落在 bank 7 的 word 0
    coef_s[8]  = 16'h0800;   // 0.0625 —— 落在 bank 0 的 **word 1**
    coef_s[9]  = 16'h0000;
    coef_s[10] = 16'h0000;
    coef_s[11] = 16'h0000;
    coef_s[12] = 16'h0000;
    coef_s[13] = 16'h0000;
    coef_s[14] = 16'h0000;
    coef_s[15] = 16'h0000;
  end

  initial begin
    clk         = 1'b0;
    rst_n       = 1'b0;
    errors      = 0;
    cycle_count = 0;
    halted_store_cycles = 0;
    halted_store_in_exmem = 0;
    running_store_cycles  = 0;
    led_seen_5            = 0;
    awaddr      = 12'b0;
    awvalid     = 1'b0;
    wdata       = 32'b0;
    wstrb       = 4'b0;
    wvalid      = 1'b0;
    bready      = 1'b0;
    araddr      = 12'b0;
    arvalid     = 1'b0;
    rready      = 1'b0;

    program[0] = 32'h0000_42B7;  // lui  x5, 0x4
    program[1] = 32'h0042_A303;  // lw   x6, 4(x5)
    program[2] = 32'h0640_0393;  // addi x7, x0, 100
    program[3] = 32'h0063_83B3;  // add  x7, x7, x6
    program[4] = 32'h0070_2023;  // sw   x7, 0(x0)
    program[5] = 32'h0010_0413;  // addi x8, x0, 1
    program[6] = 32'h0082_A023;  // sw   x8, 0(x5)
    program[7] = 32'h0000_006F;  // jal  x0, 0

    // 第二段固件：自增计数器连写 DTCM[1]/[2]/[3]，然后跳回自增 —— 用于检验
    // halt 期间冻结的 store 会不会被反复执行。
    program2[0] = 32'h0000_0493;  // addi x9, x0, 0
    program2[1] = 32'h0014_8493;  // addi x9, x9, 1
    program2[2] = 32'h0090_2223;  // sw   x9, 4(x0)
    program2[3] = 32'h0090_2423;  // sw   x9, 8(x0)
    program2[4] = 32'h0090_2623;  // sw   x9, 12(x0)
    program2[5] = 32'hFF1F_F06F;  // jal  x0, -16（跳回自增）

    // 第三段固件：驱动核侧 MMIO 0x5000 的 LED，回读确认，然后用 DTCM[0] 报完成。
    //
    // 故意**不写 TOHOST**：这样 DONE / irq / TOHOST_CNT 就全部变成"核只顾点灯、没碰邮箱"
    // 的确定性判据 —— 页限定若漏掉，LED 的每笔写都会命中 tohost，这三个全会被抓。
    // 反过来若用 TOHOST 报完成，提前置起的 DONE 会让 TB 的等待循环当场退出，
    // 判据就变成看时序脸色了（第一版就是这么写的，反证时才发现）。
    //
    // 两笔 LED 写（先 5 后 2，两个都在 3 位内且不等）中间夹 32 次延时循环，让中间态 5 保持约 64 拍，
    // TB 每拍采样必抓到。lw 走 mmio_rdata 的读回路，值落到 DTCM[1] 供 PS 取回 ——
    // 那条多路选择分支不能只写不测。
    program3[0]  = 32'h0000_5537;  // lui  x10, 0x5      x10 = 0x5000 LED 基址
    program3[1]  = 32'h0050_0313;  // addi x6, x0, 5     pattern A = 0b0101
    program3[2]  = 32'h0065_2023;  // sw   x6, 0(x10)    LED = A
    program3[3]  = 32'h0200_0393;  // addi x7, x0, 32    延时计数
    program3[4]  = 32'hFFF3_8393;  // addi x7, x7, -1
    program3[5]  = 32'hFE03_9EE3;  // bne  x7, x0, -4    32 次循环，A 保持约 64 拍
    program3[6]  = 32'h0020_0313;  // addi x6, x0, 2     pattern B = 0b010
    program3[7]  = 32'h0065_2023;  // sw   x6, 0(x10)    LED = B
    program3[8]  = 32'h0005_2483;  // lw   x9, 0(x10)    回读 LED（走 mmio_rdata）
    program3[9]  = 32'h0090_2223;  // sw   x9, 4(x0)     DTCM[1] = 回读值，应为 2
    program3[10] = 32'h0010_0413;  // addi x8, x0, 1
    program3[11] = 32'h0080_2023;  // sw   x8, 0(x0)     DTCM[0] = 1，完成标志
    program3[12] = 32'h0000_006F;  // jal  x0, 0         原地自旋

    repeat (8) @(negedge clk);
    rst_n = 1'b1;

    // ── 1. 复位后核被 halt 挡住 ──────────────────────────────────────────
    axi_read(R_STATUS, rd_val);
    check32(rd_val[2], 32'd1, "STATUS.HALTED after reset");

    // ── 2. 软复位 ────────────────────────────────────────────────────────
    axi_write(R_CTRL, 32'h0000_0013, wr_resp);   // SOFT_RST | HALT
    check32(wr_resp, RESP_OKAY, "CTRL write response");
    axi_read(R_STATUS, rd_val);
    check32(rd_val[2], 32'd1, "STATUS.HALTED after soft reset");

    // ── 3. 下载固件进 ITCM（自增窗口） ───────────────────────────────────
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);  // RST_ADDR
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < 8; i = i + 1) begin
      axi_write(R_MEM_WDATA, program[i], wr_resp);
      check32(wr_resp, RESP_OKAY, "MEM_WDATA response while halted");
    end

    // 回读校验：自增地址归零后逐字读回
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < 8; i = i + 1) begin
      axi_read(R_MEM_RDATA, rd_val);
      check32(rd_val, program[i], "ITCM readback");
    end

    // ── 4. 传参 + 使能中断 ───────────────────────────────────────────────
    axi_write(R_FROMHOST, 32'h0000_1234, wr_resp);
    axi_write(R_IRQ_MASK, 32'h0000_0006, wr_resp);  // DONE + TOHOST

    // ── 5. 开一轮测量并放行 ──────────────────────────────────────────────
    axi_write(R_CTRL, 32'h0000_0003, wr_resp);      // START | HALT：清计数器
    axi_write(R_CTRL, 32'h0000_0000, wr_resp);      // HALT=0：核开始跑

    // ── 6. 反证一：核运行期间写 ITCM 必须被拒 ────────────────────────────
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    axi_write(R_MEM_WDATA, 32'hDEAD_BEEF, wr_resp);
    check32(wr_resp, RESP_SLVERR, "MEM_WDATA while running returns SLVERR");
    axi_read(R_STATUS, rd_val);
    check32(rd_val[4], 32'd1, "STATUS.ERR set after rejected write");
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, program[0], "ITCM unchanged by rejected write");

    // ── 7. 等固件跑完 ────────────────────────────────────────────────────
    timeout = 0;
    axi_read(R_STATUS, rd_val);
    while (!rd_val[1] && timeout < 500) begin
      axi_read(R_STATUS, rd_val);
      timeout = timeout + 1;
    end
    check32(rd_val[1], 32'd1, "STATUS.DONE reached");

    check32(irq, 32'd1, "irq_o asserted");
    axi_read(R_IRQ_STAT, rd_val);
    check32(rd_val[1], 32'd1, "IRQ_STAT.TOHOST set");
    axi_read(R_TOHOST, rd_val);
    check32(rd_val, 32'h0000_0001, "TOHOST value");
    axi_read(R_TOHOST_CNT, rd_val);
    check32(rd_val, 32'h0000_0001, "TOHOST_CNT == 1 (store did not re-execute)");

    // ── 8. 取结果：DTCM[0] == 100 + FROMHOST ─────────────────────────────
    axi_write(R_MEM_ADDR, SEL_DTCM, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'h0000_1298, "DTCM[0] == 100 + 0x1234");

    // ── 9. retire 与计数器 ───────────────────────────────────────────────
    axi_read(R_RETIRE_CNT, rd_val);
    check_at_least(rd_val, 8, "RETIRE_CNT >= 8");
    axi_read(R_RETIRE_PC, rd_val);
    check32(rd_val, 32'h0000_001C, "RETIRE_PC == 0x1C (jal)");
    axi_read(R_RETIRE_INS, rd_val);
    check32(rd_val, 32'h0000_006F, "RETIRE_INSTR == jal x0, 0");
    axi_read(R_TRAP_CNT, rd_val);
    check32(rd_val, 32'd0, "TRAP_CNT == 0");
    axi_read(R_RETIRE_INF, rd_val);
    check32(rd_val[8], 32'd1, "RETIRE_INFO.valid");
    check32(rd_val[3:0], 32'd0, "RETIRE_INFO.fault == 0");

    axi_read(R_CYC_TOTAL, rd_val);
    check_at_least(rd_val, 1, "CYC_TOTAL > 0");
    axi_read(R_CYC_BUSY, rd_val);
    check_at_least(rd_val, 1, "CYC_BUSY > 0 (core did run)");
    axi_read(R_CYC_IDLE, rd_val);
    check_at_least(rd_val, 1, "CYC_IDLE > 0 (core was held)");

    // ── 10. 反证二：halt 期间退休计数必须冻住 ────────────────────────────
    axi_write(R_CTRL, 32'h0000_0002, wr_resp);      // HALT=1
    repeat (4) @(posedge clk);
    axi_read(R_RETIRE_CNT, prev_cnt);
    repeat (20) @(posedge clk);
    axi_read(R_RETIRE_CNT, cur_cnt);
    check32(cur_cnt, prev_cnt, "RETIRE_CNT frozen while halted");

    // ── 11. 单步：每次 STEP 至多退休一条 ─────────────────────────────────
    // WB 的 valid 门控若漏掉，冻结在 MEM 的指令会每拍重复退休，一步就会涨好几条。
    for (steps = 0; steps < 8; steps = steps + 1) begin
      prev_cnt = cur_cnt;
      axi_write(R_CTRL, 32'h0000_0006, wr_resp);    // HALT=1 | STEP=1
      repeat (4) @(posedge clk);
      axi_read(R_RETIRE_CNT, cur_cnt);
      delta = cur_cnt - prev_cnt;
      if (delta > 1) begin
        $display("ERROR: step %0d retired %0d instructions, expected <= 1", steps, delta);
        errors = errors + 1;
      end
      if (delta < 0) begin
        $display("ERROR: step %0d made RETIRE_CNT go backwards", steps);
        errors = errors + 1;
      end
    end

    // 单步之后核仍在 halt，写 TCM 仍然放行。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h1, wr_resp);
    axi_write(R_MEM_WDATA, 32'h0000_5A5A, wr_resp);
    check32(wr_resp, RESP_OKAY, "MEM_WDATA allowed while halted");
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h1, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'h0000_5A5A, "DTCM[1] written by PS");

    // 深字探针：TCM 扩到 16KB 后，PS 的自增窗口必须能摸到 4095。
    // 这处不测的话，整个 TB 照样全绿 —— 别处最大只用到字 1，高位被截断根本暴露不出来，
    // 只有真板上灌超过 256 字固件时才会以"灌进去一半"的形式发作。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0FFF, wr_resp);
    axi_write(R_MEM_WDATA, 32'hC0DE_1234, wr_resp);
    check32(wr_resp, RESP_OKAY, "MEM_WDATA allowed at DTCM word 4095");
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0FFF, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'hC0DE_1234, "DTCM word 4095 reachable through the PS window");
    // 再验字 3000：能抓出"只剩低若干位有效"的中间态，比只测最高字更细。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0BB8, wr_resp);
    axi_write(R_MEM_WDATA, 32'hFEED_FACE, wr_resp);
    check32(wr_resp, RESP_OKAY, "MEM_WDATA allowed at DTCM word 3000");
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0BB8, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'hFEED_FACE, "DTCM word 3000 reachable through the PS window");

    // ── 12. 未映射地址回 SLVERR ──────────────────────────────────────────
    axi_write(12'h7FC, 32'h0, wr_resp);
    check32(wr_resp, RESP_SLVERR, "unmapped write returns SLVERR");

    // ── 13. 反证三：halt 期间冻结的 store 不许重复执行 ───────────────────
    // 换一段"自增计数器连写三个字"的固件（6 条里 3 条是 store），停住后靠上面的
    // 监视块数核侧写使能。halted_store_cycles 必须在整个停住期间保持 0。
    //
    // 落点要扫：halt 停在哪一拍、EX/MEM 里是哪条指令是固定的，只停一次可能正好停在
    // 不写存储器的指令上 —— 那样断言会空过，拆掉门控也照样绿。这里错开 16 个落点，
    // 让冻结位置扫过流水各级。
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < 6; i = i + 1) begin
      axi_write(R_MEM_WDATA, program2[i], wr_resp);
      check32(wr_resp, RESP_OKAY, "program2 download response");
    end
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < 6; i = i + 1) begin
      axi_read(R_MEM_RDATA, rd_val);
      check32(rd_val, program2[i], "program2 readback");
    end
    // 换程序必须软复位：不然 PC 还停在上一段固件的自旋处，根本跑不到新代码。
    axi_write(R_CTRL, 32'h0000_0012, wr_resp);      // SOFT_RST | HALT
    for (i = 0; i < 16; i = i + 1) begin
      axi_write(R_CTRL, 32'h0000_0000, wr_resp);      // HALT=0：放行
      repeat (37 + i) @(posedge clk);
      axi_write(R_CTRL, 32'h0000_0002, wr_resp);      // HALT=1：停住
      repeat (40) @(posedge clk);
    end
    // 断言前先确认观测真的有效：光看计数为 0 分不清"防护生效"和"压根没冻住 store"。
    // store_in_exmem_while_halted 为 0 就说明这一轮扫描没扫到，断言是空过的。
    check_at_least(halted_store_in_exmem, 1, "sweep did freeze a store in EX/MEM");
    check_at_least(running_store_cycles, 1, "core did execute stores while running");
    check32(halted_store_cycles, 32'd0, "no DTCM store while halted");

    // ── 14. LED：固件写核侧 MMIO 0x5000 驱动灯 ────────────────────────────
    // 这一段是"核控灯"的验收点：灯动 = 取指 → 译码 → 访存 → store 整条链路都通了。
    // 换程序必须先软复位（PC 还停在 program2 的自增循环里），顺带验软复位会清灯。
    axi_write(R_CTRL, 32'h0000_0012, wr_resp);      // SOFT_RST | HALT
    repeat (4) @(posedge clk);
    check32(led, 4'h0, "LED cleared by soft reset");

    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < 13; i = i + 1) begin
      axi_write(R_MEM_WDATA, program3[i], wr_resp);
      check32(wr_resp, RESP_OKAY, "program3 download response");
    end
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < 13; i = i + 1) begin
      axi_read(R_MEM_RDATA, rd_val);
      check32(rd_val, program3[i], "program3 readback");
    end

    // 清掉 DTCM[0]：它是完成标志，残留的旧值会让下面的等待循环立刻退出。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0, wr_resp);
    axi_write(R_MEM_WDATA, 32'h0000_0000, wr_resp);
    // 顺手反证 ITCM 不会被这一笔带写。写 DTCM 时 ps_write_i 是共用的，只有 ps_req_i
    // 带选块信息 —— ITCM 的 B 口若漏掉 req，这里 ITCM[0] 会跟着变成 0，核随即陷在
    // 非法指令上原地打转。这条断言就是抓着这个 bug 加上的。
    check32(u_dut.u_soc.u_itcm.memory[0], program3[0], "ITCM[0] untouched by a DTCM write");

    axi_write(R_IRQ_MASK, 32'h0000_0006, wr_resp);
    axi_write(R_CTRL, 32'h0000_0003, wr_resp);      // START | HALT：清计数器
    // START 只清计数器，清灯的是软复位 —— 两者别混。
    check32(led, 4'h0, "LED stays clear after START (only soft reset clears it)");
    led_seen_5 = 1'b0;                               // 从这里起算观测窗口
    axi_write(R_CTRL, 32'h0000_0000, wr_resp);      // HALT=0：放行

    // 等固件自己报完成：DTCM[0] = 1。这里刻意不用 DONE 同步 —— 本段要证明的正是
    // "点灯不会碰到邮箱"，拿 DONE 当同步信号就循环论证了。读 MEM_RDATA 会自增地址，
    // 所以每轮都要重设 MEM_ADDR。
    timeout = 0;
    rd_val  = 32'h0;
    while (rd_val !== 32'h1 && timeout < 500) begin
      axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0, wr_resp);
      axi_read(R_MEM_RDATA, rd_val);
      timeout = timeout + 1;
    end
    check32(rd_val, 32'h1, "program3 reached its completion flag in DTCM[0]");

    // 先证明观测有效，再断言终值：两笔 LED 写中间夹了 32 次延时循环，
    // 中间态 5 该保持约 64 拍。led_seen_5 为 0 说明这段固件压根没跑到中间态，
    // 后面那条终值断言就是空过的。
    check_at_least(led_seen_5, 1, "LED was observed holding pattern A");
    check32(led, 3'h2, "LED holds final pattern B");
    axi_read(R_LED_STATE, rd_val);
    check32(rd_val, 32'h0000_0002, "LED_STATE mirror == 0x2");

    // 反证 MMIO 的页限定。LED 在 0x5000 页、偏移 0；TOHOST 在 0x4000 页、偏移也是 0。
    // mmio_tohost 若只比偏移不带页，固件那两笔 LED 写会各命中一次 tohost ——
    // 计数、DONE、中断三个后果一起断言，只断一处有可能是巧合。
    axi_read(R_TOHOST_CNT, rd_val);
    check32(rd_val, 32'h0, "TOHOST_CNT == 0 (LED writes did not hit TOHOST)");
    axi_read(R_STATUS, rd_val);
    check32(rd_val[1], 32'd0, "STATUS.DONE still 0 (LED write != program done)");
    check32(irq, 32'd0, "irq_o still low after LED writes");

    // 固件那条 lw 走的是 mmio_rdata 的读回路，值落到 DTCM[1]，PS 从 TCM 窗口取回。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h1, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'h0000_0002, "DTCM[1] == firmware readback of LED");

    // ── 15. 阵列系数预装窗口（AXI 0x0C0–0x0CC）───────────────────────────
    // 这一段是第四版"阵列真的能用起来"的验收点：PS 经 AXI 把 ŝ 装进阵列的系数
    // bank，再由**核里的 OP-V 指令**把它读出来算一次归约，结果经 DTCM 回到 PS。
    // 中间穿过 ps_regs → soc → core → vec_unit 四层，任何一层接错都到不了终点。
    // 和 tb_vec_core 的分工：那个验阵列算得对不对，这个验"PS 能不能碰得到它"。

    // 反证一：核还在跑（第 14 段放行之后没停过），此时写系数必须被拒。
    // 阵列的系数读口只有一条，读写都会借它 —— 所以读也一并拒，和 TCM 那条
    // "读不设限"不一样。
    axi_write(R_COEF_ADDR, 32'h0000_0000, wr_resp);
    axi_write(R_COEF_WDATA, 32'h0000_7FFF, wr_resp);
    check32({30'b0, wr_resp}, RESP_SLVERR, "coefficient write rejected while the core runs");
    axi_read(R_COEF_CTRL, rd_val);
    check32(rd_val[1], 32'd1, "COEF_CTRL.ERR sticky after a rejected write");
    check32(rd_val[2], 32'd1, "COEF_CTRL.LOCKED reports the core is running");
    // 被拒的写不自增地址：PS 停住核之后能从同一个抽头重来。
    axi_read(R_COEF_ADDR, rd_val);
    check32({23'b0, rd_val[8:0]}, 32'd0, "rejected write must not advance the tap index");

    // 停住核，清错误位，正式预装。
    axi_write(R_CTRL, 32'h0000_0003, wr_resp);       // START | HALT
    axi_write(R_COEF_CTRL, 32'h0000_0002, wr_resp);  // ERR(W1C)
    axi_read(R_COEF_CTRL, rd_val);
    check32(rd_val[1], 32'd0, "COEF_CTRL.ERR cleared by W1C");
    check32(rd_val[2], 32'd0, "COEF_CTRL.LOCKED clear once halted");

    // 16 个抽头一次装完（写自增），覆盖 bank 0..7 的 word 0 **和** word 1。
    axi_write(R_COEF_ADDR, {21'b0, 1'b0, 1'b1, 9'd0}, wr_resp);  // ch=0 src=ŝ idx=0
    for (i = 0; i < 16; i = i + 1) begin
      axi_write(R_COEF_WDATA, {16'b0, coef_s[i]}, wr_resp);
      check32({30'b0, wr_resp}, RESP_OKAY, "coefficient write accepted while halted");
    end
    axi_read(R_COEF_ADDR, rd_val);
    check32({23'b0, rd_val[8:0]}, 32'd16, "tap index auto-incremented to 16 after 16 writes");

    // 回读：PS 不跑核也能确认装进去了。读也自增，所以从抽头 0 重来一遍。
    axi_write(R_COEF_ADDR, {21'b0, 1'b0, 1'b1, 9'd0}, wr_resp);
    for (i = 0; i < 16; i = i + 1) begin
      axi_read(R_COEF_RDATA, rd_val);
      case (i)
        0:  check32({16'b0, rd_val[15:0]}, 32'h0000_4000, "readback s[0] = 0.5");
        1:  check32({16'b0, rd_val[15:0]}, 32'h0000_2000, "readback s[1] = 0.25 (auto-increment)");
        7:  check32({16'b0, rd_val[15:0]}, 32'h0000_1000, "readback s[7] = 0.125 (bank 7)");
        8:  check32({16'b0, rd_val[15:0]}, 32'h0000_0800, "readback s[8] = 0.0625 (bank 0, word 1)");
        default: check32({16'b0, rd_val[15:0]}, 32'h0000_0000, "readback of the zero taps");
      endcase
    end

    // ── 15b. 端到端：装好的 ŝ 由核里的 vred 读出来 ────────────────────────
    // 软复位会清空阵列里的延迟线指针，也让 PC 回到 0，从干净状态起跑。
    axi_write(R_CTRL, 32'h0000_0012, wr_resp);       // SOFT_RST | HALT
    repeat (4) @(posedge clk);
    axi_write(R_MEM_CTRL, 32'h0000_0001, wr_resp);
    axi_write(R_MEM_ADDR, SEL_ITCM, wr_resp);
    for (i = 0; i < N_PROG4; i = i + 1) begin
      axi_write(R_MEM_WDATA, program4[i], wr_resp);
      check32({30'b0, wr_resp}, RESP_OKAY, "program4 download response");
    end
    // 清完成标志，否则下面等的是上一段的残留。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0, wr_resp);
    axi_write(R_MEM_WDATA, 32'h0000_0000, wr_resp);
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h1, wr_resp);
    axi_write(R_MEM_WDATA, 32'h0000_0000, wr_resp);

    axi_write(R_CTRL, 32'h0000_0003, wr_resp);       // START | HALT：清计数器
    axi_write(R_CTRL, 32'h0000_0000, wr_resp);       // HALT=0：放行

    timeout = 0;
    rd_val  = 32'h0;
    while (rd_val !== 32'h1 && timeout < 500) begin
      axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0, wr_resp);
      axi_read(R_MEM_RDATA, rd_val);
      timeout = timeout + 1;
    end
    check32(rd_val, 32'h1, "program4 reached its completion flag");

    // 结果必须与 PS 装进去的那组系数严格对上。核里算错、装错 bank、通道选错，
    // 这个数都会变。
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h1, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'd43827200, "two-pass vred over the PS-loaded s == 43827200");
    axi_write(R_MEM_ADDR, SEL_DTCM | 32'h0, wr_resp);
    axi_read(R_MEM_RDATA, rd_val);
    check32(rd_val, 32'h1, "program4 took no trap on the way");

    axi_read(12'h048, rd_val);
    check_at_least(rd_val, 1, "CYC_SIMD counts actual OP-V occupancy");

    if (errors == 0) begin
      $display("PASS: Zynq PS-PL AXI interface test (%0d cycles)", cycle_count);
    end else begin
      $display("FAIL: %0d error(s) after %0d cycles", errors, cycle_count);
    end
    $finish;
  end

  initial begin
    $dumpfile("build/rv32_ps.vcd");
    $dumpvars(0, tb_rv32_ps);
  end

endmodule
