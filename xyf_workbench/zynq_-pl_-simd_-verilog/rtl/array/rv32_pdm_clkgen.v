// 40MHz /16 PDM CLOCK; /1024 PCM cadence. No internal PDM clock domain.
// A/B latch 125ns after the respective drive edge, at HOLD=4/CONSUME=12.
// HOLD must precede CONSUME. See docs/pdm_shared_timing.md for conditional budgets.
module rv32_pdm_clkgen #(
  parameter integer HOLD_TICK    = 4,
  parameter integer CONSUME_TICK = 12
) (
  input  clk_i,
  input  rst_n_i,
  input  en_i,
  output pdm_clk_o,
  output hold_en_o,
  output bit_en_o,
  output decim_en_o
);

  reg [9:0] div_q;

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      // 停用即归零：使能前时钟输出恒 0，
      // 上板判据才是确定的「使能前不动、使能后在跳」。
      div_q <= 10'b0;
    end else if (!en_i) begin
      div_q <= 10'b0;
    end else begin
      div_q <= div_q + 1'b1;
    end
  end

  // 抽取比 64 与 fs=clk/1024 是同一件事的两面，抽头位置写死。
  // 不设 DECIM 参数：一个改不动的参数比没有参数更误导。
  assign pdm_clk_o  = div_q[3];
  assign hold_en_o  = en_i & (div_q[3:0] == HOLD_TICK[3:0]);
  assign bit_en_o   = en_i & (div_q[3:0] == CONSUME_TICK[3:0]);
  assign decim_en_o = bit_en_o & (div_q[9:4] == 6'd63);

endmodule
