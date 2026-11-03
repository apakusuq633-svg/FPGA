// 40MHz /16 PDM CLOCK; / (16*DECIM) PCM cadence. No internal PDM clock domain.
// A/B latch 125ns after the respective drive edge, at HOLD=4/CONSUME=12.
// HOLD must precede CONSUME. See docs/pdm_shared_timing.md for conditional budgets.
module rv32_pdm_clkgen #(
  parameter integer HOLD_TICK    = 4,
  parameter integer CONSUME_TICK = 12,
  parameter integer DECIM        = 64
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
  localparam integer DECIM_BITS = $clog2(DECIM);
`ifndef SYNTHESIS
  initial begin
    if (DECIM != 16 && DECIM != 32 && DECIM != 64)
      $fatal(1, "PDM DECIM must be 16, 32 or 64");
  end
`endif

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

  // PDM edges and A/B sampling phases stay identical for all supported rates.
  // DECIM also controls the CIC gain/normalization in rv32_pdm_array_rx.
  assign pdm_clk_o  = div_q[3];
  assign hold_en_o  = en_i & (div_q[3:0] == HOLD_TICK[3:0]);
  assign bit_en_o   = en_i & (div_q[3:0] == CONSUME_TICK[3:0]);
  assign decim_en_o = bit_en_o & (&div_q[DECIM_BITS+3:4]);

endmodule
