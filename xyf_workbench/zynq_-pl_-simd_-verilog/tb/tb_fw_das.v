// 固件 DAS 波束形成器内核的验证（README §26.1）。
//
// 对着 scripts/golden/fw_das_model.py 比**六个指纹**（fw_das.h 的 RES 21..27）：
//
//   RES(21) cycles        一帧（512 样点 × 8 通道）的拍数
//   RES(22) cksum         y_mix 的普通校验和   ┐ 两个独立指纹，覆盖**每一个输出样点**，
//   RES(23) wcksum        y_mix 的加权校验和   ┘ 且逐位可比 —— 等价于逐样点验证
//   RES(24) p_target      Σ(y_t>>3)²   ┐
//   RES(25) p_other       Σ(y_o>>3)²   │ 定标功率和，用来在**固件侧**直接算 SNR
//   RES(26) p_mic         Σ(a_0>>3)²   │ （单麦基线）
//   RES(27) p_mic_oth     Σ(其余_0>>3)²┘
//   RES(28) ndiff         目标/干扰两路的 D_m 是否真的不同（结构自检）
//
// 为什么不比波形：DTCM 只有 16 KB，FW_OUT/FW_OUT2 已被 FFT/GCC 占着且
// tb_fw_fft/tb_fw_gcc 要读它们。校验和 + 功率和已经能覆盖全部输出 ——
// 任何一个样点差 1，两个校验和都会变。这与 fw_main.c §5 的指纹做法一致。
//
// ⚠ 本 TB 验的是**内核的定点正确性**，不是"波束形成在物理上有没有效"。
//   后者（DAS 相对单麦能改善多少 dB）由 Python 模型给，并在这里用 p 相除复核。
`timescale 1ns/1ps

module tb_fw_das;

  localparam integer MAXC = 14000000;   // 固件整轮 1119 万拍（FFT+GCC+SRP+DAS+GSC）
  localparam integer RESW = 32'h2800 >> 2;

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

  integer errors = 0, cyc = 0, retires = 0, i;
  reg [31:0] fp_ref [0:5];              // cksum, wcksum, p_t, p_o, p_mic, p_mic_oth

  function [31:0] res;
    input integer k;
    begin
      res = u_dut.u_dtcm.memory[RESW + k];
    end
  endfunction

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

  // dB(10log10) —— 只为打印，不参与判据（判据是逐位相等）
  function real db10;
    input integer num, den;
    begin
      if (den <= 0) db10 = 0.0;
      else db10 = 10.0 * $ln(num * 1.0 / den) / $ln(10.0);
    end
  endfunction

  initial begin
    $display("=== tb_fw_das ===");
    for (i = 0; i < 6; i = i + 1) fp_ref[i] = 32'b0;
    $readmemh("build/fw_das_fp.hex", fp_ref);

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

    $display("  DAS 一帧(512 样点 x 8 通道) = %0d 拍 = %0d 拍/样点/通道",
             res(21), res(21) / 512 / 8);

    // ── 结构自检：干扰源的 D_m 必须互异，否则求和不会抵消 ──────────
    check(res(28) === 32'd1, "interferer delays must differ across channels");

    // ── 六个指纹逐位比 ─────────────────────────────────────────────
    check(res(22) === fp_ref[0], "y_mix checksum must match the model");
    if (res(22) !== fp_ref[0])
      $display("    cksum     fw=0x%08x  model=0x%08x", res(22), fp_ref[0]);
    check(res(23) === fp_ref[1], "y_mix weighted checksum must match the model");
    if (res(23) !== fp_ref[1])
      $display("    wcksum    fw=0x%08x  model=0x%08x", res(23), fp_ref[1]);

    check(res(24) === fp_ref[2], "p_target must match the model");
    if (res(24) !== fp_ref[2])
      $display("    p_target  fw=%0d  model=%0d", res(24), fp_ref[2]);
    check(res(25) === fp_ref[3], "p_other must match the model");
    if (res(25) !== fp_ref[3])
      $display("    p_other   fw=%0d  model=%0d", res(25), fp_ref[3]);
    check(res(26) === fp_ref[4], "p_mic must match the model");
    if (res(26) !== fp_ref[4])
      $display("    p_mic     fw=%0d  model=%0d", res(26), fp_ref[4]);
    check(res(27) === fp_ref[5], "p_mic_other must match the model");
    if (res(27) !== fp_ref[5])
      $display("    p_mic_oth fw=%0d  model=%0d", res(27), fp_ref[5]);

    // ── 物理效果：DAS 相对单麦改善了没有（用固件自己算的 p 复核）────
    $display("  单麦基线 %+.2f dB  ->  DAS %+.2f dB  （改善 %+.2f dB）",
             db10(res(26), res(27)),
             db10(res(24), res(25)),
             db10(res(24), res(25)) - db10(res(26), res(27)));
    check(db10(res(24), res(25)) > db10(res(26), res(27)) + 3.0,
          "DAS must beat the single-mic baseline by >3 dB (array gain is real)");

    if (errors == 0) $display("PASS: tb_fw_das 全部通过");
    else             $display("FAIL: tb_fw_das %0d 处不符", errors);
    $finish;
  end

endmodule
