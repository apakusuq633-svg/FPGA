// 声学 DSP 扩展指令的执行体 —— rv32_defines.vh 里那四条（VCMUL/VPHAT/VSUB/VRED2）
// 一直只有编码没有单元，这个模块把它们补上。
//
// ══ 与 SIMD-MAC 阵列（rv32_vec_unit）的分工 ═══════════════════════════════
// 阵列是**实数**的 8 lane MAC，延迟线按样本下标分 bank —— 适合 FIR / NLMS /
// 波束形成这类「一路信号 × 一组系数」的形状。
// 声学扩展是**复数**的、操作数是整段频谱 —— 适合 FFT 之后的互谱、白化、归约。
// 两者的数据布局完全不同，所以**并存**、各用各的存储，不去改造阵列内部
// （阵列的 bank 划分是为 8-lane 抽头映射特化的，动它等于重写那个模块）。
//
// ══ 数据布局 ═════════════════════════════════════════════════════════════
// 三条 512 条复数的存储，每条 2 KB，复数按 {im[31:16], re[15:0]} 打包成一个字：
//     X  操作数 1（通常是 X_i 的频谱）      Y  操作数 2      Z  结果
// 用分布式 RAM（LUTRAM）推断：512×32 不大，而且 VPHAT 要 LANES 个读口。
// `ram_style` 写死 distributed，避免综合器猜成 block 之后读口不够、静默复制。
//
// ⚠ **装载是这个设计的软肋**：靠核一条 PUSH 灌一条复数，512 条 × 2 个 bank
//   = 1024 条指令、每条约 2 拍，光搬运 2000 拍就吃掉一大半收益。
//   真正的解法是给这个单元一个直接读 DTCM 的口（DMA 式），那是 SoC 层改动。
//   实测数字见 docs/issues/036 —— **先把它量出来，再决定要不要动 SoC**。
//
// ══ 指令编码（instr[31] 是唯一空闲位，这里用满）══════════════════════════
//     funct3=100  instr[31]=0  VCMUL   Z = X · Y          逐点复数乘
//     funct3=100  instr[31]=1  PUSHA   X[ptr++] = rs1
//     funct3=101  instr[31]=0  VPHAT   Z = Z/|Z| · 限带    白化
//     funct3=101  instr[31]=1  PUSHB   Y[ptr++] = rs1
//     funct3=110  instr[31]=0  VSUB    Z = X · conj(Y)     互谱
//     funct3=110  instr[31]=1  POP     rd = Z[ptr++]
//     funct3=111  instr[31]=0  VRED2   rd = {ΣIm X, ΣRe X} 对偶归约
//     funct3=111  instr[31]=1  保留（当前等同 NOP，done 一拍就回）
//
// ══ 握手 ═════════════════════════════════════════════════════════════════
// 照抄 rv32_vec_unit / rv32_div_unit 的多拍单元协议：
//   start_i 电平，只在 IDLE 采；stall_o 在 RUN/DRAIN 为高（核靠它冻结流水、
//   压掉 EX/MEM 的 valid）；done_o 一拍、result_o 当拍有效；keep_i 拉低 = 冲刷，
//   回 IDLE 且不写任何存储；commit_i 表示结果真被收下，才回 IDLE。
//
// ⚠ PUSHA/PUSHB/POP 是**有副作用**的（指针自增、写存储），在 start 那一拍就发生，
//   和阵列的 VPUSH 一样。trap 来袭时核必须把 start 一起压住。
//
// ══ lane 数 ══════════════════════════════════════════════════════════════
// LANES = 每拍处理几条复数，乘法器数 = LANES × 4。默认 8（32 个乘法器）。
//
// ⚠ 这条注释原先写「约占 Zynq-7010 的 80 个 DSP48 的四成」。**器件已换成 7z020，
//   DSP48 是 220 个**，同样的 32 个乘法器现在只占约 15%。**但那个四成的数字本来
//   也只是估算，从来没有实测过**（synth_design 本机崩溃，见 docs/issues/039）——
//   换器件不改变「这是估的不是量的」这件事。
//
// Supported configurations: 4/8/16 lanes; cache addressing follows the lane count.
// Sixteen readers can dissolve input LUTRAM; compare routed resources before use.
module rv32_acoustic_ext #(
  parameter integer LANES = 8
) (
  input                clk_i,
  input                rst_n_i,
  input                start_i,
  input                keep_i,
  input                commit_i,
  input  [2:0]         op_i,        // 0=VCMUL 1=VPHAT 2=VSUB 3=VRED2 4=NOP
  input                is_io_i,     // instr[31]：1 = PUSH/POP 那一类
  input  [1:0]         io_sel_i,    // 00=PUSHA 01=PUSHB 1x=POP
  input  [31:0]        scalar_i,    // PUSH 的数据（rs1）
  output               stall_o,
  output               done_o,
  output [31:0]        result_o,
  output               io_ready_o
);

  // ══ 只搬带内：这是最大的一笔省钱 ═══════════════════════════════════════
  // PHAT 的工作带是 200 Hz..8 kHz（fs=39.0625k、N=1024 ⇒ bin 6..209），带外
  // **注定要被清 0**（README §0.3.4 第 1 条：全带白化会把定位误差从 0.85
  // 恶化到 5.32 cm）。既然带外不留，就**没有理由把它搬进搬出**。
  //
  // 所以存储只放带内那一段，序号 0 对应原来的 bin 6：
  //     存储下标 j  ⇔  频谱 bin (j + 6)
  // 208 = 26 趟 × 8 lane（比 204 补到 8 的整数倍；补出来的 4 条落在带外，
  // VPHAT 会把它们清 0，无害）。
  //
  // ⚠ 这个「6」和 fw_gcc.c 的 BAND_LO_BIN、fw_acou_model.py 的 BAND_LO 是
  //   同一个常量，改一处必须四处一起改（对照 docs/issues/019）。
  localparam integer CN    = 208;                 // 只放带内：208 条（204 条有效）
  localparam integer CW    = 32;
  localparam integer NW    = LANES;
  localparam integer NPASS = CN / NW;             // 26 趟
  localparam integer LB    = $clog2(LANES);
  localparam integer NIDX  = 8;                   // $clog2(208)
  localparam integer PW    = $clog2(NPASS);        // 4 lanes need 52 passes
  localparam [PW-1:0] LAST_PASS = NPASS - 1;

  // 存储内序号下的带内上下界：原 bin 6..209 → 存储 0..203
  parameter integer BAND_LO = 0;
  parameter integer BAND_HI = 203;

  localparam [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DRAIN = 2'd2, ST_DONE = 2'd3;

  (* ram_style = "distributed" *) reg [CW-1:0] mx [0:CN-1];
  (* ram_style = "distributed" *) reg [CW-1:0] my [0:CN-1];
  // `mz` **不在这里** —— 它按 lane 分成了 8 个 bank，见下面 `g_mzb` 那一段
  // （每拍要写 8 个不同字 ⇒ 8 个写口 ⇒ 分布式 RAM 只有一个写口，整块会 dissolve）。

  reg [1:0]    state_q;
  reg [2:0]    op_q;
  reg          is_io_q;
  reg [1:0]    io_sel_q;
  reg [PW-1:0] pass_q;
  reg [NIDX:0] ptr_q;                      // 指针，到 CN-1 显式回绕
  reg [15:0]   acc_re_q, acc_im_q;

  // ── VPHAT 的三级流水（2026-10-02 加）─────────────────────────────────
  // 为什么必须拆：实测 40 MHz（25 ns）下 VPHAT 那条路 **30.9 ns / 30 级逻辑 / 65% 是布线**，
  // 是 `place_design` 之后 9,762 个失效端点里 **86%** 的来源（最差 2000 条路径里占 1,715 条）。
  // 拆之前先试过"布线后补一遍 phys_opt"（issues/025 那条配方，当时 −0.413 → 转正），
  // **这次工具直接拒了**：
  //   [Physopt 32-745] ... highly unlikely that slack will be improved.
  //   Post-Route Physical Optimization is most effective when WNS is above -0.5ns
  // 只挪了 0.08 ns。所以这不是摆位问题，是**逻辑深度本身超了**。
  //
  // 原来一条链在**一拍**里全串完：
  //     mz[a] 组合读(208:1) → mag_approx → recip_q14(16 位优先编码器+两次变址移位) → 复乘 → 写回
  // 现在摊到三拍（算术、取整、LUT 值一个都没改，只换了时序）：
  //     vph_q=0  读 mz + mag_approx        → mag_q / zr_q / zi_q / aidx_q / act_q
  //     vph_q=1  recip_q14(mag_q)          → zinv_q
  //     vph_q=2  复乘 + 带内门控 → 写回 mz[aidx_q]
  // ⚠ 中间量必须寄存：**a 也要寄存**（aidx_q），否则第 2 拍用当下的 base 会写错地址。
  // 代价：VPHAT 从 26 拍变 78 拍（+52）。相对整条链的 1278 拍可以忽略。
  reg [1:0]        vph_q;
  reg [15:0]       mag_q  [0:LANES-1];
  reg signed [15:0] zr_q  [0:LANES-1];
  reg signed [15:0] zi_q  [0:LANES-1];
  reg [NIDX-1:0]   aidx_q [0:LANES-1];
  reg              act_q  [0:LANES-1];
  reg [15:0]       zinv_q [0:LANES-1];
  reg [4:0]        zexp_q [0:LANES-1];

  // ══ 单拍 PUSH/POP ═════════════════════════════════════════════════════
  // PUSH 本质只是一次寄存器写，**没有理由冻流水**。旧版走多拍协议的
  // start/done/commit（3 拍），光搬运就 4608 拍，把运算省的 113× 全吃回去
  // （见 docs/issues/036）。现在**一条 PUSH/POP = 1 拍**。
  //
  // ⚠ 判据用 **commit_i**，不是 start 的上升沿。
  //   start 是电平（指令停在 ID/EX 多久就拉多久），而核可能因 memory_stall
  //   多冻几拍。用上升沿检测的话，**连续背靠背的 PUSH 会被吃掉**：start 一直
  //   为高时只有第一条能发出去（第二条没有"沿"）。
  //   用 commit_i（= ex_stage_valid & ~halt_i，"这条指令正被 EX/MEM 收下"）
  //   则两边都对：
  //     · 不被冻 → 每拍一条，背靠背 1 拍一条 ✓
  //     · 被冻住 → 那几拍 commit=0，副作用不发生；解冻那拍刚好发生一次 ✓
  //   核那边已经把 `start` 与 `~trap_taken` 相与（见 rv32_core.v），
  //   所以被冲刷的指令不会误触发。
  wire io_fire = (state_q == ST_IDLE) & start_i & is_io_i & commit_i;
  assign io_ready_o = state_q == ST_IDLE;

  // POP 的读数据取**自增前**的指针，组合给出 —— 单拍通路上指针在边沿才更新。
  wire [NIDX-1:0] ptr_idx = ptr_q[NIDX-1:0];
  // pop_rdata is selected by the low LB pointer bits after banking.

  // ── PUSH 的落盘：**单独一个不带复位的 always** ────────────────────────
  // ⚠ 这一块**不能合进下面那个 FSM 的 always**。那个块敏感表里有
  //   `negedge rst_n_i`，而分布式 RAM **没有复位端** —— 工具看到"这个块有异步复位"
  //   就要求数组也能被复位，做不到就把整块 dissolve 成触发器 + 多路选择。
  //   实测（build/probe_ram_shape.v，同尺寸对照）：
  //     m1 裸 `if (we)` 写、无复位     → LUTRAM=1792 ✓
  //     m2 深度用 localparam 表达式     → LUTRAM=1792 ✓（声明写法不是问题）
  //     m3 写嵌在带异步复位的 FSM 里     → LUTRAM=**0**、FF=480 ✗
  //   代价实测：`u_acoustic_ext` 一个模块 21,417 LUT = **全 PL 的 54%**（issues/060）。
  wire mx_push = io_fire & (io_sel_i == 2'b00);
  wire my_push = io_fire & (io_sel_i == 2'b01);
  always @(posedge clk_i) begin
    if (mx_push) mx[ptr_idx] <= scalar_i;
    if (my_push) my[ptr_idx] <= scalar_i;
  end

  wire [NIDX-1:0] base = pass_q * NW[NIDX-1:0];

  // ── 每 lane 的复数乘 ─────────────────────────────────────────────────
  // 乘法器 = LANES × 4。VSUB 与 VCMUL 共用这组乘法器，差别只在 bi 的符号 ——
  // 见下面的 bi_eff。这样不会为了「共轭」多长一倍乘法器。
  wire signed [15:0] ar_w [0:LANES-1];
  wire signed [15:0] ai_w [0:LANES-1];
  wire signed [15:0] br_w [0:LANES-1];
  wire signed [16:0] bi_w [0:LANES-1];
  wire signed [31:0] pr_w [0:LANES-1];
  wire signed [31:0] pi_w [0:LANES-1];

  // ── 每个 lane 的读地址与 mx/my 的读数据：**只声明一次** ────────────────
  // ⚠ 这不是"顺手整理"，是修一个让整个模块装不下的缺陷。
  //
  // `mx` 原来被读了**两遍**：复数乘那 8 个 lane 一遍、VRED2 归约那 8 个 lane 再一遍。
  // 综合器把它们当成 **1 写 + 16 读 = 17 个口**，而分布式 RAM 的上限是 **16 个口**，
  // 于是整块退回触发器 + 多路选择。实测（`build/probe_ram_ports.tcl`，同尺寸对照）：
  //     1 写 +  8 读 → LUTRAM=1792 ✓
  //     1 写 + 16 读 → dissolved ✗（`RAM has too many ports (16)`）
  //     深度 208（非 2 的幂）**不是问题** —— 208 与 256 都推得出来 ✓
  //
  // 而那两组的读地址**完全相同**（都是 `base + k`），本来就是同一个口：
  // 共用一根地址线即可，不损失任何功能。实测该模块 LUT 26,455 → 见 docs/issues/060。
  genvar g;
  wire [NIDX-1:0] lane_a [0:LANES-1];
  wire [31:0]     mx_rd  [0:LANES-1];
  wire [31:0]     my_rd  [0:LANES-1];
  generate
    for (g = 0; g < LANES; g = g + 1) begin : g_lane_a
      assign lane_a[g] = base + g[NIDX-1:0];
      assign mx_rd[g]  = mx[lane_a[g]];
      assign my_rd[g]  = my[lane_a[g]];
    end
  endgenerate

  generate
    for (g = 0; g < LANES; g = g + 1) begin : g_lane
      assign ar_w[g] = mx_rd[g][15:0];
      assign ai_w[g] = mx_rd[g][31:16];
      assign br_w[g] = my_rd[g][15:0];
      // VSUB 要对 Y 取共轭 —— 只翻虚部的符号，不另加乘法器
      assign bi_w[g] = (op_q == 3'd2) ? -$signed({my_rd[g][31],my_rd[g][31:16]}) :
                                               $signed({my_rd[g][31],my_rd[g][31:16]});
      assign pr_w[g] = ar_w[g] * br_w[g] - ai_w[g] * bi_w[g];
      assign pi_w[g] = ar_w[g] * bi_w[g] + ai_w[g] * br_w[g];
    end
  endgenerate

  // 两个标度各写一个函数，**不要合并**：Q15×Q15 = Q30 要 >>15，
  // Q15×Q14 = Q29 要 >>14。抄成同一个的话白化结果会整体差 2 倍，
  // 而且看着仍然"像白化过的"（幅度平坦），极难发现。
  function [15:0] q30_to_q15;                // 复数乘用
    input signed [31:0] v;
    begin
      q30_to_q15 = (v + 32'sd16384) >>> 15;
    end
  endfunction

  function [15:0] q29_to_q15;                // VPHAT 用（乘的是 Q14 的倒数）
    input signed [31:0] v;
    begin
      q29_to_q15 = (v + 32'sd8192) >>> 14;
    end
  endfunction

  // ── VPHAT 的幅值 + 倒数 ──────────────────────────────────────────────
  // Magnitude approximation: large-signal Euclidean error reaches about +8.24%.
  function [15:0] mag_approx;
    input signed [15:0] re, im;
    reg [15:0] a, b, big, sml;
    begin
      a   = re[15] ? (~re + 16'd1) : re;
      b   = im[15] ? (~im + 16'd1) : im;
      big = (a > b) ? a : b;
      sml = (a > b) ? b : a;
      mag_approx = big + (sml >> 1) - (sml >> 3) + (sml >> 5) + (sml >> 7);
    end
  endfunction

  // 倒数：**4 位 LUT，没有除法器**（README §0.3.4 第 3 条：4/6/8/10 bit 的
  // 定位误差完全相同，所以 4 位就够）。
  // 把 mag 规格化成 [1,2) 的 Q14 尾数，取高 4 位查表得 1/mant（Q14），
  // 再按指数移位。LUT 值 = round(16384 / (1 + (idx+0.5)/16))。
  function automatic [15:0] recip_q14;
    input [15:0] mag;
    reg [4:0]  e;
    reg [15:0] mant, lut;
    reg [3:0]  idx;
    // ⚠ 循环变量要**单独声明**，不能写 `for (integer b = 15; ...)`。
    //   那是 SystemVerilog 的写法：iverilog -g2005 宽容地收下（所以 24 个 TB 全过），
    //   Vivado 的默认 Verilog 模式直接报 [Synth 8-2301] 拒绝整个文件。
    //   指纹：TB 全绿但 `launch_runs synth_1` 在读文件阶段就失败。
    integer b;
    begin
      if (mag == 16'd0) begin
        recip_q14 = 16'd16384;                 // 防 0 除：当作 1/1
      end else begin
        e = 5'd0;
        for (b = 0; b < 16; b = b + 1) begin
          if (mag[b]) e = b[4:0];
        end
        // 规格化到 bit14 对齐（mant ∈ [16384, 32767] = Q14 的 [1,2)）
        mant = (e >= 5'd14) ? (mag >> (e - 5'd14)) : (mag << (5'd14 - e));
        idx  = mant[13:10];
        case (idx)
          4'd0:  lut = 16'd15888;   4'd1:  lut = 16'd14895;
          4'd2:  lut = 16'd14014;   4'd3:  lut = 13233;
          4'd4:  lut = 12537;       4'd5:  lut = 11915;
          4'd6:  lut = 11357;       4'd7:  lut = 10855;
          4'd8:  lut = 10402;       4'd9:  lut = 9993;
          4'd10: lut = 9621;        4'd11: lut = 9281;
          4'd12: lut = 8969;        4'd13: lut = 8682;
          4'd14: lut = 8417;        default: lut = 16'd8192;   // idx=15
        endcase
        // 1/mag = (1/mant) · 2^-e，lut 是 Q14
        // Keep the mantissa; shifting a reciprocal first overflows on weak bins.
        recip_q14 = lut;
      end
    end
  endfunction

  function [4:0] mag_exponent;
    input [15:0] mag;
    integer j;
    begin
      mag_exponent=0;
      for(j=0;j<16;j=j+1)if(mag[j])mag_exponent=j;
    end
  endfunction
  function [15:0] normalize_q14;
    input signed [31:0] product;
    input [4:0] exponent;
    begin normalize_q14=product>>>exponent;end
  endfunction

  // VPHAT 的结果**不再在这里组合算** —— 上面那三级流水把它拆开了，
  // 见 vph_q 的注释与 ST_RUN 里的 3'd1 分支。限带门控（带外清 0）挪到第 3 拍。

  // VRED2 的组合归约（见 ST_RUN 里为什么不能直接在 for 里累加）
  reg signed [15:0] sum_re, sum_im;
  integer k;                    // 必须声明在**使用它的 always 之前**（Vivado 8-6901）
  always @(*) begin
    sum_re = 16'sd0;
    sum_im = 16'sd0;
    for (k = 0; k < LANES; k = k + 1) begin
      // 走上面那根**共用的**读数据线（`mx_rd`），不要在这里再写一次 `mx[...]` ——
      // 那会变成第 9〜16 个读口，把整个数组顶出分布式 RAM 的 16 口上限。
      sum_re = sum_re + mx_rd[k][15:0];
      sum_im = sum_im + mx_rd[k][31:16];
    end
  end

  // ── mz 按 lane 分成 8 个 bank：**每个 bank 只有一个写口** ─────────────
  // 原来写的是 `reg [CW-1:0] mz [0:CN-1]`，而 VCMUL/VSUB/VPHAT 每拍要写
  // **8 个不同的字**（`for k: mz[base+k] <= ...`，每个 lane 一个）⇒ 8 个写口。
  // 分布式 RAM **只有一个写口**，于是整块 dissolve 成触发器 + 多路选择
  // （实测：`mz` 一个数组就吃掉 ~20,000 个 LUT，见 docs/issues/060）。
  //
  // 能这么分是因为 `base = pass×8` **恒是 8 的倍数**，于是
  //     全局下标 i  →  bank = i & 7，字 = i >> 3
  //     写：lane k 写下标 base+k  ⇒  bank = k、字 = pass   ← **地址是静态的**
  //     读：lane k 读下标 base+k  ⇒ 同一地址（VPHAT 那三级流水读的就是它）
  //     POP：读 mzb[ptr[2:0]][ptr[7:3]] —— 8 个 bank 同字读出，再按 ptr[2:0] 选
  // 与 issues/053 修 FFT bank 是同一手法：把写口降到每 bank 一个。
  //
  // ⚠ 写必须在**不带异步复位**的 always 里（和上面 mx/my 同一条理由）：
  //   这个块敏感表里只有 clk，没有 negedge rst_n_i。
  wire [CW-1:0] mz_wd [0:LANES-1];
  wire          mz_we [0:LANES-1];
  wire [CW-1:0] mzb_rd [0:LANES-1];

  // 本拍 mz 该不该写：VCMUL/VSUB 每拍写；VPHAT 在流水第 3 拍才写
  wire mz_tick = (state_q == ST_RUN) & keep_i &
                 ((op_q == 3'd0) | (op_q == 3'd2) |
                  ((op_q == 3'd1) & (vph_q == 2'd2)));

  generate
    for (g = 0; g < LANES; g = g + 1) begin : g_mzb
      (* ram_style = "distributed" *) reg [CW-1:0] mem [0:(1<<PW)-1];
      // 读地址：ST_IDLE 给 POP（按指针），其余时间给本 lane 的白化读（按 pass）
      wire [PW-1:0] rd_w = (state_q == ST_IDLE) ? (ptr_idx >> LB) : pass_q;
      assign mzb_rd[g] = mem[rd_w];
      always @(posedge clk_i) if (mz_we[g]) mem[pass_q] <= mz_wd[g];

      // 每 lane 的写数据：VPHAT 用流水第 2 拍的产物（带内门控），其余用复数乘结果
      assign mz_wd[g] = (op_q == 3'd1)
        ? (act_q[g] ? { normalize_q14(zi_q[g] * $signed({1'b0, zinv_q[g]}),zexp_q[g]),
                        normalize_q14(zr_q[g] * $signed({1'b0, zinv_q[g]}),zexp_q[g]) } : 32'd0)
        : { q30_to_q15(pi_w[g]), q30_to_q15(pr_w[g]) };
      assign mz_we[g] = mz_tick;
    end
  endgenerate

  // POP uses word=ptr/LANES and bank=ptr%LANES.
  wire [31:0] pop_rdata = mzb_rd[ptr_idx[LB-1:0]];

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      state_q <= ST_IDLE;  pass_q <= 0;   ptr_q <= 0;
      acc_re_q <= 0;       acc_im_q <= 0;
      op_q <= 3'd4;        is_io_q <= 1'b0;  io_sel_q <= 2'd0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (is_io_i) begin
            // ── 单拍通路：写完就走，**不进 DONE、不冻流水** ────────────
            if (io_fire) begin
              // ⚠ PUSH 的落盘**不在这里** —— 见下面 `g_push` 那个**不带复位**的
              //   always 块。写在这个带 `negedge rst_n_i` 的块里，分布式 RAM
              //   会因为"没法复位"被整块 dissolve 成触发器（实测见
              //   build/probe_ram_shape.v 的 m1/m3 对照）。
              // 显式回绕到 CN：数组只有 CN 条，让 8 位指针自然回绕到 256
              // 会越界读出 X（而"越界读"不报错，只让结果变成垃圾）。
              ptr_q <= (ptr_idx == (CN - 1)) ? {(NIDX+1){1'b0}} : (ptr_q + 1'b1);
              // state_q 不变，仍是 ST_IDLE
            end
          end else if (start_i) begin
            op_q     <= op_i;
            is_io_q  <= 1'b0;
            io_sel_q <= io_sel_i;
            acc_re_q <= 0;
            acc_im_q <= 0;
            pass_q   <= 0;
            vph_q    <= 2'd0;            // 三级流水相位必须从 0 起，否则会漏第 1 拍
            state_q  <= (op_i == 3'd4) ? ST_DONE : ST_RUN;   // 保留位：一拍就完
          end
        end

        ST_RUN: begin
          if (!keep_i) begin
            state_q <= ST_IDLE;                    // 冲刷：不写存储
          end else begin
            case (op_q)
              3'd0, 3'd2: begin                    // VCMUL / VSUB
                // 写**不在这里** —— 已搬到上面 `g_mzb` 那个不带复位的 always
                // （写在带 negedge rst_n_i 的块里会让 mz 无法落成 RAM）。
              end
              3'd1: begin                          // VPHAT：Z = Z/|Z| · 带内（三级流水）
                // 每趟处理 LANES 条（与 VCMUL 一样），**不是一条**。
                // 写成只处理 mz[base] 的话，512 条里只有 64 条被白化，
                // 其余保留互谱的原值 —— 看起来"白化过了"（带内确实变得平坦），
                // 只是每 8 条里错 7 条。
                case (vph_q)
                  2'd0: for (k = 0; k < LANES; k = k + 1) begin
                    // 第 1 拍：组合读 + 幅值。地址、门控、原始 z 一起寄存下去。
                    aidx_q[k] <= base + k[NIDX-1:0];
                    act_q[k]  <= ((base + k[NIDX-1:0]) >= BAND_LO[NIDX-1:0]) &&
                                 ((base + k[NIDX-1:0]) <= BAND_HI[NIDX-1:0]);
                    // 走 bank k 的读口（字 = pass），不再直接索引扁平数组
                    zr_q[k]   <= mzb_rd[k][15:0];
                    zi_q[k]   <= mzb_rd[k][31:16];
                    mag_q[k]  <= mag_approx(mzb_rd[k][15:0], mzb_rd[k][31:16]);
                  end
                  2'd1: for (k = 0; k < LANES; k = k + 1) begin
                    // 第 2 拍：倒数（16 位优先编码器 + 两次变址移位单占这一拍）
                    zinv_q[k] <= recip_q14(mag_q[k]);
                    zexp_q[k] <= mag_exponent(mag_q[k]);
                  end
                  default: begin
                    // 第 3 拍：复乘 + 限带门控 + 写回
                    // 写**不在这里** —— 已搬到 `g_mzb`（mz_wd/mz_we + 不带复位的 always）。
                  end
                endcase
              end
              default: begin                       // VRED2：对偶归约
                // ⚠ 先**组合求和**再一次性累加。写成
                //     for (k) acc_re_q <= acc_re_q + mx[base+k];
                //   只有最后一次赋值生效（非阻塞赋值在同一时刻只有一个赢家），
                //   结果是每拍只加了 8 条里的最后一条 —— 归约值偏小 8 倍，
                //   而"偏小的和"是个完全合理的数字，不报错。
                acc_re_q <= acc_re_q + sum_re;
                acc_im_q <= acc_im_q + sum_im;
              end
            endcase

            // VPHAT 三拍一趟（相位 2 才推进），其余一拍一趟
            if (op_q == 3'd1) begin
              vph_q <= (vph_q == 2'd2) ? 2'd0 : (vph_q + 2'd1);
              if (vph_q == 2'd2) begin
                if (pass_q == LAST_PASS) state_q <= ST_DRAIN;
                else                     pass_q <= pass_q + 1'b1;
              end
            end else begin
              vph_q <= 2'd0;
              if (pass_q == LAST_PASS) state_q <= ST_DRAIN;
              else                     pass_q <= pass_q + 1'b1;
            end
          end
        end

        ST_DRAIN: state_q <= ST_DONE;              // 最后一批写回落地

        ST_DONE: begin
          if (commit_i) begin
            state_q <= ST_IDLE;
            // ⚠ 计算类指令收尾时指针归零。PUSH/POP 走单拍通路、不进这里，
            //   它们各自扫满 CN 次自然回绕。
            //   （旧版在这里无条件清零，512 次 PUSH 全落在同一个地址上 ——
            //     实测只有 mx[0] 有值、其余是 X，而 PUSH 一个个"成功"返回。）
            ptr_q <= 0;
          end
        end
      endcase
    end
  end

  // 单拍的 PUSH/POP **不拉 stall、当拍给 done** —— 这是省下 2/3 搬运拍数的全部秘密。
  assign stall_o = io_fire ? 1'b0 :
                   ((state_q == ST_RUN) | (state_q == ST_DRAIN) |
                    ((state_q == ST_IDLE) & start_i & ~is_io_i));
  assign done_o  = io_fire | (state_q == ST_DONE);

  // POP 的读数据是**组合**的（自增前的指针），见 pop_rdata。
  assign result_o = io_fire                               ? pop_rdata :
                    (op_q == 3'd3)                        ? {acc_im_q, acc_re_q} :
                    32'd0;

endmodule
