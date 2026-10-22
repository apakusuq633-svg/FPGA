// 定位加速器**门铃指令**（custom-1，opcode 0x2B）的核级验收。
//
// 这是"在核上跑专用指令"那一条主张的直接证据。四段：
//
//   1. **合法且发起**：程序里发两条门铃（funct3=0 → SRP，funct3=1 → XSPEC），
//      断言 retire 里**没有故障**、两个块**真的被驱动到完成**（各自 done_q 置位）。
//      （funct3=2 是第三个门铃目标，波束转向块 rv32_steer_regs，本 TB 不覆盖。）
//   2. **恰好一拍**：数 srp_start_o / xsp_start_o 的脉冲数，必须**正好等于**门铃
//      条数（2 条指令各 1 个脉冲）。多一个说明去抖门控没做（idex_valid 是电平，
//      不用 ex_stage_valid & ~halt_i 门控就会每拍触发一次）。
//   3. **不 stall**：跑两段**只差两条门铃**的程序，量"到写邮箱"的拍数。
//      差值应当是 +2（就是那两条指令本身），**不是 +5000**（SRP 一趟是 5×4×256）。
//      这是"门铃不在关键路径上"唯一能直接量到的判据 —— 也是选 fire-and-forget
//      而不是 stall 的全部理由。
//   4. **保留编码走 trap**：funct3=3 保持非法。断言 faults>0 且邮箱**没被写**
//      （mtvec 默认 0 ⇒ 陷入后回到 0 再撞一次，程序永远走不到末尾）。
//      —— 若它被译成"什么都不做"，就会静默跑过去，这一段的判据就死了。
`timescale 1ns/1ps

module tb_loc_core;

  reg clk = 1'b0;
  always #12.5 clk = ~clk;

  reg rst_n = 1'b0;

  wire        retire_valid;
  wire [31:0] retire_pc, retire_instr;
  wire [3:0]  retire_fault;
  wire [31:0] tohost;
  wire        tohost_we;

  rv32_soc #(
    .DAS_ACTIVE_CHANNELS(8),
    .RESET_PC (32'h0000_0000)
  ) u_dut (
    .clk_i          (clk),
    .rst_n_i        (rst_n),
    .test_en_i      (1'b0),
    .halt_i         (1'b0),
    .retire_valid_o (retire_valid),
    .retire_pc_o    (retire_pc),
    .retire_instr_o (retire_instr),
    .retire_fault_o (retire_fault),
    .tohost_o       (tohost),
    .tohost_we_o    (tohost_we),
    .fromhost_i     (32'd0),
    .led_o          (),
    .ps_req_i       (1'b0),
    .ps_write_i     (1'b0),
    .ps_sel_i       (1'b0),
    .ps_addr_i      (32'd0),
    .ps_wdata_i     (32'd0),
    .ps_ready_o     (),
    .ps_rdata_o     (),
    
    .simd_active_o  (),
    
    .coef_we_i      (1'b0),
    .coef_re_i      (1'b0),
    .coef_src_i     (1'b0),
    .coef_ch_i      (1'b0),
    .coef_idx_i     (9'd0),
    .coef_wdata_i   (16'd0),
    .coef_rdata_o   (),
    
    .tacho_i        (1'b0),
    .pdm_clk_o      (),
    .pdm_din_i      (8'd0),
    .pdm_cfg_wr_i   (1'b0),
    .pdm_cfg_rd_i   (1'b0),
    .pdm_cfg_addr_i (7'd0),
    .pdm_cfg_wdata_i(32'd0),
    .pdm_cfg_rdata_o(),
    .srp_cfg_wr_i   (1'b0),
    .srp_cfg_rd_i   (1'b0),
    .srp_cfg_addr_i (7'd0),
    .srp_cfg_wdata_i(32'd0),
    .srp_cfg_rdata_o(),
    .xsp_cfg_wr_i   (1'b0),
    .xsp_cfg_rd_i   (1'b0),
    .xsp_cfg_addr_i (7'd0),
    .xsp_cfg_wdata_i(32'd0),
    .xsp_cfg_rdata_o(),
    .steer_cfg_wr_i (1'b0),
    .steer_cfg_rd_i (1'b0),
    .steer_cfg_addr_i (7'b0),
    .steer_cfg_wdata_i(32'b0),
    .steer_cfg_rdata_o()
  );

  integer errors  = 0;
  integer faults  = 0;
  integer srp_pul = 0;
  integer xsp_pul = 0;
  integer cyc     = 0;
  integer cyc_a   = 0, cyc_b = 0, cyc_c = 0;
  // ⚠ tohost_we 是**单拍脉冲**：等程序停下来再去查它，看到的永远是 0。
  //   必须当场锁存 —— 第一版就是这么把自己骗了一次（邮箱没写其实是写了）。
  integer mail_seen = 0;

  // 全程的观测器：故障退休、门铃脉冲数、拍数
  always @(posedge clk) begin
    if (rst_n) begin
      cyc <= cyc + 1;
      if (retire_valid && (retire_fault != 4'd0)) faults <= faults + 1;
      if (tohost_we === 1'b1) mail_seen <= 1;
      if (u_dut.u_core.srp_start_o) srp_pul <= srp_pul + 1;
      if (u_dut.u_core.xsp_start_o) xsp_pul <= xsp_pul + 1;
    end
  end

  task check;
    input            cond;
    input [8*88-1:0] msg;
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s  (t=%0t)", msg, $time);
      end
    end
  endtask

  integer i, j;

  // ⚠ 清 ITCM 与"跑"必须分成两步：合在一个任务里的话，清空会把调用方
  //   刚刚装好的程序擦成 nop（程序是要在复位前写进 memory 的）。
  task clr_itcm;
    begin
      for (j = 0; j < 4096; j = j + 1) u_dut.u_itcm.memory[j] = 32'h0000_0013;  // nop
    end
  endtask

  // 复位 → 放开 → 等到写邮箱，返回经过的拍数（超时回 -1）
  task run_prog;
    output integer used;
    begin
      used = -1;
      rst_n = 1'b0;
      repeat (6) @(posedge clk);
      cyc = 0;
      rst_n = 1'b1;
      i = 0;
      while ((tohost_we !== 1'b1) && (i < 20000)) begin
        @(posedge clk); i = i + 1;
      end
      if (tohost_we === 1'b1) used = cyc;
      @(posedge clk);
    end
  endtask

  // ── 程序 A：**没有**门铃（基线）────────────────────────────────────────
  task load_prog_a;
    begin
      clr_itcm;
      u_dut.u_itcm.memory[0] = 32'h000042B7; // lui  x5, 4        x5 = 0x4000（邮箱）
      u_dut.u_itcm.memory[1] = 32'h00100313; // addi x6, x0, 1
      u_dut.u_itcm.memory[2] = 32'h0062A023; // sw   x6, 0(x5)    写 tohost
      u_dut.u_itcm.memory[3] = 32'h0000006F; // jal  x0, 0        自旋
    end
  endtask

  // ── 程序 B：**多两条门铃**，其余逐条相同 ───────────────────────────────
  task load_prog_b;
    begin
      clr_itcm;
      u_dut.u_itcm.memory[0] = 32'h000042B7; // lui  x5, 4
      u_dut.u_itcm.memory[1] = 32'h0000002B; // .insn r 0x2B,0,0,x0,x0,x0  门铃 → SRP
      u_dut.u_itcm.memory[2] = 32'h0000102B; // .insn r 0x2B,1,0,x0,x0,x0  门铃 → XSPEC
      u_dut.u_itcm.memory[3] = 32'h00100313; // addi x6, x0, 1
      u_dut.u_itcm.memory[4] = 32'h0062A023; // sw   x6, 0(x5)
      u_dut.u_itcm.memory[5] = 32'h0000006F; // jal  x0, 0
    end
  endtask

  // ── 程序 C：保留编码 funct3=3，必须走 trap ─────────────────────────────
  // ⚠ 2026-10-06：这里原来是 funct3=2。波束转向块（rv32_steer_regs）把
  //   funct3=2 占成了第三个门铃目标，所以"保留编码"往后挪到 3。
  //   判据本身没变：门铃只放 000/001/010，其余必须走 trap。
  task load_prog_c;
    begin
      clr_itcm;
      u_dut.u_itcm.memory[0] = 32'h000042B7; // lui  x5, 4
      u_dut.u_itcm.memory[1] = 32'h0000302B; // .insn r 0x2B,3,0,x0,x0,x0  保留值
      u_dut.u_itcm.memory[2] = 32'h00100313; // addi x6, x0, 1
      u_dut.u_itcm.memory[3] = 32'h0062A023; // sw   x6, 0(x5)
      u_dut.u_itcm.memory[4] = 32'h0000006F; // jal  x0, 0
    end
  endtask

  initial begin
    $display("=== tb_loc_core: custom-1 doorbell (opcode 0x2B) ===");

    // ── 段 1+2：程序 B，数脉冲、看块有没有真的跑完 ─────────────────────
    $display("[1] program B: two doorbells -> blocks must actually run");
    mail_seen = 0;
    load_prog_b;
    run_prog(cyc_b);
    $display("     mail written == %0d, faults = %0d, srp pulses = %0d, xsp pulses = %0d",
             mail_seen, faults, srp_pul, xsp_pul);
    check(mail_seen == 1, "program must reach the mailbox (doorbell must not hang the core)");
    check(faults == 0,        "the custom-1 instruction must be legal (no retire fault)");
    check(srp_pul == 1,       "SRP doorbell must fire EXACTLY once");
    check(xsp_pul == 1,       "XSPEC doorbell must fire EXACTLY once");
    // ⚠ 程序第 9 拍就把邮箱写了，而 SRP 一趟是 5×4×256 = 5120 拍 ——
    //   必须在**这里**等它跑完再查 done_q，否则量到的是"刚发起"那一刻。
    repeat (8000) @(posedge clk);
    check(u_dut.u_srp.done_q === 1'b1, "the SRP block must have been driven to completion");
    check(u_dut.u_xsp.done_q === 1'b1, "the XSPEC block must have been driven to completion");
    // 顺便量一下 RUN_CYCLES 有没有落下来（SRP 一趟 = 5 拍/(对,格)）
    $display("     srp RUN_CYCLES = %0d (expect 5*4*256 = %0d)",
             u_dut.u_srp.run_cyc_q, 5*4*256);

    // ── 段 3：程序 A 做基线，比拍数证明**不 stall** ────────────────────
    $display("[3] program A: same code without the two doorbells (baseline)");
    load_prog_a;
    run_prog(cyc_a);
    $display("     cycles: baseline %0d, with doorbells %0d, delta = %0d",
             cyc_a, cyc_b, cyc_b - cyc_a);
    check(mail_seen == 1, "baseline program must also reach the mailbox");
    // 两条指令 = +2 拍。给到 +8 的余量；若门铃 stall 到扫描完成，差值会是 +5000 以上。
    check((cyc_b - cyc_a) <= 8,
          "the doorbell must NOT stall: delta must be a couple of cycles, not thousands");

    // ── 段 4：保留编码必须 trap ────────────────────────────────────────
    $display("[4] program C: reserved funct3=3 must trap");
    faults = 0; mail_seen = 0;
    load_prog_c;
    run_prog(cyc_c);
    $display("     faults = %0d, mail written == %0d (expect faults>0 and mail NOT written)",
             faults, mail_seen);
    check(faults > 0,     "reserved funct3=3 must raise an illegal-instruction trap");
    check(mail_seen == 0, "the trapping program must never reach the mailbox");

    repeat (20) @(posedge clk);
    if (errors == 0) begin
      $display("PASS: loc_core doorbell -- fired once, no stall, reserved encoding traps");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #50_000_000;
    $display("FAIL: TB timed out");
    $finish;
  end

endmodule
