// 固件 SRP 空间扫描内核的验证。
//
// 对着三样东西比：
//   1. 延迟转储（256 个格点的 τ 打包值）—— 与 Python 定点模型逐位一致
//   2. 累加器 P（256 个 int32）—— 同上；R 用的是**固件自己刚算出的 GCC-PHAT
//      输出**，所以这条同时验证了两个内核串起来没问题
//   3. 几何本身与 `mic_geometry.delay_lut` 的浮点金标准一致（在 Python 侧，
//      见 fw_srp_model.py 的第 ① 段 —— 最大误差 0.0126 样点）
//
// ⚠ 网格是 **16×16**，不是规格的 32×32：P 是 int32 × 1024 = 4 KB，DTCM 里
//   腾不出连续空间（见 sw/fw/fw_srp.h）。对比要用的量是
//   **cycles / (格点 × 对)**，与网格大小无关。
//
// ⚠ 本 TB **不验定位精度**：4 对共用同一份 R，"声源"在几何上不自洽，
//   峰值格号没有物理意义。要验定位精度得喂真实的 8 通道数据。
`timescale 1ns/1ps

module tb_fw_srp;

  localparam integer MAXC  = 14000000;  // 固件整轮 1119 万拍（FFT+GCC+SRP+DAS+GSC）
  localparam integer GRIDW = 16;
  localparam integer GRIDN = GRIDW * GRIDW;
  localparam integer RESW  = 32'h2800 >> 2;
  localparam integer R_LEN = 1024;

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

  integer errors = 0, cyc = 0, retires = 0;
  integer i, n_mismatch, first_bad;
  reg [31:0] tau_base, p_base, wtmp, wtmp2;
  reg [15:0] tau_ref [0:GRIDN-1];
  reg [31:0] p_ref  [0:GRIDN-1];

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

  // 按**运行期给的字号**读 DTCM（内核的缓冲区在 .bss，地址由 RES 传出来）
  function [31:0] memw;
    input [31:0] word_idx;
    begin
      memw = u_dut.u_dtcm.memory[word_idx];
    end
  endfunction

  initial begin
    $display("=== tb_fw_srp ===");
    $readmemh("build/fw_srp_tau.hex", tau_ref);
    $readmemh("build/fw_srp_p.hex", p_ref);

    // 阵列系数 bank 清零（必须在固件跑到 GSC 那一级之前做完）—— 见 poke_zero 的注释
    for (pk_bank = 0; pk_bank < 8; pk_bank = pk_bank + 1)
      for (pk_word = 0; pk_word < 15; pk_word = pk_word + 1) poke_zero(pk_bank, pk_word);

    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;

    load_steer_lut();   // 放核之前预装转向几何 LUT，见文件头 load_steer_lut 的注释
    while ((res(15) !== 32'hC0DE0001) && (cyc < MAXC)) begin
      @(posedge clk);
      cyc = cyc + 1;
      if (retire_valid) retires = retires + 1;
    end
    repeat (600) @(posedge clk);

    $display("  %0d 拍，退休 %0d 条指令", cyc, retires);
    check(cyc < MAXC, "firmware must finish inside MAXC cycles");
    check(res(15) === 32'hC0DE0001, "firmware must set the done marker");

    // ── 内核把两个缓冲区的**地址**放在 RES(9)/RES(10) ───────────────
    tau_base = res(9);
    p_base   = res(10);
    $display("  τ 转储 @ 0x%08x   P 累加器 @ 0x%08x", tau_base, p_base);
    check(tau_base >= 32'h0 && tau_base < 32'h2800, "tau dump must live in DTCM");
    check(p_base   >= 32'h0 && p_base   < 32'h2800, "P must live in DTCM");

    // ── 1. 延迟转储逐位比 ───────────────────────────────────────────
    n_mismatch = 0;  first_bad = -1;
    for (i = 0; i < GRIDN; i = i + 1) begin
      wtmp = memw((tau_base >> 2) + (i >> 1));
      wtmp2 = (i[0] == 1'b0) ? {16'b0, wtmp[15:0]} : {16'b0, wtmp[31:16]};
      if (wtmp2[15:0] !== tau_ref[i]) begin
        n_mismatch = n_mismatch + 1;
        if (first_bad < 0) begin
          first_bad = i;
          $display("  首个不符: 格点 %0d 实测 %04x 期望 %04x",
                   i, wtmp2[15:0], tau_ref[i]);
        end
      end
    end
    $display("  延迟转储: %0d/%0d 条不符", n_mismatch, GRIDN);
    check(n_mismatch == 0, "tau dump must match the fixed-point reference");

    // ── 2. 累加器逐位比 ─────────────────────────────────────────────
    n_mismatch = 0;  first_bad = -1;
    for (i = 0; i < GRIDN; i = i + 1) begin
      wtmp = memw((p_base >> 2) + i);
      if (wtmp !== p_ref[i]) begin
        n_mismatch = n_mismatch + 1;
        if (first_bad < 0) begin
          first_bad = i;
          $display("  首个不符: P[%0d] 实测 %08x 期望 %08x", i, wtmp, p_ref[i]);
        end
      end
    end
    $display("  累加器:   %0d/%0d 条不符", n_mismatch, GRIDN);
    check(n_mismatch == 0, "P must match the fixed-point reference");

    // ── 3. 峰值格号（TB 自己扫，不认固件报的）───────────────────────
    begin : pk
      integer kk, best, best_i;
      best = -2147483648;  best_i = -1;
      for (kk = 0; kk < GRIDN; kk = kk + 1) begin
        wtmp = memw((p_base >> 2) + kk);
        if ($signed(wtmp) > best) begin
          best = $signed(wtmp);  best_i = kk;
        end
      end
      $display("  峰值格号: 固件报 %0d，TB 自己扫出来 %0d（参照 224）",
               res(12), best_i);
      check(res(12) == 224, "firmware-reported argmax");
      check(best_i == 224,  "TB-scanned argmax");
    end

    // ── 4. 波束形成（DAS）指纹 ──────────────────────────────────────
    // P 被后面的 SRP 覆盖了（两者共用累加器，见 fw_main.c 的顺序说明），
    // 所以这里只能验**指纹**：峰值格号 + 累加器校验和。校验和由 Python
    // 用同一份定点模型算出来，能抓住任何一点的偏差。
    $display("  DAS: 峰值格号 固件报 %0d（参照 208），校验和 固件 %0d / 参照 23766",
             res(17), res(18));
    check(res(17) == 208,   "DAS argmax must be 208");
    check(res(18) == 23766, "DAS accumulator checksum");

    // ── 5. 回归 ─────────────────────────────────────────────────────
    $display("  回归: dot=%0d FFT峰bin=%0d GCC滞后=%0d",
             res(0), res(14), res(13));
    check(res(0) == 8519680, "dot product regression");
    check(res(14) == 16,     "FFT peak bin regression");
    check(res(13) == 7,      "GCC lag regression");

    $display("  基线 cycles: FFT(1024)=%0d  GCC(一对)=%0d  SRP(一对×256格)=%0d",
             res(6), res(8), res(11));
    $display("               互相关(不白化)=%0d  DAS(一对×256格)=%0d",
             res(16), res(19));
    check(res(11) > 0, "SRP cycle count must advance");
    check(res(16) > 0 && res(19) > 0, "DAS cycle counters must advance");

    if (errors == 0) begin
      $display("PASS: 固件 SRP 扫描与定点参照逐位一致（几何 + 插值 + 累加）");
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
