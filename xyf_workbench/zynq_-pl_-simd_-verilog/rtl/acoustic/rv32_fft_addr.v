// VFFT 的地址发生器 —— 纯组合，一条式子算完，**没有乘法器**。
//
// 为什么单独一个模块
// ------------------
// 蝶形本身只是「读两条、复乘、加/减、写回两条」。真正难的是地址：DIT 的 a 与 b
// 相差 half（half 从 1 变到 256），twiddle 下标按 step 跳。**地址错了不会报错，
// 只会算出一个看起来像频谱的东西。**
// 所以它单独成模块，对着 scripts/golden/fft_addr_gen.py 枚举的 384 拍逐拍比
// （tb/tb_fft_addr.v）—— 比对通过才有资格往下写数据通路。
//
// 两种取数模式
// ------------
//   stage >= 3（len >= 16）：**两个** 8 字窗口，A 窗放 a、B 窗放 b，
//       B = A + half。两窗都 8 对齐 ⇒ lane l 读 bank l，**固定接线，无交叉开关**。
//       一拍 8 个蝶形。
//   stage <= 2（len <= 8）：a 自身跨步（步长 < 8），8 条 a 会撞在同一批 bank 上。
//       改成一拍读**一个** 8 字窗口、做 **4 个蝶形**，一组两拍。
//       只占 9 级里的 3 级，多花 96 拍 —— 比做一个 16×16 的 32 位交叉开关便宜得多。
//
// 下标约定（与 sw/fw/fw_fft.c / fw_fft_model.py 一字不差）
// -------------------------------------------------------
//   len = 2^(stage+1)，half = 2^stage，step = 1024/len = 2^(9-stage)
//   蝶形线性序号 k（每级 0..255）
//   a = (k/half)*len + (k mod half)，b = a + half，tw = (k mod half)*step
//
// 全部是移位与位与，**没有乘法器、没有除法器**（half、len、step 都是 2 的幂）。
module rv32_fft_addr (
  input  [3:0] stage_i,      // 0..8
  input  [6:0] cyc_i,        // 本级的第几拍：mode8 → 0..31，mode4 → 0..63
  output [3:0] nbf_o,        // 本拍做几个蝶形（8 或 4）
  output [8:0] wa_o,         // 窗口 A 基址（恒 8 对齐）
  output [8:0] wb_o,         // 窗口 B 基址（mode4 时无意义）
  output [8*3-1:0] al_o,     // 每 lane 的 a 取哪条（窗口内偏移 0..7）
  output [8*3-1:0] bl_o,     // 每 lane 的 b 取哪条
  output [8*10-1:0] tw_o     // 每 lane 的 twiddle 下标（表 W_1024^k）
);

  wire [3:0] mode8 = (stage_i >= 4'd3);

  // grp / ph：mode8 一拍一组；mode4 一组两拍
  wire [5:0] grp = mode8 ? {1'b0, cyc_i[4:0]} : {1'b0, cyc_i[5:1]};
  wire       ph  = mode8 ? 1'b0 : cyc_i[0];

  wire [8:0] half   = 9'd1 << stage_i;
  wire [8:0] length = 9'd1 << (stage_i + 4'd1);
  // （`step = 2^(9−stage)` 这个量已经用不到了 —— 它只活在上面那条移位式子里，
  //   留着声明会变成一条没人用的信号。）
  // ⚠ tw = j·step 一律用**移位**（j << (9−stage)），不要写 `j * step`。
  //   本文件原来 9 处写的都是 `*`（每 lane 一个），而这个文件的头注释却写着
  //   「全是移位与位与，**没有乘法器**」—— **注释是错的，乘法器一直挂着**。
  //   藏得住是因为 039 挡住了综合、从来没有真实时序数字。2026-10-02 第一次跑完
  //   整实现时暴露：VPHAT 那条修完之后，**最差路径整条换了地方**，落到
  //   stage_q/cyc_q → 本模块 → bank 读地址，逻辑构成里明摆着 `CARRY4=13 DSP48E1=3`
  //   —— DSP48 长在**地址通路**上，那就只可能是乘法器。
  wire [3:0]  sh    = 4'd9 - stage_i;               // ∈ {1..9}（stage 0..8）

  wire [8:0] k0 = {grp, 3'b000} + (mode8 ? 9'd0 : {7'b0, ph, 2'b00});

  assign nbf_o = mode8 ? 4'd8 : 4'd4;

  // ── mode 8：两个 8 字窗口 ────────────────────────────────────────────
  wire [8:0] j0_8 = k0 & (half - 9'd1);
  wire [8:0] wa_8 = ((k0 >> stage_i) << (stage_i + 4'd1)) + j0_8;
  wire [8:0] wb_8 = wa_8 + half;

  // ── mode 4：a 与 b 都在同一个 8 字窗口里 ─────────────────────────────
  wire [8:0] wa_4 = (k0 >> stage_i) << (stage_i + 4'd1);

  assign wa_o = mode8 ? wa_8 : wa_4;
  assign wb_o = mode8 ? wb_8 : 9'd0;

  genvar g;
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_lane
      // mode 8：lane l 取 A 窗第 l 条与 B 窗第 l 条
      wire [8:0] j_l   = j0_8 + g[8:0];
      // j_l ≤ half−1（j0_8 是 8 的倍数、half ≥ 8）⇒ tw < 512，11 位装得下且**不移出**
      wire [10:0] tw_8 = j_l << sh;
      // mode 4：第 g 个蝶形（g < 4 有效）的下标
      wire [8:0] k_g   = k0 + g[8:0];
      wire [8:0] st_g  = (k_g >> stage_i) << (stage_i + 4'd1);
      wire [8:0] j_g   = k_g & (half - 9'd1);
      wire [8:0] a_g   = st_g + j_g;
      wire [8:0] b_g   = a_g + half;

      assign al_o[g*3 +: 3] = mode8 ? g[2:0] : (a_g - wa_4);
      assign bl_o[g*3 +: 3] = mode8 ? g[2:0] : (b_g - wa_4);
      assign tw_o[g*10 +: 10] = mode8 ? tw_8[9:0] : (j_g << sh);
    end
  endgenerate

endmodule
