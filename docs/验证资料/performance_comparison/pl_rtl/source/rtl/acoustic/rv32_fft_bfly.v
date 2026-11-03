// VFFT —— 核内的 512 点复数 FFT 执行单元。设计档见 docs/vfft_design.md。
//
// 一条指令（funct3=111 + instr[31]=1）跑完整台 FFT：
//     灌 512 条复数（PUSH）→ 位反转 → 9 级蝶形 → 实数 FFT 拆分 → 513 条 bin（POP）
//
// ══ instr[30] = 逆变换（VFFT-inv）═══════════════════════════════════════
// 同一条指令的另一个模式，跑的是 sw/fw/fw_fft.c 的 ifft512_real()：
//     灌 513 条 ψ（PUSH）→ 反向拆分 → 9 级蝶形（**共轭因子**）→ 512 条实序列（POP）
//
// 为什么要它：整条定位链里 28 对 GCC-PHAT 每对要做 **2 次正变换 + 1 次逆变换**
// （README §0.7），逆变换在标量固件里 194,956 拍/次 —— 只做正变换的话，
// 产品规模下三分之一的变换量还留在核上。
//
// ⚠ 与正变换的三处**结构性**差别（不是参数差别）：
//   1. 反向拆分与实数拆分是**互逆**的两步，不是同一段代码换参数；
//   2. 蝶形用共轭因子（-wi），正变换用 +wi；
//   3. **没有**尾巴上的「实数拆分」那一段，出 512 条而不是 513 条。
//   反向拆分的结果直接落回原址，靠"每对 (k, 512−k) 只需同一对输入"这一条
//   做到无冲突 —— 与 ST_SPLIT 是同一个道理。
//
// ══ 算术与 sw/fw/fw_fft.c **逐位一致**（这是验收标准）══════════════════════
// 固件那份标量 FFT 已经有 golden（build/fw_fft_ref.hex）并被
// fw_fft_model.py 与 tb_fw_fft.v 双重验过。硬件直接对同一份 golden，
// 前面所有验证工作都能复用。所以这里**不许"改进"任何一处取整**：
//     蝶形  tr = (wr*br − wi*bi + 8192) >>> 14      ← Q14 因子 × Q15 数据
//           ti = (wr*bi + wi*br + 8192) >>> 14
//           a' = (ar + tr + 1) >>> 1   b' = (ar − tr + 1) >>> 1   ← 每级 >>1
//           （`>>>` 是算术右移，与 C 的 `>>` 对负数一致）
//     拆分  见 ST_SPLIT
//
// ══ 存储：每 bank 一片「**一个写口** + 两个异步读口」的分布式 RAM ═══════
// 上一版是「**一个**数组 + 组合读 + **两个写口**写同一数组」。那不是任何 Xilinx
// RAM 原语能表达的形态，综合器一片都没推断出来，退回 16,384 个触发器
// + 16 路写多路选择：**一个模块 111,603 个 LUT**（全设计 75%、单它 210% 器件，
// place_design 直接失败）。见 docs/issues/053。
//
// ⚠ **实测（build/probe_tdp.tcl，Vivado 2020.2）**：一个 RAM 只给**一个写口**。
//   两个写口放同一个 always 里 → 工具自己说
//     "RAM has multiple writes via different ports in same process"
//   拆成两个 always、各管一个写口 → `[Synth 8-2914] Unsupported RAM template`
//   **真双口（两个写口）推不出来，必须实例化原语。**
//   而「1 写 + 2 异步读」**能推**（实测 RAM=112，LUT 与 FF 都是 0，
//   工具自动复制副本）。⇒ 修法不是换 BRAM，是**把每个 bank 的写口降到 1 个**。
//   BRAM 也能推（1 写 1 读 → RAMB=1），但 BRAM 读有 1 拍延迟，会把每个
//   发生器周期都撑成读相/写相两拍，拍数还要再翻一倍 —— 不划算。
//
// 能切成「每 bank 每拍恰好一条写」是靠地址的一条硬性质：
// **窗口基址恒 8 对齐** ⇒ 一个发生器周期里所有 bank 的字号都相同（`wa[8:3]`），
// bank 号就等于窗口内偏移。于是
//     mode4（stage 0..2）：a 槽的 half 位恒 0 ⇒ own[g] 与 own[g^half] 恰有一个
//         为真，每 bank 只有一条写（a' 与 b' 落在**不同 bank**）⇒ **一拍一组**
//     mode8（stage 3..8）：a' 与 b' 都回 bank g（**字不同**：A 窗 / B 窗）
//         ⇒ 一个写口装不下，拆成**两拍**（第 0 拍写 a'、第 1 拍写 b'）
// ⚠ mode8 第 0 拍写完 a' 之后，A 窗的异步读就变成 a' 了（B 窗没动）。
//   所以第 1 拍要用的 b' 必须**在第 0 拍就寄存下来**（b2r_q/b2i_q），
//   不能到第 1 拍再算 —— 那时 ar 已经被自己的写回污染。拆分阶段同理
//   （xi2_q/xr2_q，只在 X[k] 与 X[m] 撞同一个 bank 的那 65 次才用得上）。
module rv32_fft_bfly #(
  parameter INV_BAND_LO=0,
  parameter INV_BAND_COUNT=513
) (
  input                clk_i,
  input                rst_n_i,
  input                start_i,
  input                keep_i,
  input                commit_i,
  input                inv_i,        // 1 = 逆变换（VFFT-inv，指令的 instr[30]）
  input                sparse_inv_i, // Only localizer-owned band-limited input; generic ISA unchanged.
  input                is_io_i,      // 1 = PUSH/POP
  input                io_sel_i,     // 0 = PUSH 输入帧，1 = POP 结果 bin
  input                io_seek_i,    // POP encoding bit27: set pointer, do not read/advance.
  input  [31:0]        scalar_i,
  output               stall_o,
  output               done_o,
  output [31:0]        result_o,
  output               io_ready_o
);

  localparam integer M     = 512;         // 复数点数
  localparam integer NB    = 8;           // bank 数
  localparam integer BW    = 64;          // 每 bank 字数
  localparam integer NIDX  = 9;           // 下标位宽
  localparam integer NSTG  = 9;           // 蝶形级数
  localparam integer NBIN  = 513;         // 实数 FFT 输出条数

  localparam [2:0] ST_IDLE = 3'd0, ST_RUN = 3'd1, ST_SPLIT = 3'd2,
                   ST_DONE = 3'd3, ST_SPLIT_D = 3'd4,
                   ST_REVSPLIT = 3'd5, ST_REV_D = 3'd6;

  genvar g, b;

  // ── 位反转（装载时用）：9 位下标逐位倒过来 ───────────────────────────
  function [8:0] brev9;
    input [8:0] v;
    integer i;
    begin
      brev9 = 9'd0;
      for (i = 0; i < 9; i = i + 1) brev9[i] = v[8 - i];
    end
  endfunction

  // ── 定序 ─────────────────────────────────────────────────────────────
  reg [2:0]  state_q;
  reg        phase_q;          // mode8 / 拆分阶段的第 0、1 拍
  reg [3:0]  stage_q;          // 0..8
  reg [6:0]  cyc_q;            // 本级第几拍
  reg [NIDX:0] ptr_q;          // PUSH/POP 指针
  reg [8:0]  spl_q;            // 拆分 / 反向拆分阶段的 k
  reg [31:0] nyq_q;            // 正变换：第 513 条输出（bin 512，纯实）
  reg [31:0] in_nyq_q;         // 逆变换：第 513 条输入（ψ[512]，纯实）
  reg        inv_q;            // 本趟的模式（RUN 发起 / 每次 PUSH、POP 时锁存）
  reg        sparse_q;

  // ── 单拍 PUSH/POP（判据用 commit_i，理由见 rv32_acoustic_ext.v）────────
  wire io_fire   = (state_q == ST_IDLE) & start_i & is_io_i & commit_i;
  assign io_ready_o = state_q == ST_IDLE;
  wire push_fire = io_fire & ~io_sel_i;
  wire run_start = (state_q == ST_IDLE) & start_i & ~is_io_i;
  wire [NIDX-1:0] ptr_idx = ptr_q[NIDX-1:0];
  // 逆变换要灌 **513** 条（ψ 的 bin 0..512，Hermitian 谱），数组只有 512 条 ⇒
  // 第 513 条（ψ[512] = Nyquist）单独进 in_nyq_q。正变换方向正好相反：
  // 它 PUSH 512 条、POP 513 条，多出来的那条输出进 nyq_q。
  //
  // ⚠ 两条都**不能**落进数组：ptr=512 时 ptr_idx=0，位反转地址 brev(0)=0，
  //   会静默覆盖 bin 0。写口那边用 push_nyq 把这一笔挡掉。
  wire push_nyq   = push_fire & inv_i & (ptr_q == 10'd512);
  // POP 读的是**自增前**的指针。第 513 条（bin 512 = Nyquist）走单独的寄存器。
  // 逆变换只出 512 条，没有这一档。
  wire pop_is_nyq = ~inv_q & (ptr_q == 10'd512);

  // ⚠ 位反转地址先落到 wire 再位选。写成 `mem[brev9(ptr)[2:0]]` 不合法
  //   （Verilog 不允许对函数返回值做位选），报错指向的是那一行本身，
  //   看上去像数组下标写错。同一个坑在 tb_fw_fft.v 里也踩过一次。
  wire [8:0] brev_w = brev9(ptr_idx);

  // ── 标量流水的两种模式 ───────────────────────────────────────────────
  wire mode8    = (stage_q >= 4'd3);
  wire in_run   = (state_q == ST_RUN);
  wire in_split = (state_q == ST_SPLIT);
  wire in_rev   = (state_q == ST_REVSPLIT);
  // ⚠ mode4 的 half（∈ {1,2,4}）现在**只以 `half_d` 的形式存在** —— 它是写相
  //   用的量，跟着流水延迟了一拍（见下面的读相→算相寄存器组）。

  // ── 拆分 / 反向拆分阶段的 k / 镜像下标 ───────────────────────────────
  // ⚠ **必须一次算出一对互为镜像的 bin**：两步都是**原地**的，k > 256 时要读的
  //   那一条在顺推顺序里**已经被覆盖**。实测指纹：bin 0..256 全对、
  //   257 以后全错 —— 正好一半。k 与 512−k 用的是**同一对**输入（正变换是
  //   z[k]/z[512−k]，逆变换是 ψ[k]/ψ[512−k]），所以一次迭代把两条都算出来，
  //   顺便把 512 拍省成 257 拍。反向拆分能**原地**做，靠的正是这条：写 z[k]
  //   只用 ψ[k]、ψ[512−k]，而这一对在同一拍里读完 ⇒ 不会读到被自己覆盖的值。
  wire [8:0] kk = spl_q;                             // 0..256
  wire [8:0] mm = (M[8:0] - spl_q) & 9'h1FF;         // (512 − k) mod 512
  wire two_out = (mm != kk);                         // k=1..255 时出两条
  // X[k] 与 X[512−k] 撞同一个 bank 时要多花一拍
  // （kk[2:0]==mm[2:0] ⟺ kk[2:0]∈{0,4}，257 次里占 65 次）
  wire same_bank = two_out & (kk[2:0] == mm[2:0]);
  // 这一拍要不要写 X[m]：撞 bank 时留到第 1 拍，否则与 X[k] 同拍
  wire spl_m_wr = phase_q | (two_out & ~same_bank);

  // ── 反向拆分的两个索引（位反转后）────────────────────────────────────
  // 装载一律走位反转地址（索引 j 存的是 ψ[brev(j)]）⇒ ψ[k] 落在 brev(k)。
  // 蝶形要的是「索引 j 存 z[brev(j)]」，所以反向拆分的**写地址也是 brev(k)**：
  // 读一处写一处，同一对 (kk, mm) 自洽 —— 见上面"原地"那一段。
  wire [8:0] rev_a = brev9(spl_q);                   // ψ[kk] 的位置
  wire [8:0] rev_b = brev9(mm);                      // ψ[mm] 的位置
  wire       rev_same = two_out & (rev_a[2:0] == rev_b[2:0]);
  wire       rev_m_wr = phase_q | (two_out & ~rev_same);

  // ── 地址发生器（组合）────────────────────────────────────────────────
  wire [3:0]  nbf;
  wire [8:0]  wa, wb;
  wire [8*3-1:0]  al, bl;
  wire [8*10-1:0] twi;

  rv32_fft_addr u_addr (
    .stage_i (stage_q),
    .cyc_i   (cyc_q),
    .nbf_o   (nbf),
    .wa_o    (wa),
    .wb_o    (wb),
    .al_o    (al),
    .bl_o    (bl),
    .tw_o    (twi)
  );

  // ── 谁来算这个蝶形、b 从哪来、用哪个 twiddle ─────────────────────────
  // mode 8：lane l 就是一条蝶形，a 来自 A 窗、b 来自 B 窗，互不交叉。
  // mode 4：**只有 4 个 lane 是蝶形的"主"** —— 持有 a 的那些（a 槽 == lane 号）。
  //         其余 4 个 lane 持有 b，是被读的一方，自己不产生结果。
  //         例 half=2：a 槽 = {0,1,4,5}，主是 0/1/4/5，b 从 lane^2 取。
  wire [2:0] gv [0:7];
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_gv
      assign gv[g] = g[2:0];
    end
  endgenerate

  wire        own  [0:7];
  wire [2:0]  bsrc [0:7];
  wire [9:0]  tw_l [0:7];
  wire [9:0]  twi_l [0:7];
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_twi
      assign twi_l[g] = twi[g*10 +: 10];
    end
  endgenerate
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_sel
      wire p0 = (al[0*3 +: 3] == gv[g]);
      wire p1 = (al[1*3 +: 3] == gv[g]);
      wire p2 = (al[2*3 +: 3] == gv[g]);
      wire p3 = (al[3*3 +: 3] == gv[g]);
      assign own[g]  = mode8 | p0 | p1 | p2 | p3;
      assign bsrc[g] = mode8 ? gv[g] :
                       p0 ? bl[0*3 +: 3] : p1 ? bl[1*3 +: 3] :
                       p2 ? bl[2*3 +: 3] : bl[3*3 +: 3];
      assign tw_l[g] = mode8 ? twi_l[g] :
                       p0 ? twi[0*10 +: 10] : p1 ? twi[1*10 +: 10] :
                       p2 ? twi[2*10 +: 10] : twi[3*10 +: 10];
    end
  endgenerate

  // ── 旋转因子 ROM（与 sw/fw/fw_tables.c 同源 —— build/fft_tw.hex）──────
  // ⚠ 路径**不能只写相对路径**。Vivado 综合时的工作目录是 run 目录
  //   （vivado/rv32_pipeline.runs/synth_1/），`build/fft_tw.hex` 找不到 ——
  //   报 CRITICAL WARNING [Synth 8-4445] 然后**静默地留一个空 ROM**。
  //   后果特别阴：乘 0 会让乘法器被优化掉，**资源数反而好看**。
  //   TB 发现不了这件事 —— iverilog 从仓库根跑，相对路径是对的。
  //   所以照 ITCM 的既定做法（gen_synth_top.tcl 把绝对路径烘进去）：
  //   综合脚本用 verilog_define 覆盖，没定义时退回相对路径给 TB 用。
  // 8 个 lane 每拍取 8 个**不同地址** ⇒ 一片 ROM 一个读口不够，复制 8 份；
  // 拆分阶段借用副本 0/1（那时 lane 不用 ROM）。
  wire [9:0] tw_adr [0:7];
  generate
    for (g = 2; g < 8; g = g + 1) begin : g_twadr
      assign tw_adr[g] = tw_l[g];
    end
  endgenerate
  // 拆分与反向拆分用的是**同一对**下标（kk 与 mm），所以条件合成一条。
  // ⚠ 反向拆分里 kk=0 时 mm 被掩成 0，ROM 读到 tw[0] —— 那个值确实不用
  //   （那一对不出第二条），但地址必须留在 0..511 内，否则读到 ROM 外面。
  assign tw_adr[0] = (in_split | in_rev) ? kk : tw_l[0];
  assign tw_adr[1] = (in_split | in_rev) ? mm : tw_l[1];

  wire [31:0] tw [0:7];
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_twrom
      reg [31:0] rom [0:M-1];
      initial begin
      `ifdef FFT_TW_FILE
        $readmemh(`FFT_TW_FILE, rom);
      `else
        $readmemh("build/fft_tw.hex", rom);
      `endif
      end
      assign tw[g] = rom[tw_adr[g]];
    end
  endgenerate

  // ── 每 bank 一片分布式 RAM：**一个写口** + 两个异步读口 ──────────────
  // 读地址：窗口恒 8 对齐 ⇒ **所有 bank 同字号**，只有 bank 号不同。
  // 取回（POP）与拆分也走这两个口，靠 bank 号多路选择挑出要的那一条。
  // ⚠ 选择端一律用**寄存器**（state_q），不要用 `push_fire` —— 它是从核那边
  //   **组合**过来的（io_fire ← start_i/is_io_i/commit_i），拿它当 mux 选择端
  //   等于把核的指令译码串进 RAM 的地址端。实测：那样会有 32 级逻辑、30.6 ns
  //   打到 `g_bank[*].mem_reg_*/RAMC`（最差 2000 条路径里 260 条）。
  //   在 ST_IDLE 里写只发生在 PUSH、读只发生在 POP，两者互斥 ⇒ 判据等价。
  wire in_idle = (state_q == ST_IDLE);
  wire [5:0] rd_a_word = in_run   ? wa[8:3]  :
                         in_split ? kk[8:3]  :
                         in_rev   ? rev_a[8:3] :
                         ptr_idx[8:3];           // ST_IDLE：POP 的读（PUSH 时不用）
  wire [5:0] rd_b_word = in_split ? mm[8:3]  :
                         in_rev   ? rev_b[8:3] : wb[8:3];

  wire [5:0]  wr_adr [0:7];
  wire [31:0] wr_dat [0:7];
  wire        wr_en  [0:7];
  wire [31:0] bq_a   [0:7];
  wire [31:0] bq_b   [0:7];
  reg [5:0] wr_adr_q [0:7];
  reg [31:0] wr_dat_q [0:7];
  reg wr_en_q [0:7];

  generate
    for (b = 0; b < NB; b = b + 1) begin : g_bank
      (* ram_style = "distributed" *) reg [31:0] mem [0:BW-1];
      wire scalar_push = push_fire & ~push_nyq & (brev_w[2:0] == b);
      // Keep scalar I/O single-cycle; algorithm writes end at an output register.
      always @(posedge clk_i) begin
        wr_adr_q[b] <= wr_adr[b];
        wr_dat_q[b] <= wr_dat[b];
        if (scalar_push) mem[brev_w[8:3]] <= scalar_i;
        else if (wr_en_q[b] && keep_i) mem[wr_adr_q[b]] <= wr_dat_q[b];
      end
      always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) wr_en_q[b] <= 1'b0;
        else wr_en_q[b] <= wr_en[b] & ~in_idle & keep_i;
      end
      assign bq_a[b] = mem[rd_a_word];
      assign bq_b[b] = mem[rd_b_word];
    end
  endgenerate

  wire [31:0] q_a [0:7];      // 读相：组合，直接来自 RAM 的异步读口
  wire [31:0] q_b [0:7];
  generate
    for (g = 0; g < 8; g = g + 1) begin : g_q
      // lane g 读到的是**槽 g**（bank g、窗口内偏移 g）—— 因为窗口 8 对齐
      assign q_a[g] = in_rev&&sparse_q&&(kk<INV_BAND_LO||kk>=INV_BAND_LO+INV_BAND_COUNT)?32'b0:bq_a[g];
      // ⚠ 反向拆分也走 `bq_b`。它进来时 stage_q = 0（mode8 = 0），若不加
      //   `in_rev` 这一项，mode4 那条 `q_a[bsrc[g]]` 会**安静地**接管 b 路，
      //   而 bsrc 来自 FFT 地址发生器 —— 反向拆分读到的就是一格随便什么的
      //   数据。指纹：512 条输出全错，但每条都"像个相关序列"。
      assign q_b[g] = in_rev&&sparse_q&&(mm<INV_BAND_LO||mm>=INV_BAND_LO+INV_BAND_COUNT)?32'b0:
                     (mode8 | in_rev) ? bq_b[g] : q_a[bsrc[g]];
    end
  endgenerate

  // ══ 读相 → 算相的一级流水（见 issues/062）══════════════════════════════
  // 分布式 RAM 的**异步读**换来 mode4 一拍一组，代价是「地址 → 读 → 复乘 → 加
  // → 写」全压一拍（实测 25.7 ns / 17 个 CARRY4 + 2 个 DSP48E1，issues/061 §6）。
  // 这里把 a 槽 / b 槽 / 旋转因子寄存一拍，算相用**延迟一拍的控制**（`*_d`）去写。
  //
  // ⚠ 拍数几乎不涨（9 级共 +9 拍），靠的是：同级内每个元素只被碰一次、且
  //   **相邻两组的地址交集为空** ⇒ 第 n+1 组的读能与第 n 组的写同拍。
  //   **只有级边界没有这个性质** —— 少了 `flush_q` 那一拍，上一级最后一条写
  //   就会污染下一级第一组的读。这是这一改唯一不能省的地方。
  reg [31:0] qa_q [0:7], qb_q [0:7], twq [0:7];
  reg        own_d [0:7];
  reg        flush_q;                        // 级边界：只落盘、不读的那一拍
  reg        drain_q;                        // Output-register writeback needs two drain cycles.
  reg [8:0]  wa_d, wb_d;
  reg [2:0]  half_d;
  reg        phase_d, mode8_d, valid_d;
  reg wr_run,wr_split,wr_rev;
  reg [8:0]  spl_d, kk_d, mm_d;
  reg        same_bank_d, spl_m_wr_d;
  reg [8:0]  rev_a_d, rev_b_d;               // 反向拆分的读/写索引（延迟一拍）
  reg        two_out_d, rev_same_d, rev_m_wr_d;

  // 读相那一拍**发起了一次有效操作**吗（级边界的 flush 拍不算）
  wire rd_valid = (state_q == ST_RUN) & ~flush_q;



  wire in_rev_d = wr_rev;

  generate
    for (g = 0; g < 8; g = g + 1) begin : g_pipe
      always @(posedge clk_i) begin
        qa_q[g] <= q_a[g];
        qb_q[g] <= q_b[g];
        twq[g]  <= tw[g];
        own_d[g] <= own[g];
      end
    end
  endgenerate

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      wa_d <= 9'd0; wb_d <= 9'd0; half_d <= 3'd0;
      phase_d <= 1'b0; mode8_d <= 1'b0; valid_d <= 1'b0;
      wr_run<=0;wr_split<=0;wr_rev<=0;
      spl_d <= 9'd0; kk_d <= 9'd0; mm_d <= 9'd0;
      same_bank_d <= 1'b0; spl_m_wr_d <= 1'b0;
      rev_a_d <= 9'd0; rev_b_d <= 9'd0;
      two_out_d <= 1'b0; rev_same_d <= 1'b0; rev_m_wr_d <= 1'b0;
    end else begin
      wa_d   <= wa;
      wb_d   <= wb;
      half_d <= 3'd1 << stage_q[2:0];
      phase_d <= phase_q;
      mode8_d <= mode8;
      // 拆分与反向拆分都没有 flush 拍（它们各靠一个 *_D 状态落盘）
      valid_d <= rd_valid | (state_q == ST_SPLIT) | (state_q == ST_REVSPLIT);
      wr_run<=(state_q==ST_RUN);wr_split<=(state_q==ST_SPLIT);wr_rev<=(state_q==ST_REVSPLIT);
      spl_d <= spl_q; kk_d <= kk; mm_d <= mm;
      same_bank_d <= same_bank; spl_m_wr_d <= spl_m_wr;
      rev_a_d <= rev_a; rev_b_d <= rev_b;
      two_out_d <= two_out; rev_same_d <= rev_same; rev_m_wr_d <= rev_m_wr;
    end
  end

  // ── 蝶形数据通路（每 lane 一个复数乘）—— 操作数一律用**寄存过**的那份 ──
  wire signed [15:0] ar [0:7], ai [0:7], br [0:7], bi [0:7];
  wire signed [15:0] wr [0:7], wi [0:7];
  wire signed [31:0] tr [0:7], ti [0:7];
  wire signed [15:0] a2r [0:7], a2i [0:7];   // a 的新值
  wire signed [15:0] b2r [0:7], b2i [0:7];   // b 的新值

  generate
    for (g = 0; g < 8; g = g + 1) begin : g_dp
      assign ar[g] = qa_q[g][15:0];
      assign ai[g] = qa_q[g][31:16];
      assign br[g] = qb_q[g][15:0];
      assign bi[g] = qb_q[g][31:16];
      assign wr[g] = twq[g][15:0];
      assign wi[g] = twq[g][31:16];
      // 逆变换用共轭因子 —— C 那边就一行 `const int32_t wi = inv ? -wim : wim;`
      // （fw_fft.c 的 butterflies512）。两个乘式共用它，所以只改这一处。
      // Seventeen bits preserve conjugation of -32768 without a 32-bit multiplier.
      wire signed [16:0] wi_e = inv_q ? -({wi[g][15], wi[g]})
                                      :   {wi[g][15], wi[g]};
      // Q14 × Q15 >>> 14 —— 加 2^13 是四舍五入，与 C 的 `+ 8192 >> 14` 同
      assign tr[g] = (wr[g] * br[g] - wi_e * bi[g] + 32'sd8192) >>> 14;
      assign ti[g] = (wr[g] * bi[g] + wi_e * br[g] + 32'sd8192) >>> 14;
      assign a2r[g] = (ar[g] + tr[g] + 32'sd1) >>> 1;
      assign a2i[g] = (ai[g] + ti[g] + 32'sd1) >>> 1;
      assign b2r[g] = (ar[g] - tr[g] + 32'sd1) >>> 1;
      assign b2i[g] = (ai[g] - ti[g] + 32'sd1) >>> 1;
    end
  endgenerate

  // ── 跨拍寄存：算相算好、再下一拍才写回的那些值 ───────────────────────
  // mode8：a' 与 b' 要进**同一个 bank**，一个写口装不下 ⇒ 拆两拍写。
  //   a' 在算相写、b' 留一拍才写；到写 b' 那一拍操作数寄存器已被下一组覆盖，
  //   所以只能用算相寄存下来的这份。
  // 拆分：X[k] 与 X[m] 撞同一个 bank 时同理，X[m] 留一拍。
  // ⚠ 加了流水之后**"窗口被自己的写污染"这件事不存在了** —— 算相用的都是
  //   `qa_q/qb_q` 那份寄存值。这两个寄存器现在唯一的理由是**写口只有一个**。
  reg signed [15:0] b2r_q [0:7], b2i_q [0:7];
  reg signed [15:0] xr2_q, xi2_q;
  wire signed [15:0] xr, xi, xr2, xi2;
  wire [31:0] rz_k, rz_m;
  reg [15:0] rz_mr_q, rz_mi_q;

  generate
    for (g = 0; g < 8; g = g + 1) begin : g_b2q
      always @(posedge clk_i) begin
        if (valid_d & wr_run & mode8_d & ~phase_d) begin
          b2r_q[g] <= b2r[g];
          b2i_q[g] <= b2i[g];
        end
      end
    end
  endgenerate
  always @(posedge clk_i) begin
    if (valid_d & wr_split & ~phase_d & same_bank_d) begin
      xr2_q <= xr2;
      xi2_q <= xi2;
    end
  end

  // ── 写回端口：每 bank 恰好一个 ───────────────────────────────────────
  // mode8 两拍分别写 a' / b'；mode4 一拍里 a' 与 b' 落在**不同 bank**，
  // 所以每个 bank 每拍都只有一条写。
  generate
    for (g = 0; g < NB; g = g + 1) begin : g_wr
      wire [2:0] bh_d = gv[g] ^ half_d;
      // ⚠ 下面五条**全是延迟一拍的控制**（读相发起、算相落盘）。
      //   PUSH 那条不是 —— 它由核那边的 io_fire **组合**驱动，必须当拍落盘。
      wire w_m8a = valid_d & wr_run &  mode8_d & ~phase_d;   // mode8：写 a'
      wire w_m8b = valid_d & wr_run &  mode8_d &  phase_d;   // mode8：写 b'
      wire w_m4  = valid_d & wr_run & ~mode8_d;              // mode4：每 bank 一条
      wire w_kk  = valid_d & wr_split & ~phase_d & (kk_d[2:0] == gv[g]);
      wire w_mm  = valid_d & wr_split & (mm_d[2:0] == gv[g]) & spl_m_wr_d;
      // 反向拆分：写的是**位反转后**的索引（见上面 rev_a/rev_b 的说明）。
      wire w_rk  = valid_d & wr_rev & ~phase_d & (rev_a_d[2:0] == gv[g]);
      wire w_rm  = valid_d & wr_rev & (rev_b_d[2:0] == gv[g]) & rev_m_wr_d;

      // ⚠ PUSH 那一笔要挡掉第 513 条（逆变换的 ψ[512]）：它 ptr_idx=0、
      //   位反转地址是 0，不挡就会**静默覆盖** bin 0。
      assign wr_en[g]  = w_m8a | w_m8b | w_m4 | w_kk | w_mm | w_rk | w_rm |
                         (push_fire & ~push_nyq & (brev_w[2:0] == gv[g]));
      assign wr_adr[g] = w_m8b    ? wb_d[8:3] :
                         w_rm     ? rev_b_d[8:3] :
                         w_rk     ? rev_a_d[8:3] :
                         w_mm     ? mm_d[8:3] :
                         w_kk     ? kk_d[8:3] :
                         w_m4     ? wa_d[8:3] :
                         w_m8a    ? wa_d[8:3] :
                         in_idle  ? brev_w[8:3] : wa_d[8:3];  // ST_IDLE 只写 PUSH
      // ⚠ 拆分里 X[m] 有两条路：**不撞 bank** 时紧挨着 X[k] 下一拍写 ⇒ 用算相
      //   的组合值就够；**撞 bank** 时再晚一拍 ⇒ 只能用 `xr2_q/xi2_q`。
      //   两条路都用寄存值会写出上一个 k 的陈旧结果（指纹：
      //   bin 0..256 全对、257 以后全错）—— 与 053 那个坑指纹一样、根因不同。
      //   反向拆分的 z[m] 是同一个形状（rz_mr_q/rz_mi_q）。
      assign wr_dat[g] = w_m8b ? {b2i_q[g], b2r_q[g]} :   // 算相寄存的 b'
                         w_rm  ? (phase_d ? {rz_mi_q, rz_mr_q} : rz_m) :
                         w_rk  ? rz_k :
                         w_mm  ? (phase_d ? {xi2_q, xr2_q} : {xi2, xr2}) :
                         w_kk  ? {xi, xr} :
                         w_m8a ? {a2i[g], a2r[g]} :
                         w_m4  ? (own_d[g] ? {a2i[g], a2r[g]}
                                           : {b2i[bh_d], b2r[bh_d]}) :
                                 scalar_i;                // PUSH
    end
  endgenerate

  // ── 拆分 / 反向拆分共用的两个源操作数 ────────────────────────────────
  // 拆分（正变换）：zk = z[kk]、zm = z[mm]，自然序下标 kk_d / mm_d
  // 反向拆分（逆）：zk = ψ[kk]、zm = ψ[mm]，位反转下标 rev_a_d / rev_b_d
  // 两步从不同时活跃 ⇒ 这**是同一个** 8 选 1 多路器，不是两份。
  // ⚠ 这里读的是**寄存过的** bank 输出 + 延迟一拍的下标 —— 两步都走同一条
  //   流水（读相发起、算相落盘），否则它们的组合通路会成为新的 WNS。
  wire [2:0] rd_a_sel = in_rev_d ? rev_a_d[2:0] : kk_d[2:0];
  wire [2:0] rd_b_sel = in_rev_d ? rev_b_d[2:0] : mm_d[2:0];
  wire [31:0] zk = qa_q[rd_a_sel];
  wire [31:0] zm = qb_q[rd_b_sel];
  // ⚠ ψ[512]（Nyquist）不在数组里（数组只有 0..511），只有 k=0 那一对用得到。
  //   那一对的第二个操作数必须走 in_nyq_q —— 数组里 brev(0)=0 存的是 ψ[0]，
  //   拿它冒充 ψ[512]，z[0] 会**安静地**算错，而后面 511 条看起来全都正常。
  wire [31:0] rv_b = (in_rev_d & (kk_d == 9'd0)) ?
    (sparse_q&&INV_BAND_LO+INV_BAND_COUNT<=512?32'b0:in_nyq_q) : zm;

  wire signed [15:0] zkr = zk[15:0],   zki = zk[31:16];
  wire signed [15:0] zmr = rv_b[15:0], zmi = rv_b[31:16];

  // ⚠⚠ 中间和必须落在 **32 位上下文**里。写成 `wire signed [15:0] er = (zkr + zmr) >>> 1;`
  //   时上下文宽度是 16，**加法先溢出再移位**，而 C 那边是 int32_t。
  //   实测（build/tmp_sem/t.v，iverilog，2026-10-07）：zkr = zmr = 30000 时
  //   16 位上下文给 er = −2768，C 给 30000，**差一倍**。
  //   这条在这里潜伏了很久：现有 TB 的帧幅度小，两个操作数一直没同时越过
  //   16384。见 docs/issues/087。
  wire signed [31:0] zkr32 = zkr, zki32 = zki, zmr32 = zmr, zmi32 = zmi;
  wire signed [15:0] er  = ((zkr32 + zmr32) >>> 1);
  wire signed [15:0] ei  = ((zki32 - zmi32) >>> 1);
  wire signed [15:0] orr = ((zki32 + zmi32) >>> 1);
  wire signed [15:0] oi  = ((zmr32 - zkr32) >>> 1);
  wire signed [15:0] er2  = ((zmr32 + zkr32) >>> 1);
  wire signed [15:0] ei2  = ((zmi32 - zki32) >>> 1);
  wire signed [15:0] orr2 = ((zmi32 + zki32) >>> 1);
  wire signed [15:0] oi2  = ((zkr32 - zmr32) >>> 1);

  // ── 复乘：正变换与反向拆分**共用这 8 个乘法器** ──────────────────────
  // 两边的因子是同一对（twq[0] / twq[1]），只有被乘的数据不同 ⇒ 靠 in_rev_d
  // 换数据，而不是再挂 8 个 DSP48。四种符号组合一次算完，两边各取一半。
  //
  // 读法对照（lane a 一列，lane b 把 orr→orr2、oi→oi2 照搬）。记 p_XY = w_X · d_Y：
  //     正变换   被乘数 (orr, oi)  ⇒ Re = p_rr − p_ii，Im = p_ir + p_ri
  //     反向拆分 被乘数 (hr,  hi)  ⇒ Re = p_rr + p_ii，Im = **p_ri − p_ir**
  //   而 hi = (zki+zmi)>>>1 = orr、hr = (zkr−zmr)>>>1 = oi2 —— **就是同一对
  //   寄存器**，只是被当成实部/虚部的位置对调了。所以不需要新的加减法器。
  //
  //   ⚠ 虚部那一项在反向拆分里是 p_ri − p_ir（**不是** p_ir − p_ri）。
  //     C 写的是 `oi = (hi*wr − hr*wi + r) >> 14`，而 hi 乘的是 wr、hr 乘的是 wi
  //     —— 两个被乘数的位置与正变换正好对调。写成 p_ir − p_ri 时，输出从
  //     第 0 条起就只差 1 个 LSB（k=0 处 wi = 0，符号错得最干净），
  //     看起来"几乎全对"，只有逐位比才抓得住。
  //   ⚠ C 那边是 `qi = -psi[2m+1]`（虚部取负），ei/hi 两式里的符号已经在
  //     er/ei/orr/oi 的减号里了，别再加一次。
  wire signed [15:0] m_ar = in_rev_d ? oi2  : orr;
  wire signed [15:0] m_ai = in_rev_d ? orr  : oi;
  wire signed [15:0] m_br = in_rev_d ? oi   : orr2;
  wire signed [15:0] m_bi = in_rev_d ? orr2 : oi2;

  wire signed [15:0] swr = twq[0][15:0],  swi = twq[0][31:16];
  wire signed [15:0] swr2 = twq[1][15:0], swi2 = twq[1][31:16];
  wire signed [31:0] p_rr = swr  * m_ar, p_ri = swr  * m_ai;
  wire signed [31:0] p_ir = swi  * m_ar, p_ii = swi  * m_ai;
  wire signed [31:0] q_rr = swr2 * m_br, q_ri = swr2 * m_bi;
  wire signed [31:0] q_ir = swi2 * m_br, q_ii = swi2 * m_bi;

  wire signed [31:0] str  = ((in_rev_d ? (p_rr + p_ii) : (p_rr - p_ii)) + 32'sd8192) >>> 14;
  wire signed [31:0] sti  = ((in_rev_d ? (p_ri - p_ir) : (p_ir + p_ri)) + 32'sd8192) >>> 14;
  wire signed [31:0] str2 = ((in_rev_d ? (q_rr + q_ii) : (q_rr - q_ii)) + 32'sd8192) >>> 14;
  wire signed [31:0] sti2 = ((in_rev_d ? (q_ri - q_ir) : (q_ir + q_ri)) + 32'sd8192) >>> 14;

  // ⚠ (er + str) 同样要在 32 位上下文里算：er 是 16 位、str 是 32 位，混进一个
  //   16 位上下文会先把 str 截到 16 位再相加。C 那边写的是 (int16_t)((er+tr)>>1)
  //   ⇒ **截断到低 16 位**，所以这里最后取 [15:0] 与 C 一字不差。
  wire signed [31:0] xr_s  = ({{16{er[15]}},   er}  + str)  >>> 1;
  wire signed [31:0] xi_s  = ({{16{ei[15]}},   ei}  + sti)  >>> 1;
  wire signed [31:0] xr2_s = ({{16{er2[15]}},  er2} + str2) >>> 1;
  wire signed [31:0] xi2_s = ({{16{ei2[15]}},  ei2} + sti2) >>> 1;
  assign xr = xr_s[15:0], xi = xi_s[15:0];
  assign xr2 = xr2_s[15:0], xi2 = xi2_s[15:0];

  // 反向拆分的产出：z[k] = (er − oi) + j(ei + orr)，oi = sti、orr = str。
  // C 存进 int16_t ⇒ 取低 16 位。（同一对 str/sti 在正变换里是 X[k] 的修正项。）
  wire signed [31:0] rz_kr = er  - sti;
  wire signed [31:0] rz_ki = ei  + str;
  wire signed [31:0] rz_mr = er2 - sti2;
  wire signed [31:0] rz_mi = ei2 + str2;
  assign rz_k = {rz_ki[15:0], rz_kr[15:0]};
  assign rz_m = {rz_mi[15:0], rz_mr[15:0]};

  // 反向拆分里 z[m] 撞 bank 时要留到第 1 拍写，那份值只能从这里寄存。
  always @(posedge clk_i) begin
    if (valid_d & wr_rev & ~phase_d & rev_same_d) begin
      rz_mr_q <= rz_mr[15:0];
      rz_mi_q <= rz_mi[15:0];
    end
  end

  wire [31:0] pop_rdata = pop_is_nyq ? nyq_q : bq_a[ptr_idx[2:0]];
  // Nyquist 的算式（由 ST_SPLIT 的**算相**拍捕获，见下面 FSM 里那一条）
  wire signed [31:0] nyq_s  = ({{16{er[15]}}, er} - {{16{orr[15]}}, orr}) >>> 1;
  wire [31:0] nyq_nx = {16'b0, nyq_s[15:0]};

  always @(posedge clk_i or negedge rst_n_i) begin
    if (!rst_n_i) begin
      state_q <= ST_IDLE;
      phase_q <= 1'b0;
      flush_q <= 1'b0;
      drain_q <= 1'b0;
      stage_q <= 4'd0;
      cyc_q   <= 7'd0;
      ptr_q   <= 10'd0;
      spl_q   <= 9'd0;
      nyq_q   <= 32'd0;
      in_nyq_q <= 32'd0;
      inv_q   <= 1'b0;
      sparse_q <= 1'b0;
    end else begin
      // Nyquist（bin 512）在 k=0 那一对的**算相**拍算出：
      // W^512 = −1 ⇒ X[512] = (E[0] − O[0]) >>> 1，纯实。
      // ⚠ 判据是**延迟一拍**的 `spl_d` —— 加了流水之后 k=0 的结果要下一拍才出来。
      if (valid_d & wr_split & (spl_d == 9'd0)) nyq_q <= nyq_nx;

      // 模式锁存：PUSH/POP 用**组合**的 inv_i（当拍就要选地址），
      // RUN 之后的 ST_RUN / 反向拆分是几十上百拍，只能用锁存值。
      if (io_fire | run_start) inv_q <= inv_i;
      if (run_start) sparse_q <= INV_BAND_COUNT<513 && sparse_inv_i===1'b1;
      // 逆变换的第 513 条输入（ψ[512]）：写口那边已经挡掉了，这里只收着。
      if (push_nyq) in_nyq_q <= scalar_i;

      case (state_q)
        // ── 单拍搬运 ────────────────────────────────────────────────
        ST_IDLE: begin
          if (is_io_i) begin
            if (io_fire) begin
              if (io_sel_i == 1'b0) begin
                // PUSH：**按位反转后的地址**落盘（写口在 g_wr 那一段）——
                // 这样 9 级蝶形全是自然序，不用单独走一遍置换（那要多一次
                // 全数组读写）。逆变换也一样：索引 j 存的是 ψ[brev(j)]，
                // 反向拆分照样按 brev 取用。
                // ⚠ 逆变换有 **513** 条（bin 0..512），所以回绕点是 512 不是 511。
                ptr_q <= inv_i ? ((ptr_q == 10'd512) ? 10'd0 : (ptr_q + 1'b1))
                               : ((ptr_idx == (M - 1)) ? 10'd0 : (ptr_q + 1'b1));
              end else if (io_seek_i) begin
                // Pointer-only instruction avoids a decode-to-RAM address bypass.
                ptr_q <= inv_i ? {1'b0,scalar_i[8:0]} :
                         (scalar_i[9:0] <= 10'd512 ? scalar_i[9:0] : 10'd0);
              end else begin
                // POP：正变换 0..512，512 → 回 0（可重复读）；逆变换只出 512 条。
                ptr_q <= inv_q ? ((ptr_q == (M - 1)) ? 10'd0 : (ptr_q + 1'b1))
                               : (pop_is_nyq ? 10'd0 : (ptr_q + 1'b1));
              end
            end
          end else if (start_i) begin
            stage_q <= 4'd0;
            cyc_q   <= 7'd0;
            phase_q <= 1'b0;
            flush_q <= 1'b0;
            drain_q <= 1'b0;
            spl_q   <= 9'd0;
            ptr_q   <= 10'd0;               // 结果从 bin 0 开始读
            // 逆变换先走反向拆分（ψ 513 条 → z 512 条），再进 9 级蝶形；
            // 正变换直接进蝶形。
            state_q <= inv_i ? ST_REVSPLIT : ST_RUN;
          end
        end

        // ── 9 级蝶形：mode4 一拍一组，mode8 两拍一组 ────────────────
        // ⚠ 每级末尾多一个 `flush_q` 拍**只落盘不读**：流水使最后一条写回晚
        //   一拍，而下一级第一组的读地址可能和它重叠（同级的相邻组不会，
        //   跨级会）。9 级共 +9 拍。
        ST_RUN: begin
          if (!keep_i) begin
            state_q <= ST_IDLE;
            phase_q <= 1'b0;
            flush_q <= 1'b0;
            drain_q <= 1'b0;
          end else if (flush_q) begin
            if (!drain_q) drain_q <= 1'b1;
            else begin
              drain_q <= 1'b0;
              flush_q <= 1'b0;
              phase_q <= 1'b0;
              cyc_q   <= 7'd0;
              if (mode8 & (stage_q == 4'd8)) state_q <= inv_q ? ST_DONE : ST_SPLIT;
              else                           stage_q <= stage_q + 4'd1;
            end
          end else if (mode8) begin
            if (phase_q) begin
              phase_q <= 1'b0;
              if (cyc_q == 7'd31) flush_q <= 1'b1;
              else                cyc_q   <= cyc_q + 7'd1;
            end else begin
              phase_q <= 1'b1;
            end
          end else begin
            if (cyc_q == 7'd63) flush_q <= 1'b1;
            else                cyc_q   <= cyc_q + 7'd1;
            // mode4 只到 stage 2，不会走到 8 —— 出级一律走上面的 flush 分支
          end
        end

        // ── 拆分：一拍一对镜像 bin；撞 bank 时多一拍 ────────────────
        ST_SPLIT: begin
          if (!keep_i) begin
            state_q <= ST_IDLE;
            phase_q <= 1'b0;
          end else if (~phase_q & same_bank) begin
            phase_q <= 1'b1;               // X[m] 留到第 1 拍写（撞同一个 bank）
          end else begin
            if (spl_q == 9'd256) begin
              spl_q   <= 9'd0;
              state_q <= ST_SPLIT_D;
            end else begin
              spl_q <= spl_q + 9'd1;
            end
            phase_q <= 1'b0;
          end
        end

        ST_SPLIT_D: begin
          if (!drain_q) drain_q <= 1'b1;
          else begin drain_q <= 1'b0; state_q <= ST_DONE; end
        end

        // ── 反向拆分（逆变换）：一拍一对 z[k]/z[m]；撞 bank 时多一拍 ──
        // 与 ST_SPLIT 是镜像结构：那边把 z 拆成 X，这边把 ψ 合成 z。
        // ⚠ 撞 bank 的判据要用 **brev 之后**的索引（rev_same），不是 kk/mm ——
        //   写的是 brev(k) 那个位置，bank 是 brev(k)[2:0]。
        ST_REVSPLIT: begin
          if (!keep_i) begin
            state_q <= ST_IDLE;
            phase_q <= 1'b0;
          end else if (~phase_q & rev_same) begin
            phase_q <= 1'b1;               // z[m] 留到第 1 拍写
          end else begin
            if (spl_q == 9'd256) begin
              spl_q   <= 9'd0;
              state_q <= ST_REV_D;
            end else begin
              spl_q <= spl_q + 9'd1;
            end
            phase_q <= 1'b0;
          end
        end

        // ⚠ 这一拍**不能省**：上一次迭代的写回在下一拍才落盘，而 ST_RUN 的
        //   第一组读地址（stage 0 的窗口 0..7）可能正好压在被写的那一格上。
        //   正变换那边 ST_SPLIT_D 起的是同一个作用。
        ST_REV_D: begin
          if (!drain_q) drain_q <= 1'b1;
          else begin
            drain_q <= 1'b0;
            state_q <= ST_RUN;
            stage_q <= 4'd0;
            cyc_q   <= 7'd0;
            flush_q <= 1'b0;
            phase_q <= 1'b0;
          end
        end

        ST_DONE: begin
          if (commit_i) state_q <= ST_IDLE;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end

  assign stall_o = (state_q == ST_RUN) | (state_q == ST_SPLIT) |
                   (state_q == ST_SPLIT_D) | (state_q == ST_REVSPLIT) |
                   (state_q == ST_REV_D) |
                   ((state_q == ST_IDLE) & start_i & ~is_io_i);
  assign done_o  = io_fire | (state_q == ST_DONE);
  assign result_o = io_fire & ~(io_sel_i & io_seek_i) ? pop_rdata : 32'd0;

endmodule
