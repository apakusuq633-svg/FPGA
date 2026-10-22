// 固件 FFT 内核的验证 —— 1024 点实数 FFT 跑在真核上，结果对着**两条独立的**
// 参照比：
//
//   1. scripts/golden/fw_fft_model.py 生成的定点参照（build/fw_fft_ref.hex）
//      —— 逐位相等。这条抓的是「C 与模型不一致」，也就是搬写错。
//   2. TB **自己按定义算**的 DFT bins —— X[16] = Σ x[n]·e^{-j2π·16n/1024}
//      —— 实数算术，容差比对。这条抓的是「模型与 C 一起错」。
//
// 为什么两条都要：只留第 1 条的话，模型和固件共用一个错误的标度/下标，
// 仿真照样全绿（gen_srp_vectors.py 里就踩过一次「两边一起错，TB 照样通过」）。
// 第 2 条不依赖任何生成物，它只认 DFT 的定义。
//
// 测试输入（周期 64 的三角波 + LCG 噪声）在**三方**各写一遍：固件 make_frame()、
// Python make_input()、本 TB。三份必须逐字一致 —— 所以刻意写成最笨的整数形式，
// 不用任何库函数。
`timescale 1ns/1ps

module tb_fw_fft;

  localparam integer MAXC  = 14000000;  // 固件整轮 1119 万拍（FFT+GCC+SRP+DAS+GSC）
  localparam integer N     = 1024;
  localparam integer NBIN  = 513;
  localparam integer RESW  = 32'h2800 >> 2;   // 结果块字号
  localparam integer OUTW  = 32'h2880 >> 2;   // 批量输出区 1 的字号（= fw_mem.h 的 FW_OUT_BASE）

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

  // ⚠ 两份镜像都要装：只装 ITCM 的话代码照跑，但 .rodata / .data 初值读出来是 X
  //   （旋转因子表就在 .data 里）。见 sw/fw/link.ld 头部。
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
  integer i, k, retires;
  integer n_mismatch;
  integer first_bad;
  integer peak_k, peak_v, peak_exp;

  // 定点参照（Python 模型生成）
  reg [15:0] ref [0:2*NBIN-1];

  // TB 自己造的输入，用来按定义算 DFT
  reg signed [15:0] frame [0:N-1];
  reg [31:0] lcg;
  // ⚠ 变量名别叫 tri —— 那是 Verilog 的保留字（三态线网），报错指向的是
  //   「invalid module item」，看上去像声明写错，其实是撞了关键字。
  integer ph, tri_v, noise, v;
  real acc_re, acc_im, ang, mag_meas, mag_exp, rel;
  reg [31:0] wtmp;

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

  // 结果块 / 输出区里第 k 个字（backdoor，与 tb_fw_smoke 同一手法）
  function [31:0] res;
    input integer k;
    begin
      res = u_dut.u_dtcm.memory[RESW + k];
    end
  endfunction

  function [31:0] outw;
    input integer k;
    begin
      outw = u_dut.u_dtcm.memory[OUTW + k];
    end
  endfunction

  initial begin
    $display("=== tb_fw_fft ===");

    // ── 与固件 make_frame() 逐字相同的输入 ──────────────────────────
    lcg = 32'h12345678;
    for (i = 0; i < N; i = i + 1) begin
      lcg   = lcg * 32'd1103515245 + 32'd12345;      // 32 位回绕，同 uint32
      noise = (lcg >> 16) & 32'h3FFF;                // 0..16383
      ph    = i % 64;
      tri_v = (ph < 32) ? (ph*1024 - 16384) : (49152 - ph*1024);
      v     = tri_v + (noise - 8192);
      frame[i] = v[15:0];
    end

    // ── 参照 2：按 DFT 定义算 bin 16（无窗、实输入）─────────────────
    // X[k] = Σ x[n]·(cos(2πkn/N) − j·sin(2πkn/N))
    acc_re = 0.0;  acc_im = 0.0;
    for (i = 0; i < N; i = i + 1) begin
      ang = 2.0 * 3.14159265358979 * 16.0 * i / N;
      acc_re = acc_re + frame[i] * $cos(ang);
      acc_im = acc_im - frame[i] * $sin(ang);
    end
    // 固件的输出标度是「真值 / 1024」
    mag_exp = $sqrt(acc_re*acc_re + acc_im*acc_im) / 1024.0;
    $display("  独立复算 X[16]: 真值 (%.1f, %.1f) -> 期望幅度 %.1f",
             acc_re, acc_im, mag_exp);

    $readmemh("build/fw_fft_ref.hex", ref);

    // 阵列系数 bank 清零（必须在固件跑到 GSC 那一级之前做完）—— 见 poke_zero 的注释
    for (pk_bank = 0; pk_bank < 8; pk_bank = pk_bank + 1)
      for (pk_word = 0; pk_word < 15; pk_word = pk_word + 1) poke_zero(pk_bank, pk_word);

    rst_n = 1'b0;
    repeat (20) @(posedge clk);
    rst_n = 1'b1;

    load_steer_lut();   // 放核之前预装转向几何 LUT，见文件头 load_steer_lut 的注释
    // ── 跑到完成标记 ────────────────────────────────────────────────
    retires = 0;
    while ((res(15) !== 32'hC0DE0001) && (cyc < MAXC)) begin
      @(posedge clk);
      cyc = cyc + 1;
      if (retire_valid) retires = retires + 1;
    end
    // 标记之后的 store 还没落地就退出会读到 x（同一个坑见 docs/issues/030）
    repeat (600) @(posedge clk);

    $display("  %0d 拍，退休 %0d 条指令", cyc, retires);

    check(cyc < MAXC, "firmware must finish inside MAXC cycles");
    check(res(15) === 32'hC0DE0001, "firmware must set the done marker");

    // ── 参照 1：逐字比 513 条复数 ───────────────────────────────────
    n_mismatch = 0;
    first_bad  = -1;
    // ⚠ 函数返回值不能直接位选（`outw(k)[15:0]` 不是合法 Verilog），先落一个变量。
    for (k = 0; k < NBIN; k = k + 1) begin
      wtmp = outw(k);
      if (wtmp !== {ref[2*k+1], ref[2*k]}) begin
        n_mismatch = n_mismatch + 1;
        if (first_bad < 0) begin
          first_bad = k;
          $display("  首个不符: bin %0d  实测 re=%0d im=%0d  期望 re=%0d im=%0d",
                   k, $signed(wtmp[15:0]), $signed(wtmp[31:16]),
                   $signed(ref[2*k]), $signed(ref[2*k+1]));
        end
      end
    end
    $display("  定点参照比对: %0d/%0d 条不符", n_mismatch, NBIN);
    check(n_mismatch == 0, "FFT output must match the bit-exact fixed-point reference");

    // ── 参照 2：bin 16 的幅度（±5%，只查量级与标度）─────────────────
    begin : mag_check
      integer re16, im16;
      wtmp = outw(16);
      re16 = $signed(wtmp[15:0]);
      im16 = $signed(wtmp[31:16]);
      mag_meas = $sqrt(re16*re16 + im16*im16 + 0.0);
      rel = (mag_meas - mag_exp) / mag_exp;
      if (rel < 0.0) rel = -rel;
      $display("  X[16] 幅度: 实测 %.1f  独立复算 %.1f  相对差 %.2f%%",
               mag_meas, mag_exp, rel * 100.0);
      check(rel < 0.05, "bin16 magnitude must match the DFT definition within 5%");
    end

    // ── 峰值 bin：三角波周期 64 ⇒ 基波在 bin 16 ─────────────────────
    peak_v = -1;  peak_k = -1;
    for (k = 0; k < NBIN; k = k + 1) begin
      begin : pk
        integer rr, ii, vv;
        wtmp = outw(k);
        rr = $signed(wtmp[15:0]);
        ii = $signed(wtmp[31:16]);
        vv = rr*rr + ii*ii;
        if (vv > peak_v) begin peak_v = vv; peak_k = k; end
      end
    end
    peak_exp = res(14);
    $display("  峰值 bin: 固件报 %0d，TB 自己扫出来 %0d（期望 16）",
             peak_exp, peak_k);
    check(peak_exp == 16, "firmware-reported peak bin must be 16");
    check(peak_k == 16,   "TB-scanned peak bin must be 16");

    // ── 其它内核仍然正常（回归）────────────────────────────────────
    $display("  回归: dot=%0d fir=%0d energy=%0d NTAP=%0d",
             res(0), res(2), res(4), res(7));
    check(res(0) == 8519680, "dot product regression");
    check(res(2) == 260,     "FIR regression");
    check(res(4) == 89440,   "energy regression");

    $display("  基线 cycles: dot=%0d  fir=%0d  eng=%0d", res(1), res(3), res(5));
    $display("  FFT(1024) 标量 = %0d 拍", res(6));
    $display("  FFT(1024) 硬件 = %0d 拍   =>  %.2f x (含核侧 lw/sw)",
             res(20), res(6) * 1.0 / (res(20) + 1));
    check(res(6) > 0, "FFT cycle count must advance");

    if (errors == 0) begin
      $display("PASS: 固件 1024 点实数 FFT 与定点参照逐位一致，且与 DFT 定义相符");
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
