// Original PDM_48K top and acquisition RTL remain unchanged.
// Added synchronous observation only; trace is delayed one 40 MHz cycle.
module pdm_reference_observe(
  input clk_50m, input rst_n, input [3:0] pdm_data,
  output pdm_clk, output led
);
  pdm_top u_ref(.clk_50m(clk_50m),.rst_n(rst_n),.pdm_data(pdm_data),
                .pdm_clk(pdm_clk),.led(led));
  wire clk = u_ref.clk_40m;
  wire valid = u_ref.sample_valid;
  wire [127:0] pcm = u_ref.pcm_vec;
  wire [31:0] frame = u_ref.frame_cnt;
  wire [7:0] frozen = u_ref.frozen;
  wire [3:0] b_bits = {u_ref.u_rx.g_line[3].g_phase_b.u_cic_b.bit_q,
    u_ref.u_rx.g_line[2].g_phase_b.u_cic_b.bit_q,
    u_ref.u_rx.g_line[1].g_phase_b.u_cic_b.bit_q,
    u_ref.u_rx.g_line[0].g_phase_b.u_cic_b.bit_q};
  reg [31:0] cycle_q = 0;
  always @(posedge clk)
    if (u_ref.rst_internal) cycle_q <= 0;
    else cycle_q <= cycle_q+1'b1;
  // Low 64: cycle[63:32], accumulator low14[31:18], B FF[17:14],
  // held A[13:10], quarter[9:8], valid[7], consume[6], hold[5],
  // pad clock[4], DATA[3:0]. Frame[95:64], PCM16x8[223:96].
  (* DONT_TOUCH="true" *) reg [223:0] ref_trace;
  always @(posedge clk) ref_trace <= {pcm,frame,cycle_q,
    u_ref.u_rx.u_clkgen.phase_acc_q[13:0],b_bits,u_ref.u_rx.phase_a_q,
    u_ref.u_rx.u_clkgen.quarter_q,valid,u_ref.u_rx.bit_en_w,
    u_ref.u_rx.hold_en_w,pdm_clk,pdm_data};
  ila_reference_raw u_ila_raw(.clk(clk),.probe0(ref_trace));
  ila_reference_pcm u_ila_pcm(.clk(clk),.probe0(pcm),.probe1(valid),
    .probe2(frame),.probe3(frozen));
endmodule
