// PDM 阵列的 PS 侧采集通路验收：阵列 → chan_align → 采集缓冲 → cfg 窗口。
//
// 两个 DUT，**各自一条 cfg 总线**（共用会互相干扰，第一版就是这么错的）：
//   1. rv32_pdm_capture 单独测（TB 直接喂合成 audio_vec）—— 打包 / 双 bank /
//      序号与丢弃 / 增益寄存器全部逐值核对；
//   2. 整条链（rv32_pdm_array_rx_8ch → rv32_chan_align → rv32_pdm_capture）
//      用真 PDM 位流驱动 —— 证明这条通路真的接上了、而且采到的不是静音。
//
// 七段，每段先证明观测有效再断言：
//   1. 复位后：未使能、没有就绪 bank
//   2. 增益复位值必须是 16384 而不是 0（静音）—— 本仓库踩过的坑，见 029
//   3. 打包：8 通道 × 16 位 → 4 个字，且**丢掉的是低 8 位**（低字节放 0xFF 当探针）
//   4. 双 bank：采满一 bank 自动发布、切到另一个，两个 bank 内容各自正确
//   5. 序号 / 丢弃：ACK 对不上就一直丢，DROP 计数必须跟着涨
//   6. 整链：真 PDM 位流进去，采到的数据非零且在变（证明没被静音吃掉）
//   7. 反证：关掉 EN，帧计数与 pdm_clk 必须一起停
//
// ⚠ 全文不用 SystemVerilog 语法（`16'(...)`、`32'd(...)` 那种）。见 docs/issues/037：
//   iverilog 的 -g2005 会宽容收下 SV，Vivado 直接拒收整个文件，
//   而「TB 全绿」完全掩盖这件事。
//
// ⚠ check 的消息串一律 ASCII。中文串通过 `input [8*160-1:0] msg` 传进 task 会
//   被打散成乱码方块（同一个仓库的 tb_pdm_array_rx 也是这样，只是没注意）——
//   FAIL 了却读不出是哪一条，比没有 FAIL 更费时间。
`timescale 1ns/1ps

module tb_pdm_capture;

  parameter integer N_CH  = 8;
  localparam integer IN_W  = 24;
  localparam integer F_FAW = 4;          // TB 用小深度，跑得快
  localparam integer CAP   = 1 << F_FAW; // 16 帧
  localparam integer WORDS = N_CH / 2;   // 4

  reg clk = 1'b0;
  always #12.5 clk = ~clk;               // 40 MHz
  reg rst_n = 1'b0;

  integer errors = 0, ncheck = 0;
  integer cycle_count = 0;
  always @(posedge clk) cycle_count = cycle_count + 1;

  task check;
    input             cond;
    input [8*160-1:0] msg;
    begin
      ncheck = ncheck + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("  FAIL: %0s  (t=%0t)", msg, $time);
      end
    end
  endtask

  // ── DUT1：纯采集块，自己的 cfg 总线（a*）──────────────────────────────
  reg  [N_CH*IN_W-1:0] av_in;
  reg                  av_valid;
  reg  [31:0]          frame_cnt_in;
  reg  [N_CH-1:0]      frozen_in;

  reg                  awr, ard;
  reg  [6:0]           aaddr;
  reg  [31:0]          awdata;
  wire [31:0]          ardata;
  wire                 cap_en;
  wire [N_CH*16-1:0]   gain_w;

  rv32_pdm_capture #(.N_CH(N_CH), .IN_W(IN_W), .FRAME_AW(F_FAW)) u_cap (
    .clk_i       (clk),
    .rst_n_i     (rst_n),
    .audio_vec_i (av_in),
    .valid_i     (av_valid),
    .frame_cnt_i (frame_cnt_in),
    .frozen_i    (frozen_in),
    .cfg_wr_i    (awr),
    .cfg_rd_i    (ard),
    .cfg_addr_i  (aaddr),
    .cfg_wdata_i (awdata),
    .cfg_rdata_o (ardata),
    .en_o        (cap_en),
    .gain_o      (gain_w)
  );

  // ── DUT2：整条链，另一条 cfg 总线（b*）────────────────────────────────
  reg  [N_CH-1:0]      pdm_din;
  wire                 pdm_clk;
  wire [N_CH*IN_W-1:0] chain_raw, chain_aligned;
  wire                 chain_valid_raw, chain_valid_aligned;
  wire [31:0]          chain_frame_cnt;
  wire [N_CH-1:0]      chain_frozen;
  wire                 chain_en;
  wire [N_CH*16-1:0]   chain_gain;

  reg                  bwr, brd;
  reg  [6:0]           baddr;
  reg  [31:0]          bwdata;
  wire [31:0]          brdata;

  // Scaled startup exercises the real gate; default 50ms is tested separately.
  rv32_pdm_array_rx #(.N_CH(N_CH),.MICS_PER_LINE(1),.MIC_STARTUP_CYCLES(4096)) u_rx (
    .clk_i          (clk),
    .rst_n_i        (rst_n),
    .en_i           (chain_en),
    .pdm_din_i      (pdm_din),
    .pdm_clk_o      (pdm_clk),
    .audio_vec_o    (chain_raw),
    .sample_valid_o (chain_valid_raw),
    .frame_cnt_o    (chain_frame_cnt),
    .frozen_o       (chain_frozen)
  );

  rv32_chan_align #(.N_CH(N_CH), .IN_W(IN_W), .OUT_W(IN_W)) u_align (
    .clk_i       (clk),
    .rst_n_i     (rst_n),
    .en_i        (chain_en),
    .audio_vec_i (chain_raw),
    .valid_i     (chain_valid_raw),
    .gain_q_i    (chain_gain),
    .audio_vec_o (chain_aligned),
    .valid_o     (chain_valid_aligned)
  );

  rv32_pdm_capture #(.N_CH(N_CH), .IN_W(IN_W), .FRAME_AW(F_FAW)) u_chain_cap (
    .clk_i       (clk),
    .rst_n_i     (rst_n),
    .audio_vec_i (chain_aligned),
    .valid_i     (chain_valid_aligned),
    .frame_cnt_i (chain_frame_cnt),
    .frozen_i    (chain_frozen),
    .cfg_wr_i    (bwr),
    .cfg_rd_i    (brd),
    .cfg_addr_i  (baddr),
    .cfg_wdata_i (bwdata),
    .cfg_rdata_o (brdata),
    .en_o        (chain_en),
    .gain_o      (chain_gain)
  );

  // ── cfg 访问 ──────────────────────────────────────────────────────────
  // 写口在时钟沿生效、寄存器在 NBA 区更新，所以写完**必须再等一拍**才能去读
  // 它影响的信号——否则读到的是写之前的值（第一版就是在这里栽的）。
  // ⚠ 所有激励一律在**时钟沿之后 1 ns** 再改，不用阻塞赋值贴着时钟沿写。
  //   贴着沿写会让 DUT 里的组合逻辑（这里是 release_ok 这种连续赋值）与
  //   always 块在同一时刻竞争：always 可能采到**还没重算完**的旧值。
  //   实测现象是 release_ok 在脉冲当中读出来是 1、DUT 却走进了 else 分支
  //   （ack_errors 照样涨）。这类竞争在波形上极难看出来，在 TB 上避开最省事。
  task cfg_write;
    input [6:0]  a;
    input [31:0] d;
    begin
      @(posedge clk); #1;
      awr = 1'b1; aaddr = a; awdata = d;
      @(posedge clk); #1;
      awr = 1'b0;
      @(posedge clk);
    end
  endtask

  task cfg_read;
    input  [6:0]  a;
    output [31:0] d;
    begin
      @(posedge clk); #1;
      aaddr = a; ard = 1'b1;
      #1 d = ardata;
      @(posedge clk); #1;
      ard = 1'b0;
    end
  endtask

  task ccfg_write;
    input [6:0]  a;
    input [31:0] d;
    begin
      @(posedge clk); #1;
      bwr = 1'b1; baddr = a; bwdata = d;
      @(posedge clk); #1;
      bwr = 1'b0;
      @(posedge clk);
    end
  endtask

  task ccfg_read;
    input  [6:0]  a;
    output [31:0] d;
    begin
      @(posedge clk); #1;
      baddr = a; brd = 1'b1;
      #1 d = brdata;
      @(posedge clk); #1;
      brd = 1'b0;
    end
  endtask

  task read_word;                        // DUT1
    input  integer bank;
    input  integer idx;
    output [31:0]  d;
    begin
      cfg_write(7'd3, bank);
      cfg_write(7'd7, idx);
      repeat (2) @(posedge clk);         // BRAM 同步读口
      cfg_read(7'd8, d);
    end
  endtask

  task push_sample;
    input integer n;
    integer c;
    begin
      for (c = 0; c < N_CH; c = c + 1)
        // 高 16 位 = 期望被采到的值；低 8 位 = 0xFF 探针，证明低字节被丢掉
        av_in[c*IN_W +: IN_W] = {(16'h1000 + n*N_CH + c), 8'hFF};
      frame_cnt_in = n;
      @(posedge clk); #1;
      av_valid = 1'b1;
      @(posedge clk); #1;
      av_valid = 1'b0;
      repeat (WORDS + 2) @(posedge clk);
    end
  endtask

  // ── 8 通道 LFSR 位流 ──────────────────────────────────────────────────
  // 周期远大于 64。0101 那类周期 64 的会被 CIC 的零点抹平成常数，
  // 过不了 chan_align 的直流阻断，反证不出「数据在变」。
  reg [15:0] lfsr [0:N_CH-1];
  reg        pdm_d;
  wire       ev_fall = pdm_d & ~pdm_clk;
  integer    g;
  always @(posedge clk) pdm_d <= pdm_clk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (g = 0; g < N_CH; g = g + 1) lfsr[g] <= 16'hBEEF ^ (g * 16'h0111);
    end else if (chain_en && ev_fall) begin
      for (g = 0; g < N_CH; g = g + 1)
        lfsr[g] <= {lfsr[g][14:0], lfsr[g][15] ^ lfsr[g][13] ^ lfsr[g][12] ^ lfsr[g][10]};
    end
  end
  always @* begin
    for (g = 0; g < N_CH; g = g + 1) pdm_din[g] = lfsr[g][15];
  end

  // ── 主流程 ────────────────────────────────────────────────────────────
  integer    i, k, n, mism, nz, changes;
  reg [31:0] d, d2, d3, prev;
  reg [31:0] wd;
  reg [31:0] bankw [0:WORDS*CAP-1];

  initial begin
    av_in = 0; av_valid = 0; frame_cnt_in = 0; frozen_in = 0;
    awr = 0; ard = 0; aaddr = 0; awdata = 0;
    bwr = 0; brd = 0; baddr = 0; bwdata = 0;
    mism = 0; nz = 0; changes = 0; prev = 32'hdeadbeef;

    // ── 1. 复位后 ───────────────────────────────────────────────────────
    $display("== 1. reset state");
    #200;
    cfg_read(7'd0, d);
    check(d[0] === 1'b0, "reset: EN must be 0");
    check(d[1] === 1'b0, "reset: CAPTURE must be 0");
    check(cap_en === 1'b0, "reset: en_o must be 0");
    cfg_read(7'd1, d);
    check(d[1:0] === 2'b00, "reset: no bank ready");
    $display("   CTRL=%08x STATUS=%08x, not enabled, no bank ready", 32'h0, d);

    // ── 2. 增益复位值 ───────────────────────────────────────────────────
    $display("== 2. gain reset value (must not be mute)");
    for (k = 0; k < N_CH; k = k + 1)
      check(gain_w[k*16 +: 16] === 16'd16384,
            "gain reset must be 16384 (unity Q2.14), not 0");
    cfg_read(7'd16, d);
    check(d[15:0] === 16'd16384, "gain readback even ch must be 16384");
    check(d[31:16] === 16'd16384, "gain readback odd ch must be 16384");
    $display("   gain[0..7] all read back 16384 (not 0, not mute)");

    // ── 3. 打包 ─────────────────────────────────────────────────────────
    $display("== 3. frame packing (low 8 bits must be dropped)");
    rst_n = 1'b0; #100; rst_n = 1'b1;
    cfg_write(7'd0, 32'h0000_0003);       // EN=1, CAPTURE=1
    cfg_write(7'd3, 32'd0);               // SELECT = bank0
    for (n = 0; n < 3; n = n + 1) push_sample(n);
    cfg_read(7'd4, d);
    check(d === 32'd0, "SEQ must not move before CAP frames");
    cfg_read(7'd1, d);
    check(d[1:0] === 2'b00, "no bank ready before CAP frames");
    for (n = 3; n < CAP; n = n + 1) push_sample(n);
    cfg_read(7'd1, d);
    check(d[0] === 1'b1, "bank0 must be ready after CAP frames");
    cfg_read(7'd4, d);
    // 序号是**发布当时**的计数值，不是发布后的：seq0_q <= sequence_q（旧值 0），
    // 同一拍 sequence_q 才 +1。所以第一个 bank 读出来是 0，第二个是 1。
    check(d === 32'd0, "first published bank carries SEQ 0 (pre-increment value)");

    for (n = 0; n < CAP; n = n + 1) begin
      for (k = 0; k < WORDS; k = k + 1) begin
        read_word(0, n*WORDS + k, wd);
        bankw[n*WORDS + k] = wd;
      end
    end
    mism = 0;
    for (n = 0; n < CAP; n = n + 1) begin
      for (k = 0; k < WORDS; k = k + 1) begin
        if (bankw[n*WORDS+k][15:0]  !== (16'h1000 + n*N_CH + 2*k))   mism = mism + 1;
        if (bankw[n*WORDS+k][31:16] !== (16'h1000 + n*N_CH + 2*k+1)) mism = mism + 1;
      end
    end
    check(mism == 0, "capture must take the HIGH 16 bits (0xFF probe must not leak)");
    $display("   %0d frames x %0d ch checked, %0d mismatches", CAP, N_CH, mism);
    $display("   e.g. frame3 word0 = %08x (expect 1018/1019)", bankw[3*WORDS]);

    // ── 4. 双 bank 与回收 ───────────────────────────────────────────────
    $display("== 4. dual bank and recycle");
    // bank 选择规则是「挑一个空闲的」，两块都空闲时**优先 bank0**（!available[0]）。
    // 所以要让第二段落进 bank1，前提是 bank0 还占着 —— 先不释放，继续灌。
    for (n = CAP; n < 2*CAP; n = n + 1) push_sample(n);
    cfg_read(7'd1, d);
    check(d[1:0] === 2'b11, "with bank0 still held, the second run must land in bank1");
    mism = 0;
    for (n = 0; n < CAP; n = n + 1) begin
      for (k = 0; k < WORDS; k = k + 1) begin
        read_word(1, n*WORDS + k, wd);
        if (wd[15:0]  !== (16'h1000 + (n+CAP)*N_CH + 2*k))   mism = mism + 1;
        if (wd[31:16] !== (16'h1000 + (n+CAP)*N_CH + 2*k+1)) mism = mism + 1;
      end
    end
    check(mism == 0, "bank1 contents must match the second run sample index");
    $display("   both banks published; bank1 %0d frames checked, %0d mismatches", CAP, mism);

    // 序号：bank1 的序号 = 发布它时的计数值（1，同样是 +1 之前的）
    cfg_write(7'd3, 32'd1);               // SELECT = bank1
    cfg_read(7'd4, d);
    check(d === 32'd1, "bank1 carries SEQ 1");
    cfg_write(7'd3, 32'd0);               // 回到 bank0

    // 回收 bank0：ACK 对上它自己的序号（0）
    cfg_write(7'd9, 32'd0);
    cfg_write(7'd10, 32'd1);
    cfg_read(7'd1, d);
    check(d[0] === 1'b0, "RELEASE with matching ACK must clear bank0 ready");
    check(d[1] === 1'b1, "RELEASE must not touch the other bank");
    $display("   bank0 released, bank1 untouched (READY=%b)", d[1:0]);

    // ── 5. 序号与丢弃 ───────────────────────────────────────────────────
    $display("== 5. sequence / drop");
    cfg_read(7'd6, d2);
    cfg_write(7'd9, 32'd99);              // 故意给错的 ACK_SEQ
    cfg_write(7'd10, 32'd1);              // RELEASE 会被拒
    cfg_write(7'd0, 32'h0000_0003);       // 重开纪元（两个 bank 都作废）
    // 要送**多于 2×CAP** 个样点才会真丢：前 2×CAP 个正好把两个 bank 填满并发布
    // （两边都没释放），第 3 段才无处可去。第一版只送 2×CAP，DROP 当然是 0 ——
    // 那是 TB 算错了，不是 DROP 没接上。
    for (n = 0; n < 3*CAP; n = n + 1) push_sample(n + 100);
    cfg_read(7'd6, d3);
    check(d3 === CAP, "DROP must count exactly the CAP samples that had nowhere to go");
    cfg_read(7'd11, d);
    check(d === (100 + 3*CAP - 1), "FRAME_CNT must pass through the last fed frame number");
    $display("   both banks stuck, DROP went %0d -> %0d (expected %0d samples)",
             d2, d3, CAP);

    // ── 6. 整链 ─────────────────────────────────────────────────────────
    $display("== 6. full chain (array -> chan_align -> capture)");
    rst_n = 1'b0; #100; rst_n = 1'b1;
    ccfg_write(7'd0, 32'h0000_0003);      // EN=1, CAPTURE=1
    check(chain_en === 1'b1, "en_o must rise after CTRL write (it drives the chain)");
    k = 0;
    while (chain_frame_cnt < (CAP + 4) && k < 200000) begin
      @(posedge clk); k = k + 1;
    end
    check(k < 200000, "chain must produce CAP+4 samples within the limit");
    repeat (8) @(posedge clk);
    ccfg_read(7'd1, d);
    check(d[0] === 1'b1 || d[1] === 1'b1, "chain must publish at least one bank");
    ccfg_write(7'd3, 32'd0);
    ccfg_write(7'd7, 32'd0);
    repeat (2) @(posedge clk);
    ccfg_read(7'd8, prev);
    nz = 0; changes = 0;
    for (k = 1; k < WORDS*CAP; k = k + 1) begin
      ccfg_write(7'd7, k);
      repeat (2) @(posedge clk);
      ccfg_read(7'd8, d3);
      if (d3 !== 32'd0) nz = nz + 1;
      if (d3 !== prev)  changes = changes + 1;
      prev = d3;
    end
    check(nz > 0, "chain capture must not be all zero (all zero = gain muted)");
    check(changes > 0, "chain capture must vary under LFSR (constant = not connected)");
    check(chain_frozen === 8'b0, "LFSR keeps moving, frozen must stay low");
    $display("   bank0: %0d of %0d words non-zero, %0d transitions", nz, WORDS*CAP, changes);

    // ── 7. 反证：关掉 EN ────────────────────────────────────────────────
    $display("== 7. counterexample: EN off must stop capture");
    ccfg_write(7'd0, 32'h0000_0002);      // EN=0, CAPTURE=1
    check(chain_en === 1'b0, "EN must really drop after CTRL write");
    repeat (300) @(posedge clk);
    // EN 拉低后阵列的帧计数是**被清零**（不是冻结在最后一个值）——
    // rv32_pdm_array_rx 在 !en_i 那一支明确写 frame_cnt_q <= 0。
    // 所以判据是「归零且不再动」，不是「停在原处」。
    check(chain_frame_cnt === 32'd0, "frame counter must clear to 0 when EN=0");
    check(pdm_clk === 1'b0, "pdm_clk must sit low when EN=0");
    $display("   with EN=0 frame counter cleared to %0d, pdm_clk low", chain_frame_cnt);

    $display("");
    if (errors == 0) $display("PASS: tb_pdm_capture all %0d checks passed (%0d cycles)", ncheck, cycle_count);
    else             $display("FAIL: tb_pdm_capture %0d of %0d checks failed", errors, ncheck);
    $finish;
  end

endmodule
