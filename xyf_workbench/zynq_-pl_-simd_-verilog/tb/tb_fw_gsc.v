// 固件 GSC 内核的验证（README §26.3）。
//
// 对着 scripts/golden/fw_gsc_model.py 比指纹，并检查**物理判据**。
//
// ⚠⚠ **`e_cksum` 在这一场景下是"空判据"，单看它会漏 bug。**
//   原因：目标源被**精确对准** ⇒ 8 路对齐通道完全相同 ⇒ 阻塞矩阵输出 u_j ≡ 0
//   ⇒ filt(h_tgt) ≡ 0 ⇒ e_t = d_t，**与滤波器无关**。实测：L=16 与 L=32 两次
//   跑出来的 e_cksum 一模一样（0x00020B7C）—— 它不是"对上了"，是**没被测到**。
//   这与 docs/issues/042 的"回绕版判据恒满足"是同一类错误。
//   2026-10-05 已补上一条接线检查（下面 §"目标通路的接线检查"）：把 GSC 的
//   p_e_target 与 DAS 的 p_target 断言相等，h_tgt 接错线会被它抓住。
//   ⇒ 真正能判别数值的是 **p_e_other 与 w_ck**（它们随抽头数/步长变）。
//   ⇒ **仍欠一个"指向误差"场景**：把转向偏开目标，让目标那一路的阻塞非零，
//     目标滤波通路才被**数值地**覆盖。见文件末尾的 TODO。
//
// 结果位置：
//   RES(29) 拍数   RES(30) e_cksum   RES(31) e_wcksum
//   FW_GSC_EXTRA (0x3C40) = FW_GSC_BASE(0x38C0) + 0x380：
//       [0] p_e_target  [1] p_e_other  [2] mix_cksum  [3] w_ck
//     结果块只有 32 个字，DAS 已占 21..28，装不下两套指纹 —— 所以多余的按
//     **固定绝对地址**读，与 fw_srp 把 τ 转储/P 的地址放进 RES 是同一个套路。
`timescale 1ns/1ps

module tb_fw_gsc;

  localparam integer MAXC  = 13000000;  // 整轮：标量 GSC + 阵列 GSC 各一趟（≈11.4M）。刻意留窄：
                                        // 卡住时能更快看到探针 EXTRA[8] 走到第几个样点
  localparam integer RESW  = 32'h2800 >> 2;
  localparam integer GSCX  = 32'h3C40 >> 2;   // FW_GSC_EXTRA 的字号

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
    .clk_i (clk), .rst_n_i (rst_n), .test_en_i (1'b0), .halt_i (1'b0),
    .retire_valid_o (retire_valid), .retire_pc_o (retire_pc),
    .retire_instr_o (retire_instr), .retire_fault_o (retire_fault),
    .tohost_o (), .tohost_we_o (), .fromhost_i (32'b0), .led_o (),
    .ps_req_i (1'b0), .ps_write_i (1'b0), .ps_sel_i (1'b0), .ps_addr_i (32'b0),
    .ps_wdata_i (32'b0), .ps_ready_o (), .ps_rdata_o (),
     
    .coef_we_i (1'b0), .coef_re_i (1'b0), .coef_src_i (1'b0), .coef_ch_i (1'b0),
    .coef_idx_i (9'b0), .coef_wdata_i (16'b0), .coef_rdata_o (),
       
      .tacho_i (1'b0),
    .steer_cfg_wr_i   (ps_wr), .steer_cfg_rd_i   (ps_rd), .steer_cfg_addr_i  (ps_addr),
    .steer_cfg_wdata_i (ps_wdata), .steer_cfg_rdata_o ()
  );

  integer errors = 0, cyc = 0, retires = 0, i, j;
  integer n_push = 0, n_vred = 0, n_vupd = 0, n_vfft = 0, n_fault = 0;
  always @(negedge clk) begin
    if (rst_n && retire_valid) begin
      if (retire_fault != 0) n_fault = n_fault + 1;
      if (retire_instr[6:0] == 7'h0B) begin
        case (retire_instr[14:12])
          0: n_push = n_push + 1;
          1: n_vred = n_vred + 1;
          2: n_vupd = n_vupd + 1;
          7: n_vfft = n_vfft + 1;
        endcase
      end
    end
  end
  reg [63:0] pct_scene, pct_nlms;
  reg [31:0] fp_vec [0:1];              // 阵列那路：p_e_target, p_e_other
  reg [31:0] fp_ref [0:5];              // cksum, wcksum, p_t, p_o, mix_ck, w_ck

  function [31:0] res; input integer k;
    begin res = u_dut.u_dtcm.memory[RESW + k]; end
  endfunction
  function [31:0] gx; input integer k;
    begin gx = u_dut.u_dtcm.memory[GSCX + k]; end
  endfunction

  // ── 阵列系数 bank 清零 ────────────────────────────────────────────────
  // ⚠⚠ **不能省。** 那块 BRAM 没有复位（`RAM contents survive reset`，为了推断成
  //   BRAM），而固件**够不着** `coef_*` 端口（SoC 顶层、PS 侧驱动）⇒ 只能由 TB
  //   用层次引用捅。不捅的话读到的是 **X**，加法树整条变 X，表现为"阵列那路算出来
  //   是 x" —— 而 x 在 `===` 下既不等于期望值、也不报未初始化（tb_vec_unit 踩过）。
  //   VS_NTAP=120 ⇒ 每 bank 15 个字（word 0..14），8 个 bank 全要。
  //   `generate` 块的层次下标必须是常量 ⇒ 展开成 case（变量下标 iverilog 直接报错）。
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

  task check; input cond; input [8*96-1:0] msg;
    begin
      if (!cond) begin errors = errors + 1; $display("  FAIL: %0s", msg); end
    end
  endtask

  function real db10; input integer num, den;
    begin
      if (den <= 0) db10 = 0.0;
      else db10 = 10.0 * $ln(num * 1.0 / den) / $ln(10.0);
    end
  endfunction

  initial begin
    $display("=== tb_fw_gsc ===");
    for (i = 0; i < 6; i = i + 1) fp_ref[i] = 32'b0;
    $readmemh("build/fw_gsc_fp.hex", fp_ref);
    for (i = 0; i < 2; i = i + 1) fp_vec[i] = 32'b0;
    $readmemh("build/fw_gsc_vec_fp.hex", fp_vec);

    // 阵列系数 bank 清零（必须在固件跑到 mode=1 之前做完）—— 见 poke_zero 的注释
    for (i = 0; i < 8; i = i + 1)
      for (j = 0; j < 15; j = j + 1) poke_zero(i, j);

    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;

    load_steer_lut();   // 放核之前预装转向几何 LUT，见文件头 load_steer_lut 的注释
    while ((res(15) !== 32'hC0DE0001) && (cyc < MAXC)) begin
      @(posedge clk); cyc = cyc + 1;
      if (retire_valid) retires = retires + 1;
    end
    repeat (600) @(posedge clk);

    $display("  %0d 拍，退休 %0d 条指令", cyc, retires);
    check(cyc < MAXC, "firmware must finish inside MAXC cycles");
    check(res(15) === 32'hC0DE0001, "firmware must set the done marker");

    $display("  GSC 一趟(512 样点 x 3 条 x 7 路 x 16 抽头) = %0d 拍 (%0d 拍/样点)",
             res(29), res(29) / 512);
    $display("  DAS 一帧 = %0d 拍", res(21));
    // 分段：只给"场景生成"一段（其余由总拍数减出来）。
    // ⚠ 之所以只给一段：每次 rdcycle 展开 ~8 条指令，8 次/样点会把 .text 顶过 0x2000。
    // ⚠ 百分比要 (a*1000/total) 再手点小数点 —— Verilog 的 `/` 是整数除法，
    //   写成 (a*100)/(total/100) 会印出 1150% 这种数（踩过）。
    // ⚠⚠ 百分比要**64 位中间**。写成 `(res(29)-gx(4)) * 1000` 会溢出 int32：
    //   5,123,773 × 1000 = 5.12e9 > 2^31 ⇒ 回绕成 8.29e8 ⇒ 印出 **13.8%**
    //   而真值是 **85.5%**。拍数是对的，只有百分比错 —— 这种"看着合理的错数"最危险。
    //   （第一版就是这么印的，是对着拍数手算才发现对不上。）
    pct_scene = gx(4) * 64'd1000 / res(29);
    pct_nlms  = (res(29) - gx(4)) * 64'd1000 / res(29);
    $display("    ├ 场景生成(8 麦 x 3 分量 x 2 次 hash) = %0d 拍 (%0d.%0d%%)",
             gx(4), pct_scene / 10, pct_scene % 10);
    $display("    └ NLMS 内核(阻塞/滤波/范数/更新)    = %0d 拍 (%0d.%0d%%)",
             res(29) - gx(4), pct_nlms / 10, pct_nlms % 10);

    // ── 指纹：能判别的那两个（p_e_other / w_ck）必须逐位相等 ──────────
    check(gx(1) === fp_ref[3], "p_e_other must match the model");
    if (gx(1) !== fp_ref[3])
      $display("    p_e_other fw=%0d model=%0d", gx(1), fp_ref[3]);
    check(gx(3) === fp_ref[5], "w_ck (final weight sum) must match the model");
    if (gx(3) !== fp_ref[5])
      $display("    w_ck      fw=0x%08x model=0x%08x", gx(3), fp_ref[5]);
    check(gx(2) === fp_ref[4], "mix_cksum must match the model");
    if (gx(2) !== fp_ref[4])
      $display("    mix_cksum fw=0x%08x model=0x%08x", gx(2), fp_ref[4]);
    // 空判据，仍然比 —— 对不上说明定点口径错了；对上了**不代表目标通路被测到**
    check(res(30) === fp_ref[0], "e_cksum must match the model");
    check(res(31) === fp_ref[1], "e_wcksum must match the model");

    // ── 目标通路的**接线**检查（补 e_cksum 的洞）─────────────────────────
    // 精确对准 ⇒ 阻塞 u_j ≡ 0 ⇒ filt(h_tgt) ≡ 0 ⇒ e_t ≡ d_t
    // ⇒ GSC 的 p_e_target 必须**逐位等于** DAS 的 p_target：两边都是 Σ(y>>3)²，
    //   同一张延迟表、同一个源、同一口径，本该一模一样。
    // 这条真正查的是 **h_tgt 有没有接错线**（比如误接了 a_mix）：一旦 y_t ≠ 0，
    // e_t ≠ d_t，两个数立刻不等。而 e_cksum 在 e_t ≡ d_t 时只是"源求和的校验和"，
    // filt 通不通它根本看不见 —— L=16 与 L=32 的 e_cksum 逐位相同就是这么来的。
    // ⚠ 若将来加了"指向误差"场景，这条等式**按设计不再成立**（那时 u_j ≠ 0），
    //   要换成与模型比对 —— 见文件末尾 TODO。
    check(gx(0) === res(24),
          "p_e_target must equal DAS p_target exactly (aligned => e_t == d_t; catches h_tgt mis-wiring)");
    if (gx(0) !== res(24))
      $display("    p_e_target fw=%0d das=%0d", gx(0), res(24));

    // ── 物理判据：GSC 必须比 DAS 好（用两个内核各自算的功率和）──────────
    $display("  DAS  %+.2f dB   GSC  %+.2f dB   (相对 DAS %+.2f dB)",
             db10(res(24), res(25)), db10(gx(0), gx(1)),
             db10(gx(0), gx(1)) - db10(res(24), res(25)));
    check(db10(gx(0), gx(1)) >= db10(res(24), res(25)) - 0.05,
          "GSC must not be worse than DAS (the adaptive canceller earns its keep)");
    check(gx(3) !== 0, "weights must have actually adapted (w_ck != 0)");

    // ── 阵列那路（mode=1）：7 路交织进 SIMD-MAC，滤波与更新都由阵列做 ──────
    // 与 scripts/golden/fw_gsc_vec_model.py 逐位比。口径不同的两套定点，
    // 所以**不能**拿标量的指纹比它 —— 只比 p_e_target / p_e_other。
    $display("  [阵列] 一趟 = %0d 拍 (%0d 拍/样点)", gx(5), gx(5) / 512);
    $display("  [阵列] DAS %+.2f dB   GSC %+.2f dB   (相对 DAS %+.2f dB)",
             db10(res(24), res(25)), db10(gx(6), gx(7)),
             db10(gx(6), gx(7)) - db10(res(24), res(25)));
    check(gx(6) === fp_vec[0], "array p_e_target must match fw_gsc_vec_model.py");
    if (gx(6) !== fp_vec[0])
      $display("    array p_e_target fw=%0d model=%0d", gx(6), fp_vec[0]);
    check(gx(7) === fp_vec[1], "array p_e_other must match fw_gsc_vec_model.py");
    if (gx(7) !== fp_vec[1])
      $display("    array p_e_other  fw=%0d model=%0d", gx(7), fp_vec[1]);
    check(gx(5) !== 0, "the array path must have been timed by main (EXTRA[5] != 0)");
    check(n_fault == 0, "acoustic firmware must retire without faults");
    check(n_push > 0 && n_vred > 0 && n_vupd > 0 && n_vfft > 0,
          "PUSH/VRED/VUPD/VFFT must actually retire, GSC cannot be bypassed");
    check(gx(5) < res(29), "SIMD GSC must reduce cycles against scalar GSC");
    check(db10(gx(6), gx(7)) >= db10(res(24), res(25)),
          "SIMD GSC must improve DAS in this controlled acceptance scene");
    $display("ACOUSTIC_INSTRUCTIONS: PUSH=%0d VRED=%0d VUPD=%0d VFFT=%0d faults=%0d",
             n_push, n_vred, n_vupd, n_vfft, n_fault);

    if (errors == 0) $display("PASS: tb_fw_gsc 全部通过");
    else             $display("FAIL: tb_fw_gsc %0d 处不符", errors);
    $finish;
  end

endmodule

// TODO(指向误差场景)：再加一份延迟表，把**转向偏开目标**（例如转向扫描面中心
//   或干扰源方向）。那样目标那一路的阻塞 u_j 非零，filt(h_tgt) 才真正参与，
//   e_cksum/p_e_target 才从"空判据"变成真判据。见 README §26.6（指向误差正是
//   GSC 会退化的条件之一，所以这个场景本来就该有）。
