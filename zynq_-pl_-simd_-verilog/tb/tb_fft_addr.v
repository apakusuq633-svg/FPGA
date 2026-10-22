// VFFT 地址发生器的验证 —— 9 级 2304 个蝶形，逐拍对着 Python 枚举比。
//
// 这是整个 FFT 加速里**最该先验**的一块：数据通路写错了通常会得到一个明显
// 荒唐的数，而地址写错会得到一个"看起来像频谱的东西"，要拿它跟 golden 比
// 才能发现 —— 那时已经很难分清是地址错还是蝶形算错。
//
// 参照：build/fft_addr_ref.hex，每拍 9 行
//   行 0  {stage[3:0], grp[5:0], ph[1:0], wb[8:0], wa[8:0]}
//   行 1-8 {al[2:0], bl[2:0], tw[9:0]}，未用的补 0
`timescale 1ns/1ps

module tb_fft_addr;

  localparam integer NCYC = 384;        // 6 级 × 32 + 3 级 × 64

  reg  [3:0]  stage;
  reg  [6:0]  cyc;
  wire [3:0]  nbf;
  wire [8:0]  wa, wb;
  wire [8*3-1:0]  al, bl;
  wire [8*10-1:0] tw;

  rv32_fft_addr u_dut (
    .stage_i (stage),
    .cyc_i   (cyc),
    .nbf_o   (nbf),
    .wa_o    (wa),
    .wb_o    (wb),
    .al_o    (al),
    .bl_o    (bl),
    .tw_o    (tw)
  );

  // 参照：每拍 9 行
  reg [31:0] ref [0:NCYC*9-1];

  integer errors = 0;
  integer i, j, line, n_bf_seen;
  reg [31:0] hdr;
  reg [8:0]  exp_wa, exp_wb;
  reg [3:0]  exp_stage;
  integer    exp_nbf;
  reg [2:0]  e_al, e_bl;
  reg [9:0]  e_tw;

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

  integer c;
  initial begin
    $display("=== tb_fft_addr ===");
    $readmemh("build/fft_addr_ref.hex", ref);

    n_bf_seen = 0;
    for (c = 0; c < NCYC; c = c + 1) begin
      line = c * 9;
      // 包头打包：{stage[3:0], grp[5:0], ph[1:0], wb[8:0], wa[8:0]}
      hdr  = ref[line];
      exp_stage = hdr[31:28];
      exp_wb    = hdr[17:9];
      exp_wa    = hdr[8:0];
      exp_nbf   = (exp_stage >= 4'd3) ? 8 : 4;

      // 还原 cyc：mode8 时 cyc = grp；mode4 时 cyc = grp*2 + ph
      stage = exp_stage;
      cyc   = (exp_stage >= 4'd3) ? {1'b0, hdr[26:22]}
                                  : {hdr[26:22], hdr[20]};
      #1;                                  // 组合稳定

      check(nbf === exp_nbf[3:0], "nbf 不对");
      check(wa  === exp_wa,        "窗口 A 基址不对");
      if (exp_nbf == 8) check(wb === exp_wb, "窗口 B 基址不对");

      for (j = 0; j < 8; j = j + 1) begin
        e_al = ref[line + 1 + j][15:13];
        e_bl = ref[line + 1 + j][12:10];
        e_tw = ref[line + 1 + j][9:0];
        if (j < exp_nbf) begin
          if (al[j*3 +: 3] !== e_al) begin
            errors = errors + 1;
            $display("  FAIL: 拍 %0d lane %0d 的 a 偏移 实测 %0d 期望 %0d",
                     c, j, al[j*3 +: 3], e_al);
          end
          if (bl[j*3 +: 3] !== e_bl) begin
            errors = errors + 1;
            $display("  FAIL: 拍 %0d lane %0d 的 b 偏移 实测 %0d 期望 %0d",
                     c, j, bl[j*3 +: 3], e_bl);
          end
          if (tw[j*10 +: 10] !== e_tw) begin
            errors = errors + 1;
            $display("  FAIL: 拍 %0d lane %0d 的 twiddle 实测 %0d 期望 %0d",
                     c, j, tw[j*10 +: 10], e_tw);
          end
          n_bf_seen = n_bf_seen + 1;
        end
      end
    end

    $display("  %0d 拍，%0d 个蝶形（期望 %0d）", NCYC, n_bf_seen, 9 * 256);
    check(n_bf_seen == 9 * 256, "蝶形总数必须是 9 级 × 256");

    if (errors == 0) begin
      $display("PASS: VFFT 地址发生器与 Python 枚举逐拍一致（384 拍 / 2304 个蝶形）");
      $finish;
    end else begin
      $display("FAIL: %0d error(s)", errors);
      $finish;
    end
  end

endmodule
