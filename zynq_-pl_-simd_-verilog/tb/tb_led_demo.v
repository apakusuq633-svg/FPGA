// 裸 PL 路径的验收测试：把**真实的**流水灯固件预装进 ITCM，跑 RTL 仿真，断言核真的按
// 1→2→4 驱动 led_o，并且每转完一圈写一次 TOHOST。
//
// 为什么非要有这一条：scripts/gen_led_demo.py 的 --check 只是 Python 解释器，它证明的是
// "编码自洽"。只有在真 RTL 里跑一遍，才同时证明固件编码、MMIO 译码、ITCM 预装
// （$readmemh 的路径 + 补满 256 字）三者对得上 —— 这是上板前的最后一道关。
//
// 固件用**相对路径**：vvp 的工作目录是仓库根，和 verify.ps1 / run_iverilog.ps1 一致。
// 板级顶层里用的是绝对路径（Vivado 里相对路径解析不可靠），两者出自同一个生成器。
//
// 这条相对路径只对 iverilog 成立。若在 Vivado 里把仿真顶层切成 tb_led_demo，
// $readmemh 会去 xsim 的运行目录找 sw/led_demo_tb.hex 而找不到 —— 那种跑法要自己
// 把路径改成绝对路径，或者干脆用 verify.ps1 / run_iverilog.ps1 跑。
`timescale 1ns/1ps

module tb_led_demo;

  localparam integer MAX_CYCLES = 20000;
  localparam integer WANT_STEPS = 7;   // 3 步一圈，7 步 = 两圈多，心跳至少 2 次

  reg        clk;
  reg        rst_n;
  wire [2:0] led;
  wire       tohost_we;

  integer    errors;
  integer    cycle_count;
  integer    steps;                    // 已经比对过的灯变化次数
  integer    heartbeats;
  reg [2:0]  led_prev;
  reg        tohost_we_q;

  rv32_soc #(
    .DAS_ACTIVE_CHANNELS(8),
    .ITCM_FILE ("sw/led_demo_tb.hex"),
    .LED_WIDTH (3)
  ) u_dut (
    .clk_i          (clk),
    .rst_n_i        (rst_n),
    .test_en_i      (1'b0),
    .halt_i         (1'b0),
    .retire_valid_o (),
    .retire_pc_o    (),
    .retire_instr_o (),
    .retire_fault_o (),
    .tohost_o       (),
    .tohost_we_o    (tohost_we),
    .fromhost_i     (32'b0),
    .led_o          (led),
    .ps_req_i       (1'b0),
    .ps_write_i     (1'b0),
    .ps_sel_i       (1'b0),
    .ps_addr_i      (32'b0),
    .ps_wdata_i     (32'b0),
    .ps_ready_o     (),
    .ps_rdata_o     (),
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

  // 期望序列：单个 1 在 3 位里左移，移出后回到 bit0 —— 即 1,2,4,1,2,4,...
  // 写成函数而不是数组，省得在 always 块里索引数组。
  function [2:0] expected_led;
    input integer n;
    begin
      case (n % 3)
        0:       expected_led = 3'b001;
        1:       expected_led = 3'b010;
        default: expected_led = 3'b100;
      endcase
    end
  endfunction

  always #5 clk = ~clk;

  // 每拍采样：灯值一变就按序比对；TOHOST 写脉冲取上升沿计数
  //（tohost_we_o 是寄存器输出，正常只高一拍，取沿是为了万一它拉长也不会重复计数）。
  always @(posedge clk) begin
    if (rst_n) begin
      cycle_count = cycle_count + 1;

      // 先比再更新标志，顺序反了等于自己把上升沿吃掉（本文件初版就反了，心跳恒 0）。
      if (tohost_we && !tohost_we_q) begin
        heartbeats = heartbeats + 1;
      end
      tohost_we_q = tohost_we;

      if (led !== led_prev) begin
        if (led !== expected_led(steps)) begin
          $display("ERROR: LED step %0d expected %b, got %b (cycle %0d)",
                   steps, expected_led(steps), led, cycle_count);
          errors = errors + 1;
        end
        steps    = steps + 1;
        led_prev = led;
      end
    end
  end

  initial begin
    clk         = 1'b0;
    rst_n       = 1'b0;
    errors      = 0;
    cycle_count = 0;
    steps       = 0;
    heartbeats  = 0;
    tohost_we_q = 1'b0;
    // 从 0 起算：复位后灯是灭的，第一次变化是 0→1，正好对上 expected_led(0)。
    // 若从 X 起算，那个 0 会被当成一次"变化"从而错位。
    led_prev    = 3'b000;

    repeat (8) @(negedge clk);
    rst_n = 1'b1;

    while (steps < WANT_STEPS && cycle_count < MAX_CYCLES) begin
      @(posedge clk);
    end

    if (cycle_count >= MAX_CYCLES) begin
      $display("FAIL: timeout after %0d cycles (%0d LED steps, %0d heartbeats)",
               cycle_count, steps, heartbeats);
      $finish;
    end

    // 先确认观测有效，再断言别的：steps 太少说明固件压根没跑到，
    // 那么上面那些序列比对就是空过的（一条都没比）。
    if (steps < WANT_STEPS) begin
      $display("ERROR: only saw %0d LED steps, expected >= %0d", steps, WANT_STEPS);
      errors = errors + 1;
    end
    if (heartbeats < 2) begin
      $display("ERROR: only saw %0d TOHOST pulses, expected >= 2", heartbeats);
      errors = errors + 1;
    end

    if (errors == 0) begin
      $display("PASS: bare-PL LED demo firmware (%0d cycles, %0d LED steps, %0d heartbeats)",
               cycle_count, steps, heartbeats);
    end else begin
      $display("FAIL: %0d error(s) after %0d cycles", errors, cycle_count);
    end
    $finish;
  end

endmodule
