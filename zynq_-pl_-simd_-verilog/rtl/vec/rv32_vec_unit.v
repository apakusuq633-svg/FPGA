// SIMD-MAC 向量单元：8 lane、16-bit MAC、加法树可旁路。四条自定义指令的执行体。
//
// 多拍单元，住在核里（rv32_core.v）而不是 EX 级里 —— 沿用 rv32_div_unit 的先例，
// EX 保持纯组合、无时钟端口；start/keep/commit/stall/done 握手也照抄那个。
//
// ══ 抽头映射（整个设计能不能成立就在这一段，改之前先读）═══════════════════════
//
// 8 个 lane 对应 8 个 bank（固定接线）。抽头 t = 8j + b 由 lane b 在第 j 趟处理。
//
// **两套独立存储**，因为一个简单双口 BRAM 只有一个读口，而系数与数据必须同拍取：
//   系数 bank：静态存储（w、ŝ），按系数下标分 bank —— 系数 t 在 bank (t mod 8)、
//              word (base + t/8)。于是趟 j 时 8 个 bank 读**同一个字地址** (base+j)，
//              是广播；bank b 返回的就是 w[8j+b] ✓
//   延迟线 bank：x 与 x'，按**样本下标**分 bank —— 样本 x(m) 写进 bank (m mod 8)、
//              word (m/8) mod 64。每个样本只写一个 bank ✓（写口正好只有一个）
//
// 延迟线的读：lane b 在趟 j 要样本 x(n - 8j - b)，它的 (m/8) = (n-8j-b)/8。
// 令 nq = n/8、nr = n%8，则 (n-8j-b)/8 = nq - (b>nr ? 1 : 0) - j。所以
//   bank b 读 word (base + nq - (b>nr) - j) mod 64，**拿到的正好是 x(n-8j-b)**。
// ✓ **不需要 barrel 旋转**，每 bank 只是地址差一个 borrow。
//
// ══ 流水（逐级列清；改之前先数一遍拍）═════════════════════════════════════════
//   t+0  pass_q 出地址 → BRAM（系数广播址 + 每 bank 的数据址）
//   t+1  BRAM 数据回来 → a_q / b_q / cw1_q（w 的旧值），同时带 op1/ch1/p1
//   t+2  prod_q = a*b，带 b2_q（x'）、cw2_q（w 旧值）、op2/ch2/p2
//   t+3  acc_q += prod_q；VUPD 在这一拍用 cw2_q + g*b2_q 写回系数 bank
// RUN 每拍发一趟，所以 len 趟共 (len+1) 拍，最后一趟的累加再落 2 拍。
//
// **加法树不在 RUN 里做**，放在 DRAIN 阶段对**已经稳定的 acc_q** 做 3 级归约。
// 曾经把它和累加放同一个 always 块，那样树读的是还在变的 acc_q —— 拍数对不上，
// 结果是部分和，而部分和是个完全合理的数字，静默错。
module rv32_vec_unit (
  input               clk_i,
  input               rst_n_i,
  input               start_i,
  input               keep_i,
  input               commit_i,
  // 0 = PUSH  1 = VRED（归约，树接通）  2 = VUPD（逐元素，树旁路）  3 = VMUL（Σ|x|）
  input  [1:0]        op_i,
  input  [5:0]        len_i,       // 趟数 - 1
  input  [31:0]       scalar_i,    // rs1，start 那拍锁存（VUPD 的 g）
  input               acc_i,       // 1 = 累加到已有值（多趟归约第 2 趟起）
  input               wsel_i,      // 系数选哪一套：0 = w，1 = ŝ（叫 wsel 不叫 coef，
                                   //   免得和下面那组外部预装口 coef_* 看混）
  input               data_i,      // 0 = x 线，1 = x' 线
  // x' 有 4 条（2 位）：2×2 MIMO 的 filtered-x 要 x'_LL / x'_LR / x'_RL / x'_RR 各一条。
  // MIMO 的梯度是 Σ_m e_m·x'_ms，一个 VUPD 只吃一个标量 g，所以 4 条都得留历史。
  input  [1:0]        ch_i,
  input  [15:0]       xin_i,       // PUSH 送进来的样本
  // PS 侧系数预装口：一个抽头一次。**按逻辑抽头号寻址**，Q15 进出 ——
  // 抽头落在哪个 bank、存储格式是 Q15<<8，都留在本模块里，外面不用知道。
  // 写保护不在这里做：核停住时阵列必然空闲，两边的写撞不上（PS 寄存器堆那层
  // 已经用 halt_q 挡住运行期的写）。
  input               coef_we_i,
  input               coef_re_i,
  input               coef_src_i,   // 0 = w，1 = ŝ（与 wsel_i 同义，来源不同）
  input               coef_ch_i,    // 通道
  input  [8:0]        coef_idx_i,   // 抽头号 t：w 为 0..511，ŝ 为 0..63
  input  [15:0]       coef_wdata_i, // Q15
  output [15:0]       coef_rdata_o, // 读回 Q15（发地址后一拍有效）
  output              stall_o,
  output              done_o,
  output [31:0]       result_o,
  output [5:0]        norm_sh_o,
  output [15:0]       n_x_o,
  output [39:0]       lane0_acc_o
);

  localparam integer LANES = 8;
  localparam integer CAW   = 8;    // 系数 bank：256 字
  localparam integer DAW   = 9;    // 延迟线 bank：512 字
  localparam integer CDW   = 24;   // w：Q15 + 8 个额外小数位
  localparam integer DDW   = 16;

  localparam [CAW-1:0] W0_BASE = 8'd0;     //   0.. 63  w[ch0]（512 tap / 8 lane）
  localparam [CAW-1:0] W1_BASE = 8'd64;    //  64..127  w[ch1]
  // ŝ 按 4 条次级通路分 bank：128 + 8*ch，ch = {m,s} 见下面 ch_q 的注释
  localparam [CAW-1:0] S0_BASE = 8'd128;   // 128..159  四条通路的 ŝ，各 64 tap / 8 lane
  localparam [CAW-1:0] S1_BASE = 8'd136;   // 保留：老端口按 ch 选 bank 时的第二个

  localparam [DAW-1:0] X_BASE   = 9'd0;    //   0.. 63  x 线
  localparam [DAW-1:0] XP0_BASE = 9'd64;   //  64..127  x'[ch0]
  localparam [DAW-1:0] XP1_BASE = 9'd128;  // 128..191  x'[ch1]（ch 现在是 2 位，见 ch_i）
  localparam [DAW-1:0] XP2_BASE = 9'd192;  // 192..255  x'[ch2]
  localparam [DAW-1:0] XP3_BASE = 9'd256;  // 256..319  x'[ch3]

  localparam [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DRAIN = 2'd2, ST_DONE = 2'd3;

  localparam [1:0] OP_PUSH = 2'd0, OP_VRED = 2'd1, OP_VUPD = 2'd2, OP_VMUL = 2'd3;

  // ── t+0：状态与锁存的指令字段 ─────────────────────────────────────────────
  reg [1:0]  state_q;
  reg [5:0]  pass_q;
  reg [1:0]  op_q;
  reg [5:0]  len_q;
  // 注意 accmode_q 不能叫 acc_q —— 会和下面的累加器数组撞名（Verilog 同一作用域
  // 不许重名，而且报错指向的是数组那行，不好找）。
  reg        wsel_q, data_q, accmode_q;
  // 通道号 = 次级通路下标，编码 {m, s}：0=LL 1=LR 2=RL 3=RR（m 误差麦、s 扬声器）。
  // 同一个 ch 同时选 ŝ bank 与 x′ 延迟线 —— 因为 x'_ms 就是「ŝ_ms 卷 x」，两者必须同路。
  // 选 w bank 时只用 ch[0]（输出通道 s）：MIMO 的两个输出滤波器各一条。
  reg [1:0]  ch_q;
  reg [15:0] scalar_q;

  // 五条延迟线各一个写指针：x 一条，x′ 四条
  reg [15:0] n_x_q;
  reg [15:0] n_p_q [0:3];
  // RAM contents survive reset; valid lengths provide deterministic zero history
  // without resetting RAM (which would destroy block-RAM inference).
  reg [9:0] valid_x_q;
  reg [9:0] valid_p_q [0:3];
  reg [7:0] tap_valid_q;
  wire [9:0] line_valid = data_q ? valid_p_q[ch_q] : valid_x_q;
  reg        push_go_q;                // PUSH 的写脉冲，只发一拍

  // ── t+1 ───────────────────────────────────────────────────────────────────
  reg        v1_q;
  reg [5:0]  p1_q;
  reg [1:0]  op1_q;
  reg [1:0]  ch1_q;
  // 有符号：系数与样本都是 Q15，无符号乘会把负半轴整个算错。
  reg signed [15:0] a_q   [0:LANES-1];
  reg signed [15:0] b_q   [0:LANES-1];
  reg [CDW-1:0] cw1_q [0:LANES-1];

  // ── t+2 ───────────────────────────────────────────────────────────────────
  reg        v2_q;
  reg [5:0]  p2_q;
  reg [1:0]  op2_q;
  reg [1:0]  ch2_q;
  reg signed [31:0] prod_q [0:LANES-1];
  reg signed [15:0] b2_q   [0:LANES-1];
  reg [CDW-1:0] cw2_q [0:LANES-1];

  // ── t+3 ───────────────────────────────────────────────────────────────────
  // 累加的使能要用**第 3 级**有效位。地址在 t 拍出 → BRAM 输出 t+1 → 操作数 t+2 →
  // 乘积 t+3，所以 t+3 那一拍的产品对应的是**t 拍**发出的地址，使能也必须延迟 3 拍
  // 才是 running(t)。用第 2 级（= running(t+1)）会差一拍：只有第 1 趟被累加，
  // 后面每一趟都在重复第 1 趟的数据 —— 单趟（len=0）测试里完全看不出来。
  reg        v3_q;
  reg [5:0]  p3_q;
  reg [1:0]  op3_q;
  reg [1:0]  ch3_q;
  reg signed [39:0] acc_q  [0:LANES-1];

  // ── 加法树（DRAIN 阶段，3 级）────────────────────────────────────────────
  reg signed [39:0] t1_q [0:3];
  reg signed [39:0] t2_q [0:1];
  reg signed [39:0] red_q;
  reg [1:0]  tree_q;
  // 进 DRAIN 后先等 3 拍再开树：RUN 的最后一趟发出后，它的累加还要 3 拍才落进
  // acc_q（见头部流水表）。不等就跑树，读到的是**缺最后一项**的累加器 ——
  // 而那个数照样合理，只是结果系统性偏小，静默错。
  reg [2:0]  wait_q;

  wire       running = (state_q == ST_RUN);
  wire [5:0] p       = pass_q;

  // ── 地址 ──────────────────────────────────────────────────────────────────
  wire [CAW-1:0] coef_raddr = (wsel_q ? (S0_BASE + {3'b0, ch_q, 3'b000})
                                      : (ch_q[0] ? W1_BASE : W0_BASE)) + {2'b0, p};

  wire [15:0]    line_n    = data_q ? n_p_q[ch_q] : n_x_q;
  wire [DAW-1:0] line_base = data_q ? (XP0_BASE + {6'b0, ch_q, 6'b000000}) : X_BASE;

  // line_n 是**下一个要写的**样本号，所以最新样本是 line_n-1。令 nn = line_n-1、
  // Q = nn/8、R = nn%8。lane b 要的抽头是 k = 8j+b，样本下标 m = nn - 8j - b。
  //   m 所在的 bank = m%8 = (R - b) mod 8      ← **这是旋转的来源**
  //   m 的 word     = Q - j - (b > R ? 1 : 0)
  // 早先一版把 bank 定成 b 就直接读，等于假设 (R-b)%8 == b（只在 R==2b 时成立），
  // 读出来的是错位的样本 —— 滤波器照样"收敛"，只是收敛到错的东西上。
  // 测试台用 lane0 应当拿到 x(n) 这一条把它抓了出来。
  wire [15:0] nn   = line_n - 16'd1;
  wire [5:0]  nn_Q = nn[8:3];
  wire [2:0]  nn_R = nn[2:0];

  wire [CDW-1:0] c_rd [0:LANES-1];
  wire [DDW-1:0] d_rd [0:LANES-1];
  wire [LANES*DDW-1:0] d_rd_flat;
  wire [DDW-1:0] lane_d [0:LANES-1];   // 旋转之后、给 lane b 的那份数据

  // VUPD 的回写：t+3 那一拍。趟号/通道用第 3 级（p3_q/ch3_q），它对应的正是 t 拍
  // 发出的那个地址 —— 也就是 t+3 这一拍乘积所属的趟。
  // c_wr_data 用 cw2_q/b2_q：它们在 t+3 这一拍有效（t+2 末装载），和写同拍。
  wire           c_we    = v3_q & (op3_q == OP_VUPD);
  wire [CAW-1:0] c_waddr = (ch3_q[0] ? W1_BASE : W0_BASE) + {2'b0, p3_q};
  wire [CDW-1:0] c_wr_data [0:LANES-1];

  // PUSH 的写：**和指针自增同一拍，用自增前的指针**。
  // 曾经把它做成一个打拍的脉冲 push_go_q，那时指针已经自增过了，样本被写进下一个
  // 字，而要读的那个字从没被写过 —— 读出来是 X，整条加法树跟着变 X。
  // 地址直接用输入（data_i/ch_i），不用锁存后的字段：start 那拍 data_q 还是上一条的。
  // **三条延迟线各有一个指针**，写地址必须跟着**选中的那条**走。曾经三个都取
  // n_x_q，等于把 x' 的样本按 x 线的进度写进同一个字里互相覆盖，而读那边用的是
  // n_p*_q —— 读到的是一片从没写过的 X。只在 x 线上测（tb_vec_unit）看不出来。
  wire [15:0]    push_ptr  = (data_i == 1'b0) ? n_x_q : n_p_q[ch_i];
  wire [5:0]     push_nq   = push_ptr[8:3];
  wire [2:0]     push_nr   = push_ptr[2:0];
  wire [DAW-1:0] push_base = (data_i == 1'b0) ? X_BASE
                                             : (XP0_BASE + {6'b0, ch_i, 6'b000000});
  wire           d_we      = (state_q == ST_IDLE) & start_i & (op_i == OP_PUSH);
  wire [DAW-1:0] d_waddr   = push_base + {3'b0, push_nq};

  // ── PS 侧预装口的译码 ─────────────────────────────────────────────────────
  // 抽头 t 落在 bank (t mod 8)、word (base + t/8) —— 和阵列自己读的那套完全一样，
  // 所以外面按逻辑抽头号走，bank/word 的换算留在这里。
  // ŝ 的 4 条通路复用 coef_idx_i 的高两位（idx 0..63 仍是老通路，向后兼容）。
  // 加宽 coef_ch_i 要动 ps_regs/ps_top/soc 一整条线，不值当。
  wire [1:0]     coef_ext_path = coef_idx_i[7:6];
  wire [CAW-1:0] coef_ext_base = coef_src_i
      ? (S0_BASE + {3'b0, coef_ext_path, 3'b000})
      : (coef_ch_i ? W1_BASE : W0_BASE);
  wire [2:0]     coef_ext_bank = coef_idx_i[2:0];
  // 字偏移按通路分开取：ŝ 64 抽头（8 字，idx[5:3]），w 最多 512 抽头（64 字，idx[8:3]）。
  wire [5:0]     coef_ext_off  = coef_src_i ? {3'b0, coef_idx_i[5:3]} : coef_idx_i[8:3];
  wire [CAW-1:0] coef_ext_word = coef_ext_base + {2'b0, coef_ext_off};
  wire [CDW-1:0] coef_ext_data = {coef_wdata_i, 8'b0};   // 外面给 Q15，存储是 Q15<<8

  // 读口是**借阵列那条**的（简单双口只有 1 读 1 写），地址在 coef_re_i 那拍改。
  // coef_re_i 只在核停住时来，阵列必然空闲，借不坏东西。
  wire [CAW-1:0] bank_raddr = coef_re_i ? coef_ext_word : coef_raddr;

  // c_rd 是同步读：coef_re_i 那拍发地址，数据下一拍才到。把当时选中的 bank 号打
  // 一拍存着，下一拍组合选出来 —— 正好落在寄存器总线"读数据延后一拍"的约定上
  // （和 rv32_ps_memif 对 TCM 的做法同拍数）。**不能再打一拍**，那样就慢了一拍，
  // PS 读到的是上一次的残留值。
  reg [2:0]     coef_ext_bank_q;
  reg [CDW-1:0] coef_ext_rd;

  always @(*) begin
    case (coef_ext_bank_q)
      3'd0: coef_ext_rd = c_rd[0];
      3'd1: coef_ext_rd = c_rd[1];
      3'd2: coef_ext_rd = c_rd[2];
      3'd3: coef_ext_rd = c_rd[3];
      3'd4: coef_ext_rd = c_rd[4];
      3'd5: coef_ext_rd = c_rd[5];
      3'd6: coef_ext_rd = c_rd[6];
      3'd7: coef_ext_rd = c_rd[7];
    endcase
  end

  assign coef_rdata_o = coef_ext_rd[23:8];

  genvar b;
  generate
    for (b = 0; b < LANES; b = b + 1) begin : g_lane
      // generate 下标这里是 **bank 号**（不是 lane 号）。bank b 读回来的数据会被
      // 旋转给 lane (R - b) mod 8，所以借位要按**那个 lane**算：
      //   bc = (R - b) mod 8；borrow = bc > R
      wire [2:0]     bc      = nn_R - b[2:0];
      wire           borrow  = (bc > nn_R);
      wire [5:0]     widx    = nn_Q - (borrow ? 6'd1 : 6'd0) - p;
      wire [DAW-1:0] d_raddr = line_base + {3'b0, widx};

      rv32_vec_bank #(.AW(CAW), .DW(CDW)) u_cbank (
        .clk_i   (clk_i),
        // 阵列自己的回写（VUPD）与 PS 预装共用这个写口。两者不会同拍：预装只在核
        // 停住时来，那时阵列不可能在跑。显式让预装优先，不留未定义行为。
        .we_i    (coef_we_i ? (coef_ext_bank == b[2:0]) : c_we),
        .waddr_i (coef_we_i ? coef_ext_word : c_waddr),
        .wdata_i (coef_we_i ? coef_ext_data : c_wr_data[b]),
        .raddr_i (bank_raddr),
        .rdata_o (c_rd[b])
      );

      rv32_vec_bank #(.AW(DAW), .DW(DDW)) u_dbank (
        .clk_i   (clk_i),
        .we_i    (d_we && (push_nr == b[2:0])),
        .waddr_i (d_waddr),
        .wdata_i (xin_i),
        .raddr_i (d_raddr),
        .rdata_o (d_rd[b])
      );

      // VUPD 的逐元素增量：g（Q15）× x'（Q15）→ Q30，取高 16 位回到 Q15，
      // 再左移 8 位对齐到系数的存储格式（Q15 + 8 个额外小数位）。
      // 用 b2_q（t+2 带来的 x'），不能用 b_q —— 它每拍都被下一趟覆盖。
      wire signed [31:0] gmul = $signed(scalar_q) * $signed(b2_q[b]);
      wire signed [31:0] dq15 = gmul >>> 15;
      wire signed [32:0] updated = $signed(cw2_q[b]) + (dq15 <<< 8);
      assign c_wr_data[b] = updated > 33'sd8388607 ? 24'h7fffff :
                            updated < -33'sd8388608 ? 24'h800000 : updated[23:0];
      assign d_rd_flat[b*DDW +: DDW] = d_rd[b];
    end
  endgenerate

  // 数据旋转：lane l 取 bank (R - l) mod 8 的输出。
  // 一头是固定的 lane、一头是固定的 bank，中间的对应关系每拍转 —— 这就是并行抽头
  // 延迟线躲不掉的那笔钱。8 lane 下是 8 个字 × 16 位，用变量基址的部分选择写出来，
  // 综合器建的是一个 8:1 mux，很便宜；32 lane 下它会变成 5 级 barrel（约 3000~4000 LUT），
  // 那才是 README 里 32 lane 口径没算到的那笔账。
  genvar l;
  generate
    for (l = 0; l < LANES; l = l + 1) begin : g_rot
      wire [2:0] src = nn_R - l[2:0];
      assign lane_d[l] = d_rd_flat[{src, 4'b0} +: DDW];
    end
  endgenerate

  integer i;
  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      state_q <= ST_IDLE; pass_q <= 6'b0;
      op_q <= 2'b0; len_q <= 6'b0; wsel_q <= 1'b0; data_q <= 1'b0;
      ch_q <= 2'b0; accmode_q <= 1'b0; scalar_q <= 16'b0;
      n_x_q <= 16'b0; push_go_q <= 1'b0;
      valid_x_q <= 0; tap_valid_q <= 0;
      for (i = 0; i < 4; i = i + 1) begin
        n_p_q[i] <= 16'b0; valid_p_q[i] <= 10'd0;
      end
      v1_q <= 1'b0; v2_q <= 1'b0;
      p1_q <= 6'b0; p2_q <= 6'b0; p3_q <= 6'b0; op1_q <= 2'b0; op2_q <= 2'b0; op3_q <= 2'b0;
      ch1_q <= 2'b0; ch2_q <= 2'b0; ch3_q <= 2'b0; v3_q <= 1'b0;
      tree_q <= 2'b0; wait_q <= 3'd0; red_q <= 40'b0;
      coef_ext_bank_q <= 3'b0;
      for (i = 0; i < LANES; i = i + 1) begin
        a_q[i] <= 16'b0; b_q[i] <= 16'b0; cw1_q[i] <= 24'b0;
        prod_q[i] <= 32'b0; b2_q[i] <= 16'b0; cw2_q[i] <= 24'b0;
        acc_q[i] <= 40'b0;
      end
      t1_q[0] <= 40'b0; t1_q[1] <= 40'b0; t1_q[2] <= 40'b0; t1_q[3] <= 40'b0;
      t2_q[0] <= 40'b0; t2_q[1] <= 40'b0;
    end else begin
      coef_ext_bank_q <= coef_ext_bank;

      // ── t+1：接住 bank 输出 ─────────────────────────────────────────────
      v1_q  <= running;
      p1_q  <= p;
      op1_q <= op_q;
      ch1_q <= ch_q;
      for (i = 0; i < LANES; i = i + 1) begin
        tap_valid_q[i] <= ({1'b0, p, 3'b000} + i) < line_valid;
        // 系数存的是 Q15 + 8 个额外小数位（即 w<<8），所以 Q15 在 [23:8]。
        // VMUL 走另一条路：把样本取绝对值进 a_q（求补，不是只清符号位）。
        a_q[i]   <= !tap_valid_q[i] ? 16'b0 :
                     (op_q == OP_VMUL) ? (lane_d[i][15] ? (~lane_d[i] + 16'd1) : lane_d[i])
                                      : c_rd[i][23:8];
        b_q[i]   <= tap_valid_q[i] ? lane_d[i] : 16'b0;
        cw1_q[i] <= c_rd[i];
      end

      // ── t+2：乘法 ───────────────────────────────────────────────────────
      v2_q  <= v1_q;
      p2_q  <= p1_q;
      op2_q <= op1_q;
      ch2_q <= ch1_q;
      for (i = 0; i < LANES; i = i + 1) begin
        // VMUL 只要 |x| 本身（Σ|x| 的加数），不要乘系数。
        prod_q[i] <= (op1_q == OP_VMUL) ? $signed({16'b0, a_q[i]})
                                        : (a_q[i] * b_q[i]);
        b2_q[i]   <= b_q[i];
        cw2_q[i]  <= cw1_q[i];
      end

      // ── t+3：累加 ───────────────────────────────────────────────────────
      v3_q  <= v2_q;
      p3_q  <= p2_q;
      op3_q <= op2_q;
      ch3_q <= ch2_q;
      for (i = 0; i < LANES; i = i + 1) begin
        if (v3_q) begin
          acc_q[i] <= acc_q[i] + {{8{prod_q[i][31]}}, prod_q[i]};
        end
      end

      // ── DRAIN：先等最后一趟的累加落地，再对稳定的 acc_q 做 3 级归约 ────
      if (state_q == ST_DRAIN && wait_q != 3'd0) begin
        wait_q <= wait_q - 3'd1;
      end else if (state_q == ST_DRAIN) begin
        tree_q <= tree_q + 2'd1;
        case (tree_q)
          2'd0: begin
            t1_q[0] <= acc_q[0] + acc_q[1];
            t1_q[1] <= acc_q[2] + acc_q[3];
            t1_q[2] <= acc_q[4] + acc_q[5];
            t1_q[3] <= acc_q[6] + acc_q[7];
          end
          2'd1: begin
            t2_q[0] <= t1_q[0] + t1_q[1];
            t2_q[1] <= t1_q[2] + t1_q[3];
          end
          2'd2: red_q <= t2_q[0] + t2_q[1];
          default: ;
        endcase
      end

      // ── PUSH 的写脉冲只有一拍 ───────────────────────────────────────────
      push_go_q <= (state_q == ST_IDLE) & start_i & (op_i == OP_PUSH);

      // ── 状态机 ──────────────────────────────────────────────────────────
      case (state_q)
        ST_IDLE: begin
          pass_q <= 6'b0;
          tree_q <= 2'b0;
          if (start_i) begin
            op_q     <= op_i;
            len_q    <= len_i;
            wsel_q   <= wsel_i;
            data_q   <= data_i;
            ch_q     <= ch_i;
            accmode_q <= acc_i;
            scalar_q <= scalar_i[15:0];
            if (op_i == OP_PUSH) begin
              // 一拍写完就完事，指针同时推进
              state_q <= ST_DRAIN;
              tree_q  <= 2'd3;                 // 跳过归约
              wait_q  <= 3'd0;                 // 也不等
              if (data_i == 1'b0) n_x_q <= n_x_q + 16'd1;
              else                n_p_q[ch_i] <= n_p_q[ch_i] + 16'd1;
              if (!data_i && valid_x_q < 512) valid_x_q <= valid_x_q + 1'b1;
              if (data_i && valid_p_q[ch_i] < 512) valid_p_q[ch_i] <= valid_p_q[ch_i] + 1'b1;
            end else begin
              state_q <= ST_RUN;
              if (!acc_i) begin
                for (i = 0; i < LANES; i = i + 1) acc_q[i] <= 40'b0;
              end
            end
          end
        end

        ST_RUN: begin
          if (!keep_i) begin
            state_q <= ST_IDLE;               // 被冲刷：中途放弃，不写任何存储
          end else if (pass_q >= len_q) begin
            state_q <= ST_DRAIN;              // 等累加落地，再进 DRAIN 做树
            tree_q  <= 2'd0;
            wait_q  <= 3'd3;                  // 最后一趟的累加还差 3 拍
          end else begin
            pass_q <= pass_q + 6'd1;
          end
        end

        ST_DRAIN: if (tree_q >= 2'd3) state_q <= ST_DONE;

        ST_DONE:  if (commit_i) state_q <= ST_IDLE;

        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign stall_o  = (state_q == ST_RUN) | (state_q == ST_DRAIN) |
                    ((state_q == ST_IDLE) & start_i);
  assign done_o   = (state_q == ST_DONE);
  assign result_o = red_q > 40'sd2147483647 ? 32'h7fffffff :
                     red_q < -40'sd2147483648 ? 32'h80000000 : red_q[31:0];
  assign n_x_o    = n_x_q;
  assign lane0_acc_o = acc_q[0];

  // Σ|x| 的 ceil-log2。**ceil 不能 floor** —— floor 掉 2 bit 增益，20 dB ERLE 直接
  // 变发散（scripts/aec_feasibility.py:117-123 点名的 #1 定点坑）。前导一检测给的
  // 是 bit_length，写成 31-clz 就复现了那个 bug。
  wire [5:0] lz = red_q[39] ? 6'd0  : red_q[38] ? 6'd1  : red_q[37] ? 6'd2  :
                  red_q[36] ? 6'd3  : red_q[35] ? 6'd4  : red_q[34] ? 6'd5  :
                  red_q[33] ? 6'd6  : red_q[32] ? 6'd7  : red_q[31] ? 6'd8  :
                  red_q[30] ? 6'd9  : red_q[29] ? 6'd10 : red_q[28] ? 6'd11 :
                  red_q[27] ? 6'd12 : red_q[26] ? 6'd13 : red_q[25] ? 6'd14 :
                  red_q[24] ? 6'd15 : red_q[23] ? 6'd16 : red_q[22] ? 6'd17 :
                  red_q[21] ? 6'd18 : red_q[20] ? 6'd19 : red_q[19] ? 6'd20 :
                  red_q[18] ? 6'd21 : red_q[17] ? 6'd22 : red_q[16] ? 6'd23 :
                  red_q[15] ? 6'd24 : red_q[14] ? 6'd25 : red_q[13] ? 6'd26 :
                  red_q[12] ? 6'd27 : red_q[11] ? 6'd28 : red_q[10] ? 6'd29 :
                  red_q[9]  ? 6'd30 : red_q[8]  ? 6'd31 : red_q[7]  ? 6'd32 :
                  red_q[6]  ? 6'd33 : red_q[5]  ? 6'd34 : red_q[4]  ? 6'd35 :
                  red_q[3]  ? 6'd36 : red_q[2]  ? 6'd37 : red_q[1]  ? 6'd38 :
                  red_q[0]  ? 6'd39 : 6'd40;

  wire [5:0] bl      = 6'd40 - lz;                          // bit_length
  wire [5:0] norm_sh = (bl > 6'd4) ? ((bl << 1) - 6'd9) : 6'b0;
  assign norm_sh_o = norm_sh;

endmodule
