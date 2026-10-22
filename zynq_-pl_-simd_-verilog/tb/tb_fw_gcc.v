// 固件 GCC-PHAT 内核的验证 —— 一对麦克风的 TDOA 跑在真核上。
//
// 对着**两条独立参照**比：
//   1. scripts/golden/fw_gcc_model.py 的定点参照（build/fw_gcc_ref.hex）—— 逐位
//   2. TB 自己造的两路信号有**已知时延**（B 比 A 超前 7 个样点），峰值必须落 +7
//      —— 不依赖任何生成物
//
// 第 2 条是核心：定点模型和固件可能一起错（同一个标度、同一个下标约定），
// 但「已知时延能不能测出来」不认生成物，只认物理事实。
//
// ⚠ 固件里 R 落在**固定输出区 2**（DTCM 0x3080），不是 0x2400（那里是 FFT 的
//   输出）。两个内核在同一轮固件里都跑，一份输出区留不住两份结果。
`timescale 1ns/1ps

module tb_fw_gcc;

  localparam integer MAXC  = 14000000;  // 固件整轮 1119 万拍（FFT+GCC+SRP+DAS+GSC）
  localparam integer N     = 1024;
  localparam integer RESW  = 32'h2800 >> 2;   // 结果块
  localparam integer OUTW  = 32'h2400 >> 2;   // 批量输出区 1（FFT）
  localparam integer OUT2W = 32'h30C0 >> 2;   // 批量输出区 2（GCC-PHAT 的 R）

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;

  // ══ 转向 LUT 预装（甲：只补 TB）══════════════════════════════════════════
  // ⚠⚠ **不能省。** rv32_steer.v 的 lut_mem 故意没有复位/初值（为推断成 BRAM，
  //   文件头明说踩过两次 issues/060、080），而**生产路径上没有任何地方装它**：
  //   fw_steer.c 没有 S_WDATA 宏、ps_main.c 只清 GSC 的系数 bank、SoC 级 TB 与
  //   gen_synth_top.tcl 全把 steer_cfg_* 接 0。唯一装表的是专用块 TB
  //   tb_steer.v / tb_steer_regs.v。
  //   不装的后果（实测，非推测）：§9 读回 X ⇒ fw_steer_query 在 0x2108 拿 X 做
  //   分支 ⇒ rv32_fetch_stage.v:48 的 `pc_d = redirect_i ? ... : ...` 按位 X 合并
  //   ⇒ PC 变 X ⇒ 取指字 X ⇒ 所有流水线使能 X ⇒ Verilog 里 if(X) 判假 ⇒
  //   **整核冻结，零退休**。五个固件 TB 都恰好停在 7782978 条退休。
  //   这里经 PS 窗口（steer_cfg_* → 壳的 ps_* 口）灌，与真机上 PS 在放核前预装
  //   是同一条路径 —— 将来 ps_main.c 补 load_steer_lut() 就是这份时序。
  reg        ps_wr = 1'b0, ps_rd = 1'b0;
  reg [6:0]  ps_addr  = 7'd0;
  reg [31:0] ps_wdata = 32'd0;
  integer    lut_img [0:2047];
  integer    lut_n = 0;

  task wr_reg; input [6:0] a; input [31:0] d;
    begin
      @(posedge clk);
      ps_addr = a; ps_wdata = d; ps_wr = 1'b1;
      @(posedge clk);
      ps_wr = 1'b0;
    end
  endtask

  task load_steer_lut;
    begin
      $readmemh("build/steer_lut.hex", lut_img);
      wr_reg(7'h00, 32'h0000_0002);   // CTRL: EN=1（**不** START，别触发更新）
      wr_reg(7'h02, 32'h0000_0000);   // ADDR: SEL=0(LUT), IDX=0
      for (lut_n = 0; lut_n < 2048; lut_n = lut_n + 1)
        wr_reg(7'h03, {18'd0, lut_img[lut_n][13:0] & 14'h3FFF});  // WDATA，IDX 自增
    end
  endtask
  // ════════════════════════════════════════════════════════════════════════
  wire        retire_valid;
  wire [31:0] retire_pc, retire_instr;
  wire [3:0]  retire_fault;

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
    
    .steer_cfg_wr_i   (ps_wr),
    .steer_cfg_rd_i   (ps_rd),
    .steer_cfg_addr_i  (ps_addr),
    .steer_cfg_wdata_i (ps_wdata),
    .steer_cfg_rdata_o  (),
    
    .tacho_i         (1'b0)
  );

  integer errors = 0;
  integer cyc    = 0;
  integer i, n, retires, n_mismatch, first_bad;
  integer peak_k, peak_v, absv;
  integer lag_scan, lag_fw;
  reg [15:0] ref [0:N-1];
  reg signed [15:0] rv;

  // ── 阵列系数 bank 清零 ────────────────────────────────────────────────
  // ⚠⚠ **不能省。** 那块 BRAM 没有复位（`RAM contents survive reset`，为了推断成
  //   BRAM），而固件**够不着** `coef_*` 端口（SoC 顶层、PS 侧驱动）⇒ 只能由 TB
  //   用层次引用捅。不捅的话读到的是 **X**：加法树整条变 X，x 再进到循环控制里，
  //   表现不是"算错了"而是**固件不结束**。实测（2026-10-06）：不做这个 poke 时本
  //   TB 卡在 1400 万拍、退休 6471367 条指令 —— 与 tb_fw_gsc 之外的所有固件 TB
  //   一字不差；做了就正常跑完。产品路径上这件事由 PS 侧的 zero_coef_bank() 做
  //   （见 docs/gsc_vec_design.md），TB 这里只是复现同一段上电序列。
  //   VS_NTAP=120 ⇒ 每 bank 15 个字（word 0..14），8 个 bank 全要。
  //   `generate` 块的层次下标必须是常量 ⇒ 展开成 case（变量下标 iverilog 直接报错）。
  integer pk_bank, pk_word;
  task poke_zero; input integer bank; input integer word;
    begin
      case (bank)
        0: u_dut.u_core.u_vec_unit.g_lane[0].u_cbank.mem_q[word] = 24'h000000;
        1: u_dut.u_core.u_vec_unit.g_lane[1].u_cbank.mem_q[word] = 24'h000000;
        2: u_dut.u_core.u_vec_unit.g_lane[2].u_cbank.mem_q[word] = 24'h000000;
        3: u_dut.u_core.u_vec_unit.g_lane[3].u_cbank.mem_q[word] = 24'h000000;
        4: u_dut.u_core.u_vec_unit.g_lane[4].u_cbank.mem_q[word] = 24'h000000;
        5: u_dut.u_core.u_vec_unit.g_lane[5].u_cbank.mem_q[word] = 24'h000000;
        6: u_dut.u_core.u_vec_unit.g_lane[6].u_cbank.mem_q[word] = 24'h000000;
        7: u_dut.u_core.u_vec_unit.g_lane[7].u_cbank.mem_q[word] = 24'h000000;
        default: ;
      endcase
    end
  endtask

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

  function [31:0] res;
    input integer k;
    begin
      res = u_dut.u_dtcm.memory[RESW + k];
    end
  endfunction

  // DTCM 里第 k 个字，取低半（int16）
  function signed [15:0] r_at;
    input integer k;
    reg [31:0] w;
    begin
      w = u_dut.u_dtcm.memory[OUT2W + (k >> 1)];
      r_at = (k[0] == 1'b0) ? w[15:0] : w[31:16];
    end
  endfunction

  initial begin
    $display("=== tb_fw_gcc ===");
    $readmemh("build/fw_gcc_ref.hex", ref);

    // 阵列系数 bank 清零（必须在固件跑到 GSC 那一级之前做完）—— 见 poke_zero 的注释
    for (pk_bank = 0; pk_bank < 8; pk_bank = pk_bank + 1)
      for (pk_word = 0; pk_word < 15; pk_word = pk_word + 1) poke_zero(pk_bank, pk_word);

    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;

    load_steer_lut();   // 放核之前预装转向几何 LUT，见文件头 load_steer_lut 的注释
    retires = 0;
    while ((res(15) !== 32'hC0DE0001) && (cyc < MAXC)) begin
      @(posedge clk);
      cyc = cyc + 1;
      if (retire_valid) retires = retires + 1;
    end
    repeat (600) @(posedge clk);      // 标记之后的 store 还要落地

    $display("  %0d 拍，退休 %0d 条指令", cyc, retires);
    check(cyc < MAXC, "firmware must finish inside MAXC cycles");
    check(res(15) === 32'hC0DE0001, "firmware must set the done marker");

    // ── 参照 2：TB 自己扫相关序列的峰（不依赖生成物）─────────────────
    // ⚠ 取绝对值再比，别写成「正数比大小、负数另算」的复合条件 ——
    //   那个写法在 0 附近会挑错，而且看着还挺像对的。
    peak_v = -1;  peak_k = 0;  absv = 0;
    for (n = 0; n < N; n = n + 1) begin
      rv   = r_at(n);
      absv = (rv >= 0) ? rv : -rv;
      if (absv > peak_v) begin
        peak_v = absv;
        peak_k = n;
      end
    end
    lag_scan = (peak_k >= N/2) ? (peak_k - N) : peak_k;
    lag_fw   = res(13);
    $display("  峰值滞后: 固件报 %0d，TB 自己扫出来 %0d（期望 +7）",
             lag_fw, lag_scan);
    check(res(13) == 7, "firmware-reported lag must be +7");
    check(lag_scan == 7, "TB-scanned lag must be +7 (known delay)");

    // ── 参照 1：相关序列逐字比 ──────────────────────────────────────
    n_mismatch = 0;  first_bad = -1;
    for (n = 0; n < N; n = n + 1) begin
      if (r_at(n) !== ref[n]) begin
        n_mismatch = n_mismatch + 1;
        if (first_bad < 0) begin
          first_bad = n;
          $display("  首个不符: n=%0d 实测 %0d 期望 %0d",
                   n, r_at(n), $signed(ref[n]));
        end
      end
    end
    $display("  定点参照比对: %0d/%0d 条不符", n_mismatch, N);
    check(n_mismatch == 0, "R must match the bit-exact fixed-point reference");

    // ── 回归：别的内核没被这次改动带坏 ──────────────────────────────
    $display("  回归: dot=%0d fir=%0d energy=%0d NTAP=%0d FFT峰bin=%0d",
             res(0), res(2), res(4), res(7), res(14));
    check(res(0) == 8519680, "dot product regression");
    check(res(2) == 260,     "FIR regression");
    check(res(4) == 89440,   "energy regression");
    check(res(14) == 16,     "FFT peak bin regression");

    $display("  基线 cycles: FFT(1024)=%0d  GCC-PHAT(一对)=%0d", res(6), res(8));
    check(res(6) > 0 && res(8) > 0, "cycle counters must advance");

    if (errors == 0) begin
      $display("PASS: 固件 GCC-PHAT 与定点参照逐位一致，已知时延 +7 复现");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

  initial begin
    #(MAXC * 12);
    $display("FAIL: timeout after %0d cycles", cyc);
    $finish;
  end

endmodule
