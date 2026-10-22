// PL 侧固件在真核上的冒烟测试 —— 证明 sw/fw/ 的 C 构建流端到端可用。
//
// 验的是**四件事**，缺一件构建流就不算通：
//   1. 固件真的从 ITCM 取指跑起来了（不是 PC 卡在 0）；
//   2. 启动代码把 .bss 清了（g_x/g_h 是 .bss，清不干净结果就是垃圾）；
//   3. 标量内核的结果与 TB 端**独立复算**的期望值一致；
//   4. cycle 计数器在动 —— 后面所有加速比都靠它。
//
// 期望值由 TB 自己按定义算，不引用固件里的任何常量：
//   g_x[i] = i+1 (i=0..63), g_h[i] = 4096
//   点积   Σ (i+1)·4096            = 4096·2080      = 8519680
//   FIR    (Σ h·x) >> 15           = 8519680/32768  = 260
//   能量   Σ (i+1)²                = 89440
`timescale 1ns/1ps

module tb_fw_smoke;

  // 固件现在含 FFT 内核（约 18.4 万拍/次，跑 3 次），整轮 ≈ 75 万拍。
  // 这个上限只留够余量即可 —— 卡死时靠它兜底，不靠它计时。
  localparam integer MAXC   = 4200000;
  localparam integer RESW   = 32'h2800 >> 2;   // 结果块在 DTCM 的字号
  localparam integer NTAP   = 64;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg rst_n = 1'b0;

  wire        retire_valid;
  wire [31:0] retire_pc, retire_instr;
  wire [3:0]  retire_fault;

  // ⚠ 两份都要装：只装 ITCM 的话代码照跑，但 .rodata / .data 初值读出来是 X。
  rv32_soc #(
    .DAS_ACTIVE_CHANNELS(8),
    .ITCM_FILE ("sw/fw/fw_itcm.hex"),
    .DTCM_FILE ("sw/fw/fw_dtcm.hex")
  ) u_dut (
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

  integer errors = 0;
  integer cyc    = 0;
  integer i;
  integer exp_dot, exp_fir, exp_eng;
  integer got_dot, got_fir, got_eng, got_mark, got_ntap;
  integer c_dot, c_fir, c_eng;
  integer retires;
  integer seen_nonzero_pc;

  // ── 握手计数器（docs/issues/030）────────────────────────────────────
  // 直接量「DTCM 收到多少笔写请求」vs「真正落地多少笔」。
  // 两者不等 = 握手丢写，与地址无关。
  integer n_req_rise;      // dtcm_req 的上升沿数（发出多少笔）
  integer n_write;         // dmem_write 的拍数（接受多少笔）
  integer n_res_hits;      // 写进结果块 0x3000–0x303F 的笔数
  reg     req_d;
  reg     wr_d;

  // 逐拍时序抓取：结果块被访问的每一拍都记下来。
  // 关键看「核有没有在 rdy=1 且 wr=1 的那一拍把写递过去」——
  // 若某笔 store 出现 req=1/rdy=1 却没产生 wr=1，或地址在核推进后变了，
  // 就当场看见。
  integer trace_n;
  reg     trace_on;
  integer n_fault;         // 退休时带异常的指令数
  integer n_stall;         // memory_stall 拍数

  always @(posedge clk) begin
    if (rst_n) begin
      if (retire_valid && (retire_fault != 4'b0)) n_fault <= n_fault + 1;
      if (u_dut.dmem_req && !u_dut.dmem_ready) n_stall <= n_stall + 1;
    end
  end

  always @(posedge clk) begin
    // 只在**最后阶段**抓（前 121000 拍是内核循环，噪声太大），
    // 而且**不过滤地址** —— 要看清那笔 store 到底是"没发"还是"发到别处去了"。
    // 之前带地址过滤，等于把"发到别处"这种可能直接排除掉了。
    if (rst_n && trace_on && u_dut.dtcm_req && (cyc > 121300)) begin
      if (trace_n < 400) begin
        $display("  T c=%0d addr=%04x req=%b rdy=%b wr=%b wd=%08x",
                 cyc, u_dut.dmem_addr[15:0], u_dut.dtcm_req,
                 u_dut.dmem_ready, u_dut.dmem_write, u_dut.dmem_wdata);
        trace_n <= trace_n + 1;
      end
    end
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      n_req_rise <= 0;
      n_write    <= 0;
      n_res_hits <= 0;
      req_d      <= 1'b0;
      wr_d       <= 1'b0;
    end else begin
      req_d <= u_dut.dtcm_req;
      wr_d  <= u_dut.dmem_write;
      if (u_dut.dtcm_req & ~req_d) n_req_rise <= n_req_rise + 1;
      if (u_dut.dmem_write & ~wr_d) n_write <= n_write + 1;
      if (u_dut.dmem_write & (u_dut.dmem_addr >= 32'h3000) &&
          (u_dut.dmem_addr < 32'h3040)) begin
        n_res_hits <= n_res_hits + 1;
      end
    end
  end

  task check;
    input            cond;
    input [8*96-1:0] msg;
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s", msg);
      end
    end
  endtask

  // 结果块里第 k 个字
  function [31:0] res;
    input integer k;
    begin
      res = u_dut.u_dtcm.memory[RESW + k];
    end
  endfunction

  initial begin
    trace_n  = 0;
    trace_on = 1'b0;
    n_fault  = 0;
    n_stall  = 0;
    // 期望值按定义独立算，不抄固件里的常量
    exp_dot = 0; exp_eng = 0;
    for (i = 0; i < NTAP; i = i + 1) begin
      exp_dot = exp_dot + (i + 1) * 4096;
      exp_eng = exp_eng + (i + 1) * (i + 1);
    end
    exp_fir = exp_dot >> 15;

    $display("=== tb_fw_smoke ===");
    $display("   TB 端独立算出的期望: dot=%0d  fir=%0d  energy=%0d",
             exp_dot, exp_fir, exp_eng);

    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
    trace_on = 1'b1;

    // ── 跑到固件打完成标记，或超时 ──────────────────────────────────
    retires = 0;
    seen_nonzero_pc = 0;
    while ((res(15) !== 32'hC0DE0001) && (cyc < MAXC)) begin
      @(posedge clk);
      cyc = cyc + 1;
      if (retire_valid) begin
        retires = retires + 1;
        if (retire_pc != 32'b0) seen_nonzero_pc = 1;
      end
    end

    // 等到 marker 之后再多等几拍：marker 之后的 store 还没落地就退出会读到 x。
    // 转储原始 hex —— 只打印十进制的话 x 会伪装成"某个值"。
    repeat (600) @(posedge clk);   // marker 之后还有多笔 store 要落地，8 拍远远不够

    $display("  %0d 拍，退休 %0d 条指令", cyc, retires);
    $display("   握手计数: dtcm_req 上升沿 = %0d", n_req_rise);
    $display("             dmem_write 拍数 = %0d", n_write);
    $display("             结果块(0x3000-0x303F) 写入笔数 = %0d  (探针 16 + 最终 14 = 30 期望)",
             n_res_hits);
    $display("   异常=%0d  stall=%0d", n_fault, n_stall);
    $display("   结果块原始值:");
    for (i = 0; i < 16; i = i + 1) begin
      $display("     RES(%0d) = %08x", i, res(i));
    end

    // ── 1. 真跑起来了 ───────────────────────────────────────────────
    check(cyc < MAXC, "firmware must finish inside MAXC cycles");
    check(retires > 200, "core must retire a meaningful number of instructions");
    check(seen_nonzero_pc == 1, "PC must advance past 0 (firmware really executed)");

    // ── 2/3. 结果 ───────────────────────────────────────────────────
    got_dot  = res(0);
    got_fir  = res(2);
    got_eng  = res(4);
    got_mark = res(15);
    got_ntap = res(7);
    c_dot    = res(1);
    c_fir    = res(3);
    c_eng    = res(5);

    $display("   dot    = %0d  (期望 %0d)", got_dot, exp_dot);
    $display("   fir    = %0d  (期望 %0d)", got_fir, exp_fir);
    $display("   energy = %0d  (期望 %0d)", got_eng, exp_eng);
    $display("   NTAP   = %0d  (期望 %0d)", got_ntap, NTAP);

    check(got_mark == 32'hC0DE0001, "firmware must set the done marker");
    check(got_dot == exp_dot,  "dot product must match");
    check(got_fir == exp_fir,  "FIR output must match");
    check(got_eng == exp_eng,  "energy must match");
    check(got_ntap == NTAP,    ".bss must hold the written values (startup cleared it)");

    // ── 4. cycle 计数器 ─────────────────────────────────────────────
    $display("   cycles: dot=%0d (64 次)  fir=%0d  energy=%0d",
             c_dot, c_fir, c_eng);
    check(c_dot > 0 && c_fir > 0 && c_eng > 0,
          "cycle counter must advance -- every later speedup number depends on it");
    $display("   --- 标量基线 cycles/次 (NTAP=%0d) ---", NTAP);
    $display("       点积   %0.1f", c_dot * 1.0 / 64.0);
    $display("       FIR    %0.1f", c_fir * 1.0 / 64.0);
    $display("       能量   %0.1f", c_eng * 1.0 / 64.0);

    if (errors == 0) begin
      $display("PASS: RV32 固件构建流可用，标量基线已量出");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #(MAXC * 12);
    $display("FAIL: TB timed out after %0d cycles", cyc);
    $finish;
  end

endmodule
