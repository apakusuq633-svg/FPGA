// 通道对齐 / DC 去除 / 增益校准的验收测试（README §12 / §13 / §14）。
//
// ⚠ 本 TB 每拍一个样点，等效采样率 fs_sim 取名义值 39062.5 Hz。
//   滤波器行为只取决于 f/fs 这个**比值**，取名义值不损失一般性，而且让 12 Hz
//   拐点的周期压到几千样点，仿真跑得动。
//
// ⚠ check() 的消息必须是 ASCII：UTF-8 中文经 reg 位向量传参会按字节截断，
//   长消息会显示成乱码。中文只出现在 $display 的字面量里。
//
// 七段，每段先证明观测有效再断言：
//   1. 停用时输出恒 0；
//   2. DC 去除：恒定输入的残差必须单调下降，并**收敛到实测的死区** [0, 2^DC_K)；
//   3. 通带保真：1 kHz 正弦幅度必须与解析 |H(f)| 相符；
//   4. 频响 vs 解析：扫 50 / 200 / 1000 / 5000 Hz 四点逐点比；
//   5. 增益校准：g=0.5 幅度减半、g=1.0 原样通过；
//   6. 饱和：大信号必须削在边界，且正负都还在（回绕会变成满幅噪声）；
//   7. 反证：DC_K=0（纯微分器）与 DC_K=9 吃同一路激励，**实测**必须差很多。
//      没有这一段，前面对得上分不清是真对还是解析式自己也错了。
`timescale 1ns/1ps

module tb_chan_align;

  localparam integer N_CH   = 8;
  localparam integer IN_W   = 24;
  localparam integer OUT_W  = 24;
  localparam integer DC_K   = 9;
  localparam real    FS     = 39062.5;
  localparam real    PI     = 3.14159265358979;
  localparam integer FULL   = 1 <<< (OUT_W-1);   // 2^23

  reg clk = 1'b0;
  always #12.5 clk = ~clk;

  reg rst_n = 1'b0;
  reg en    = 1'b0;

  reg  [N_CH*IN_W-1:0]  audio_in;
  reg                   valid_i;
  reg  [N_CH*16-1:0]    gain_q;
  wire [N_CH*OUT_W-1:0] audio_out;
  wire                  valid_o;

  rv32_chan_align #(
    .N_CH (N_CH), .IN_W (IN_W), .OUT_W (OUT_W), .DC_K (DC_K)
  ) u_dut (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .audio_vec_i (audio_in), .valid_i (valid_i), .gain_q_i (gain_q),
    .audio_vec_o (audio_out), .valid_o (valid_o)
  );

  // 第二份 DUT：DC_K = 0（alpha = 0，退化成纯微分器），只用于第 7 段反证。
  wire [N_CH*OUT_W-1:0] audio_out_k0;

  rv32_chan_align #(
    .N_CH (N_CH), .IN_W (IN_W), .OUT_W (OUT_W), .DC_K (0)
  ) u_dut_k0 (
    .clk_i (clk), .rst_n_i (rst_n), .en_i (en),
    .audio_vec_i (audio_in), .valid_i (valid_i), .gain_q_i (gain_q),
    .audio_vec_o (audio_out_k0), .valid_o ()
  );

  integer errors = 0;
  integer cyc = 0;
  always @(posedge clk) cyc = cyc + 1;

  task check;
    input            cond;
    input [8*96-1:0] msg;
    begin
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s  (t=%0t)", msg, $time);
      end
    end
  endtask

  function signed [OUT_W-1:0] ch;
    input integer k;
    begin
      ch = audio_out[k*OUT_W +: OUT_W];
    end
  endfunction

  function signed [OUT_W-1:0] ch0;
    input integer k;
    begin
      ch0 = audio_out_k0[k*OUT_W +: OUT_W];
    end
  endfunction

  function integer iabs;
    input integer v;
    begin
      iabs = (v < 0) ? -v : v;
    end
  endfunction

  // 解析幅频响应 |H| = 2|sin(w/2)| / |1 - alpha*e^-jw|
  function real hmag;
    input real f;
    input real alpha;
    real w;
    begin
      w = 2.0 * PI * f / FS;
      hmag = (2.0 * $sin(w / 2.0)) /
             $sqrt(1.0 - 2.0 * alpha * $cos(w) + alpha * alpha);
    end
  endfunction

  task set_all;
    input signed [IN_W-1:0] v;
    integer j;
    begin
      for (j = 0; j < N_CH; j = j + 1) audio_in[j*IN_W +: IN_W] = v[IN_W-1:0];
    end
  endtask

  task set_gain_all;
    input [15:0] g;
    integer j;
    begin
      for (j = 0; j < N_CH; j = j + 1) gain_q[j*16 +: 16] = g;
    end
  endtask

  real    amp_in;
  integer pk_max, pk_min, pk0_max, pk0_min;
  reg [IN_W-1:0] stim;
  integer i;
  real    alpha, meas, expect, err_pct;
  real    freq;

  // 跑一段正弦，量后半个窗的峰峰值（避开起始暂态）
  task run_sine;
    input real f;
    input real a;
    input integer nsamp;
    integer j;
    real    ph;
    begin
      pk_max  = -(1 << 30);
      pk_min  =  (1 << 30);
      pk0_max = -(1 << 30);
      pk0_min =  (1 << 30);
      for (j = 0; j < nsamp; j = j + 1) begin
        ph = 2.0 * PI * f * (j + 1) / FS;
        stim = $rtoi(a * $sin(ph));
        audio_in = {(N_CH*IN_W){1'b0}};
        set_all(stim);
        @(posedge clk);
        if (j > nsamp / 2) begin
          if ($signed(ch(0))  > pk_max)  pk_max  = $signed(ch(0));
          if ($signed(ch(0))  < pk_min)  pk_min  = $signed(ch(0));
          if ($signed(ch0(0)) > pk0_max) pk0_max = $signed(ch0(0));
          if ($signed(ch0(0)) < pk0_min) pk0_min = $signed(ch0(0));
        end
      end
      amp_in = a;
    end
  endtask

  task expect_match;
    input real got;
    input real want;
    input real tol_pct;
    input [8*96-1:0] msg;
    real e;
    begin
      e = (got - want) / want * 100.0;
      check((e < tol_pct) && (e > -tol_pct), msg);
    end
  endtask

  integer r1, r2, r3, r4;

  initial begin
    audio_in = {(N_CH*IN_W){1'b0}};
    valid_i  = 1'b0;
    gain_q   = {(N_CH*16){1'b0}};
    set_gain_all(16'd16384);   // Q2.14: 1.0
    set_all(24'sd0);

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    $display("=== tb_chan_align: %0d channels, DC_K=%0d ===", N_CH, DC_K);
    alpha = 1.0 - 1.0 / (1 << DC_K);
    $display("    alpha = %.6f  ->  f_c = %.1f Hz",
             alpha, -$ln(alpha) * FS / (2.0 * PI));

    // ── 段 1 ────────────────────────────────────────────────────────
    $display("[1] disabled: output must be 0, valid_o must be 0");
    en = 1'b0; valid_i = 1'b1;
    set_all(24'sd1000000);
    repeat (50) @(posedge clk);
    check(ch(0) === 24'sd0, "disabled: ch0 must be 0");
    check(valid_o === 1'b0, "disabled: valid_o must be 0");

    // ── 段 2：DC 去除 + 死区实测 ────────────────────────────────────
    $display("[2] DC removal, constant input 100000 (measuring the dead zone)");
    en = 1'b1; valid_i = 1'b1;
    set_all(24'sd100000);
    repeat (100)   @(posedge clk); r1 = $signed(ch(0));
    repeat (1900)  @(posedge clk); r2 = $signed(ch(0));
    repeat (4000)  @(posedge clk); r3 = $signed(ch(0));
    repeat (10000) @(posedge clk); r4 = $signed(ch(0));
    $display("    residual @100/2000/6000/16000 = %0d / %0d / %0d / %0d",
             r1, r2, r3, r4);
    $display("    predicted dead zone = [0, %0d)  (= %.1f dBFS)",
             1 << DC_K, 20.0 * $log10((1 << DC_K) * 1.0 / FULL));
    // ⚠ 不能用平方比大小：80993^2 = 6.6e9 溢出 32 位 integer，
    //   会翻成负数让断言假通过/假失败。比绝对值。
    check(iabs(r1) > iabs(r2), "residual must shrink (1)");
    check(iabs(r2) > iabs(r3), "residual must shrink (2)");
    check((r3 >= 0) && (r3 < (1 << DC_K)),
          "residual must settle inside [0, 2^DC_K) -- the shift dead zone");
    check(r4 == r3, "once inside the dead zone the residual must be constant");
    check(r3 < FULL / 1000,
          "dead zone must be well below 0.1% of full scale");

    // ── 段 3+4：频响 vs 解析 ────────────────────────────────────────
    $display("[3/4] magnitude response vs analytic |H(f)|");
    set_all(24'sd0);
    repeat (300) @(posedge clk);
    for (i = 0; i < 4; i = i + 1) begin
      case (i)
        0: freq =   50.0;
        1: freq =  200.0;
        2: freq = 1000.0;
        3: freq = 5000.0;
      endcase
      run_sine(freq, 100000.0, 4000);
      meas   = (pk_max - pk_min) / 2.0;
      expect = hmag(freq, alpha) * amp_in;
      err_pct = (meas - expect) / expect * 100.0;
      $display("    f=%7.0f Hz  measured %9.1f  analytic %9.1f  err %+6.2f%%",
               freq, meas, expect, err_pct);
      check((err_pct < 3.0) && (err_pct > -3.0),
            "response must match analytic within 3 pct");
    end

    // ── 段 5：增益校准 ──────────────────────────────────────────────
    $display("[5] gain calibration");
    set_all(24'sd0);
    repeat (300) @(posedge clk);
    set_gain_all(16'd8192);    // Q2.14: 0.5
    run_sine(1000.0, 100000.0, 4000);
    meas   = (pk_max - pk_min) / 2.0;
    expect = hmag(1000.0, alpha) * 100000.0 * 0.5;
    $display("    g=0.5  measured %9.1f  expected %9.1f", meas, expect);
    expect_match(meas, expect, 3.0, "g=0.5 must halve the amplitude");

    set_gain_all(16'd16384);   // Q2.14: 1.0                     // 1.0
    run_sine(1000.0, 100000.0, 4000);
    meas   = (pk_max - pk_min) / 2.0;
    expect = hmag(1000.0, alpha) * 100000.0;
    $display("    g=1.0  measured %9.1f  expected %9.1f", meas, expect);
    expect_match(meas, expect, 3.0, "g=1.0 must pass through unchanged");

    // ── 段 6：饱和 ──────────────────────────────────────────────────
    $display("[6] saturation (must clip, must NOT wrap)");
    set_all(24'sd0);
    repeat (300) @(posedge clk);
    begin : sat_blk
      integer mx, mn;
      reg signed [IN_W-1:0] bigv;
      bigv = 24'sd8000000;                       // 接近 2^23
      mx = -(1 << 30); mn = (1 << 30);
      for (i = 0; i < 4000; i = i + 1) begin
        audio_in = {(N_CH*IN_W){1'b0}};
        set_all(i[0] ? bigv : -bigv);
        @(posedge clk);
        if ($signed(ch(0)) > mx) mx = $signed(ch(0));
        if ($signed(ch(0)) < mn) mn = $signed(ch(0));
      end
      $display("    out range [%0d, %0d], OUT_W=%0d bounds [%0d, %0d]",
               mn, mx, OUT_W, -FULL, FULL - 1);
      check(mx <= FULL - 1,  "positive rail must not be exceeded");
      check(mn >= -FULL,    "negative rail must not be exceeded");
      check(mx > 0 && mn < 0,
            "large signal must keep both signs (wrapping would not)");
    end

    // ── 段 7：反证 ──────────────────────────────────────────────────
    $display("[7] negative control: DC_K=9 vs DC_K=0 on the SAME stimulus");
    set_all(24'sd0);
    repeat (400) @(posedge clk);
    set_gain_all(16'd16384);   // Q2.14: 1.0
    run_sine(50.0, 100000.0, 6000);
    begin : neg_blk
      real amp9, amp0, h9, h0;
      amp9 = (pk_max  - pk_min)  / 2.0;
      amp0 = (pk0_max - pk0_min) / 2.0;
      h9   = hmag(50.0, 1.0 - 1.0 / (1 << 9));
      h0   = hmag(50.0, 0.0);
      $display("    DC_K=9  measured %9.1f  analytic %9.1f", amp9, h9 * 1e5);
      $display("    DC_K=0  measured %9.1f  analytic %9.1f", amp0, h0 * 1e5);
      check(amp0 < amp9 * 0.5,
            "DC_K=0 must MEASURE much lower than DC_K=9 (else control is void)");
      expect_match(amp0, h0 * 1e5, 3.0,
                   "DC_K=0 variant must match its own analytic");
      expect_match(amp9, h9 * 1e5, 3.0,
                   "DC_K=9 variant must match its own analytic");
    end

    repeat (100) @(posedge clk);
    if (errors == 0) begin
      $display("PASS: chan align / DC block / gain cal -- %0d cycles", cyc);
      $finish;
    end else begin
      $display("FAIL: %0d error(s) after %0d cycles", errors, cyc);
      $finish;
    end
  end

  initial begin
    #80_000_000;
    $display("FAIL: TB timed out after %0d cycles", cyc);
    $finish;
  end

endmodule
