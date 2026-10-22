// Original PDM/src/pdm_top.v remains unchanged. One-cycle delayed trace
// observes the original 200 MHz domain, including its real sample enables.
module pdm_original_edge_observe(
  input clk_50m,input rst_n,input [3:0] pdm_data,
  output pdm_clk,output led
);
  pdm_top u_ref(.clk_50m(clk_50m),.rst_n(rst_n),.pdm_data(pdm_data),.pdm_clk(pdm_clk),.led(led));
  reg [31:0] cycle_q=0;
  always @(posedge u_ref.clk_200m)
    if(u_ref.rst_internal)cycle_q<=0;
    else cycle_q<=cycle_q+1'b1;
  // [0] raw DATA1, [1] sync1, [2] sync2, [3] CLOCK, [4] L enable,
  // [5] R enable, [6] L PCM valid, [7] R PCM valid, [13:8] half_cnt,
  // [20:14] frac_acc, [21] reset, [37:22] PCM_L, [53:38] PCM_R,
  // [85:54] cycle, [89:86] all raw DATA, [93:90] all synchronized DATA.
  (* DONT_TOUCH="true" *) reg [95:0] edge_trace;
  always @(posedge u_ref.clk_200m) edge_trace <= {2'b0,u_ref.pdm_data_s2,pdm_data,
    cycle_q,u_ref.pcm_0r,u_ref.pcm_0l,u_ref.rst_internal,u_ref.frac_acc,u_ref.half_cnt,
    u_ref.pcm_0r_valid,u_ref.pcm_0l_valid,u_ref.sample_en_r,u_ref.sample_en_l,
    u_ref.pdm_clk_r,u_ref.pdm_data_s2[0],u_ref.pdm_data_s1[0],pdm_data[0]};
  ila_pdm_edge200 u_ila_edge(.clk(u_ref.clk_200m),.probe0(edge_trace));
endmodule
