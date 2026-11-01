/* PL 侧固件 —— 定位链的内核。
 *
 * 架构约定（README"PL 只做实时、多通道、强并行、确定性的事"）：
 *   固件在 RISC-V 上执行 FFT / GCC-PHAT / TDOA / SRP 空间扫描 / Beamforming，
 *   **不是**一堆自跑的自定义模块。自研 SIMD-MAC 与声学扩展指令的价值，
 *   体现在这些内核的 cycles/sample 上。
 *
 * 本文件是**标量基线**：纯 RV32I(M) 写出来，先把每一步的 cycles 量准。
 * 后面加 SIMD、再加声学扩展指令，对照的就是这条基线。
 *
 * 内核清单（每加一个就在 RES 里占一格，TB 对着看）：
 *   1. 点积 / FIR / 能量        —— §1，最基础的三条
 *   2. fft1024（实数 FFT）      —— §2，整条定位链的地基，见 fw_fft.c
 */
#include <stdint.h>

#include "fw_fft.h"
#include "fw_gcc.h"
#include "fw_srp.h"
#include "fw_das.h"
#include "fw_fir.h"
#include "fw_steer.h"
#include "fw_scene.h"
#include "fw_mem.h"

/* ── MMIO ──────────────────────────────────────────────────────────── */
/* 完成邮箱。⚠ 可被覆盖：sw/ps_only.c 把本文件整个编到 Cortex-A9 / x86 上，
   那里 0x4000 要么是别人的 OCM、要么根本不是映射内存（host 上直接段错误）。 */
#ifndef FW_MMIO_MBOX
#define FW_MMIO_MBOX    (*(volatile uint32_t *)0x4000u)
#endif
#define MMIO_MBOX       FW_MMIO_MBOX

/* ── 结果块与批量输出区的地址都在 fw_mem.h；这里只起个别名 ──────────── */
#define RES(i)          (*(volatile uint32_t *)(FW_RES_BASE + 4u * (i)))

/* ── cycle 计数器（CSR 0xC00）──────────────────────────────────────── */
/*
 * ⚠ 读出来之后**不能马上用**：CSR 读的结果没有前递，紧随其后的那条指令
 *   读到的是 x。实测证据（tb_fw_smoke 的第一版）：
 *
 *     rdcycle t4 / sub t4,t4,a7       ← 相隔 0 条 → 拿到 x
 *     rdcycle a7 / sub a7,a7,t5       ← 相隔 0 条 → 拿到 x
 *     rdcycle a2 / ... 6 条 ... / sub ← 相隔 6 条 → 正确
 *
 *   所以这里在 csrr 后面塞六条 nop，把使用推后。写成 `addi %0,%0,0` ×3 是错的：
 *   它**依赖** %0，只会把 x 一路传下去，起不到「等一拍」的作用。
 *
 *   编译器不知道这条限制（它把 csrr 当普通的 CSR 读），所以只能在这里兜住。
 *   根治要在核的 CSR 路径上加前递，见 docs/issues/030。
 */
/* rdcycle 已提到 fw_scene.h（fw_gsc.c 也要用）*/

/* ── 标量内核：后面每一条都要和它对比 ─────────────────────────────── */

/* 点积 —— FIR / 波束形成 / 互谱实部都是这个形状 */
static int32_t dot_scalar(const int16_t *a, const int16_t *b, int n)
{
    int32_t s = 0;
    for (int i = 0; i < n; i++) {
        s += (int32_t)a[i] * (int32_t)b[i];
    }
    return s;
}

/* FIR：y = Σ h[k]·x[n−k] */
static int16_t fir_scalar(const int16_t *x, const int16_t *h, int taps)
{
    int32_t s = 0;
    for (int k = 0; k < taps; k++) {
        s += (int32_t)h[k] * (int32_t)x[k];
    }
    /* 定点：Q15 系数，右移 15 */
    s >>= 15;
    if (s > 32767)  s = 32767;
    if (s < -32768) s = -32768;
    return (int16_t)s;
}

/* 能量 Σx² —— NLMS 的归一化项，对偶归约要把它和点积合成一条 */
static int32_t energy_scalar(const int16_t *x, int n)
{
    int32_t s = 0;
    for (int i = 0; i < n; i++) {
        s += (int32_t)x[i] * (int32_t)x[i];
    }
    return s;
}

/* ── 测试数据 ──────────────────────────────────────────────────────── */
#define NTAP 64
static int16_t g_x[NTAP];
static int16_t g_h[NTAP];

/* ── 测试输入 ──────────────────────────────────────────────────────── */
/*
 * 周期 64 的三角波（基波落在 bin 16）+ LCG 噪声，**纯整数**。
 * 三方（固件 / Python 模型 / TB）必须照抄同一段 —— 一旦有一边用了浮点或
 * 不同的取整，比对就从「逐位相等」退化成「看着差不多」。
 *
 * 幅度取到接近满幅（±24576）：灌小信号试不到中间级的溢出边界，
 * 而定点 FFT 出问题多半就出在边界上。
 *
 * 输入帧直接造在固定输出区 2（FW_OUT2_BASE）—— 见下面的 FRM 说明。
 */
#define LCG_A       1103515245u
#define LCG_C       12345u
#define LCG_SEED    0x12345678u

/* 第 m 个样点。抽出来是因为「带时延的通道」要按需重算其中的某一段。 */
static inline int16_t sample_at(uint32_t s, int m)
{
    int32_t noise = (int32_t)((s >> 16) & 0x3FFFu);   /* 0..16383 */
    int32_t ph = m & 63;
    int32_t tri = (ph < 32) ? (ph * 1024 - 16384) : (49152 - ph * 1024);
    return (int16_t)(tri + (noise - 8192));
}

/* 输入帧直接造在**固定输出区 2**（0x3080）里 —— 不是图省事，是 DTCM 只有
 * 16 KB：再留一块 2 KB 的帧缓冲就会把频谱缓冲挤出去（实测差 1.3 KB）。
 * 那块地方在算 R 之前是空闲的，而帧在两级 FFT 做完之后就没用了，
 * 时间上刚好错开。见 fw_mem.h 的地图。 */
#define FRM ((int16_t *)FW_OUT2_BASE)

static void make_frame(void)
{
    uint32_t s = LCG_SEED;
    for (int i = 0; i < FFT_N; i++) {
        s = s * LCG_A + LCG_C;                       /* uint32 回绕，与 Python 同 */
        FRM[i] = sample_at(s, i);
    }
}

/* 带时延的通道：FRM[n] = A[(n + delay) % N]，即这一路比 A **超前** delay 个样点。
 * GCC-PHAT 的峰值应落在 +delay —— 这是**不依赖任何生成物**的独立判据。
 *
 * ⚠ 不缓存 A（省一块 2 KB 帧缓冲）：n = 0..N−1−delay 那段下标连续，直接往下推
 *   LCG 即可；末尾 delay 个点要回卷到下标 0..delay−1，把 LCG 重置一次再推。
 *   「重置一次」写错成「每次重置」的话，末尾那几个点的噪声全一样 ——
 *   峰值还在，只是峰变钝，TB 不会报错。 */
static void make_frame_shifted(int delay)
{
    uint32_t s = LCG_SEED;
    for (int i = 0; i < delay; i++) s = s * LCG_A + LCG_C;
    for (int n = 0; n < FFT_N; n++) {
        int m = n + delay;
        if (m >= FFT_N) {
            m -= FFT_N;
            s = LCG_SEED;
            for (int i = 0; i < m; i++) s = s * LCG_A + LCG_C;
        }
        s = s * LCG_A + LCG_C;
        FRM[n] = sample_at(s, m);
    }
}

#define GCC_TEST_DELAY  7

/* SRP / 波束形成基线扫几对（与 python 的 pair_list()[:4] 同序）—— 见 fw_srp.h */
#define SRP_PAIRS_TEST  4
static int32_t  g_srp_p[SRP_GRID_N];
static int16_t  g_tau_dump[SRP_GRID_N];

static const int pi4_l[SRP_PAIRS_TEST] = { 0, 0, 0, 0 };
static const int pj4_l[SRP_PAIRS_TEST] = { 1, 2, 3, 4 };

/* 峰值格号 + 累加器校验和。校验和让 TB 能验一整个 P —— 不用为此再留一份 */
static void srp_argmax_sum(uint32_t *arg, uint32_t *sum)
{
    int32_t best = g_srp_p[0];
    uint32_t bi = 0, s = 0;
    for (int i = 0; i < SRP_GRID_N; i++) {
        if (g_srp_p[i] > best) { best = g_srp_p[i]; bi = (uint32_t)i; }
        s += (uint32_t)g_srp_p[i];
    }
    *arg = bi;
    *sum = s;
}

/* 造两路频谱（A 通道 + 超前 7 个样点的 B 通道）。DAS 与 GCC-PHAT 各要一次 ——
   中间那次互谱会把 g_xi 就地改写成 Ψ，所以第二遍必须重造。 */
static void build_pair_spectra(void)
{
    make_frame();
    gcc_load_a(FRM);
    make_frame_shifted(GCC_TEST_DELAY);
    gcc_load_b(FRM);
}

/* ── 一帧的链（逐帧抖动用，见 fw_plat.h 的 FW_JITTER_N）─────────────────
 * 与 README §35 的分段一一对应：
 *     正变换（2 次）→ 互谱/PHAT → 逆变换+峰值 → 定位扫描 → 定向增强 → 固定 FIR
 * ⚠ 与产品形态轮的链**同一段代码**，不是另写一遍 —— 否则量的是另一件事。 */
#if FW_JITTER_N > 0
/* 逐帧样本的落点。核上 .bss 只剩 16 B，放不下数组 ⇒ 默认 NULL（只留 min/max/sum）；
   A9（sw/ps_only.c）把它指到 DDR 上的数组，好算 P95/P99。 */
int32_t *fw_jit_trace;

static void frame_once(void)
{
    int32_t lag = 0;
    int p;
    build_pair_spectra();
    gcc_finish((volatile int16_t *)FW_OUT2_BASE, &lag);
    for (p = 0; p < SRP_PAIRS_TEST; p++) {
        srp_acc_pair((const int16_t *)FW_OUT2_BASE, pi4_l[p], pj4_l[p], g_srp_p);
    }
    fw_das_run();
    fw_fir_run(FW_HAVE_HW ? 1 : 0);
}
#endif

int main(void)
{
    /* ── 诊断探针（见 docs/issues/030）────────────────────────────────
     * 先给 16 个槽各写一个**可区分**的常量，最后再写真实结果。
     * 读回后三种结局各自说明什么：
     *   0xA5A5xxxx  → 探针写了、后续那笔丢了   → 与"写入时机"有关
     *   真实值       → 两笔都成功
     *   x           → 探针那笔就没写进去        → 与"地址"有关
     * 一次仿真就能把"地址坏"和"时序坏"彻底分开。
     */
    for (int i = 0; i < 16; i++) {
        RES(i) = 0xA5A50000u + (uint32_t)i;
    }

    /* 造一组确定的数据，TB 端能独立复算出期望值 */
    for (int i = 0; i < NTAP; i++) {
        g_x[i] = (int16_t)(i + 1);          /* 1..64，和 = 2080 */
        g_h[i] = (int16_t)(1 << 12);        /* Q15 下的 0.125 */
    }

    /* ── 1. 点积基线 ─────────────────────────────────────────────── */
    int32_t d = 0;
    uint32_t cyc_t0_dot = rdcycle();
    for (int r = 0; r < 64; r++) d = dot_scalar(g_x, g_h, NTAP);
    uint32_t cyc_t1_dot = rdcycle();
    uint32_t c_dot = cyc_t1_dot - cyc_t0_dot;

    /* ── 2. FIR 基线 ─────────────────────────────────────────────── */
    int16_t y = 0;
    uint32_t cyc_t0_fir = rdcycle();
    for (int r = 0; r < 64; r++) y = fir_scalar(g_x, g_h, NTAP);
    uint32_t cyc_t1_fir = rdcycle();
    uint32_t c_fir = cyc_t1_fir - cyc_t0_fir;

    /* ── 3. 能量基线 ─────────────────────────────────────────────── */
    int32_t e = 0;
    uint32_t cyc_t0_eng = rdcycle();
    for (int r = 0; r < 64; r++) e = energy_scalar(g_x, NTAP);
    uint32_t cyc_t1_eng = rdcycle();
    uint32_t c_eng = cyc_t1_eng - cyc_t0_eng;

    /* ── 4. FFT 基线（见 fw_fft.c）───────────────────────────────── */
    volatile int16_t *out = (volatile int16_t *)FW_OUT_BASE;
    make_frame();
    fft_init();
    fft1024(FRM, out);                /* 热身一次：第一趟有冷分支/写回差异 */
    uint32_t cyc_t0_fft = rdcycle();
    for (int r = 0; r < 2; r++) fft1024(FRM, out);
    uint32_t cyc_t1_fft = rdcycle();
    uint32_t c_fft = (cyc_t1_fft - cyc_t0_fft) / 2u;

    /* ── 4b. 硬件 VFFT：同一条链，换成核内单元算 ─────────────────────
     * 输出写回**同一块 .fwout**：两边逐位等价，所以 TB 那份 golden 对谁都成立。
     * 这样 tb_fw_fft 同时验了标量与硬件两条路。
     *
     * ⚠ FW_ACCEL=0 的基线镜像里没有硬件 VFFT（那正是它的定义），这一段整个
     *   不编 —— 结果块第 20 格留 0，PS 那边打印出来的 hardware= 就是 0。 */
    /* ⚠ 基线镜像（FW_ACCEL=0）里也走**同样多**的一次变换，只是用标量 ——
       两版的工作量必须一模一样，否则对照比的是"做得少"而不是"算得快"。 */
#if FW_HAVE_HW
    make_frame();                     /* 重新造帧（上面被就地在别处用过）*/
    uint32_t cyc_t0_hw = rdcycle();
    fft1024_hw(FRM, out);
    uint32_t cyc_t1_hw = rdcycle();
    uint32_t c_fft_hw = cyc_t1_hw - cyc_t0_hw;
#else
    make_frame();
    uint32_t cyc_t0_hw = rdcycle();
    fft1024(FRM, out);
    uint32_t cyc_t1_hw = rdcycle();
    uint32_t c_fft_hw = cyc_t1_hw - cyc_t0_hw;
#endif

    /* 峰值 bin —— 三角波周期 64 ⇒ 期望 16。整条链最容易一眼看出的指纹。
       ⚠ 平方和会溢出：|X| 到 3 万时平方就是 9e8，两条相加逼近 2^31。
         这里用 64 位中间量，不要图快用 int32。 */
    int32_t peak_v = -1;
    uint32_t peak_k = 0;
    for (int k = 0; k < FFT_NBIN; k++) {
        int32_t re = out[2 * k], im = out[2 * k + 1];
        int32_t v = re * re + im * im;
        if (v > peak_v) { peak_v = v; peak_k = (uint32_t)k; }
    }

    volatile int16_t *r_out = (volatile int16_t *)FW_OUT2_BASE;
    int32_t gcc_lag = 0;

    /* ── 5. 波束形成（DAS）基线 ──────────────────────────────────────
     * 频域 DAS 的功率展开与 SRP 是**同一个内核**：
     *     |Σ_i X_i e^{-jωτ_i}|² = Σ_ij R_ij(τ_i − τ_j)
     * 只差 R 做不做白化。所以这里复用 srp_acc_pair，只换一份 R ——
     * 换来的是一条**真在核上跑出来**的波束形成基线，而不是另写一遍。
     *
     * 顺序上 DAS 在前、GCC-PHAT 在后：两者共用输出区 2 和 P 累加器，而
     * TB 要验的是**白化那份 R**（tb_fw_gcc）与 **SRP 那份 P**（tb_fw_srp），
     * 必须留到最后。DAS 只留峰值格号 + 校验和（RES(16..18)）。 */
    srp_init();
    for (int i = 0; i < SRP_GRID_N; i++) g_srp_p[i] = 0;
    srp_dump_tau(0, 1, g_tau_dump);                  /* 供 TB 验几何 */

    build_pair_spectra();
    uint32_t t0x = rdcycle();
    (void)gcc_finish_raw(r_out);                     /* 互相关（不白化）*/
    uint32_t t1x = rdcycle();

    for (int i = 0; i < SRP_GRID_N; i++) g_srp_p[i] = 0;
    uint32_t t0d = rdcycle();
    for (int p = 0; p < SRP_PAIRS_TEST; p++) {
        srp_acc_pair((const int16_t *)FW_OUT2_BASE, pi4_l[p], pj4_l[p], g_srp_p);
    }
    uint32_t t1d = rdcycle();

    uint32_t c_xcorr   = t1x - t0x;
    uint32_t c_das     = (t1d - t0d) / (uint32_t)SRP_PAIRS_TEST;
    uint32_t das_arg   = 0;
    uint32_t das_sum   = 0;
    srp_argmax_sum(&das_arg, &das_sum);

    /* ── 6. GCC-PHAT 基线（见 fw_gcc.c）──────────────────────────── */
    /* 分三段计时再相加：中间那次「造 B 通道」是**造数据**，不是内核，
       不该算进去。分段计时的和与整段计时的差在 100 拍以内，可以忽略。 */
    make_frame();                         /* A 通道 → FRM */
    uint32_t t0a = rdcycle();
    gcc_load_a(FRM);                      /* 加窗 + FFT（**就地改写 FRM**）*/
    uint32_t t1a = rdcycle();

    make_frame_shifted(GCC_TEST_DELAY);   /* B 通道，超前 A 7 个样点 */
    uint32_t t0b = rdcycle();
    gcc_load_b(FRM);
    uint32_t t1b = rdcycle();

    uint32_t t0c = rdcycle();
    gcc_finish(r_out, &gcc_lag);          /* 互谱 + PHAT + 逆变换 + 峰值 */
    uint32_t t1c = rdcycle();

    uint32_t c_gcc = (t1a - t0a) + (t1b - t0b) + (t1c - t0c);

    /* ── 7. SRP 空间扫描基线（见 fw_srp.c）────────────────────────── */
    /* 用 GCC-PHAT 刚落下的 R（在输出区 2）当输入 —— 不另造一份，
       正好也把两个内核串成一条链。**4 对共用同一份 R**：这里量的是扫描的
       算力，不是定位精度（那需要真实的 8 通道数据）。 */
    for (int i = 0; i < SRP_GRID_N; i++) g_srp_p[i] = 0;

    uint32_t t0s = rdcycle();
    for (int p = 0; p < SRP_PAIRS_TEST; p++) {
        srp_acc_pair((const int16_t *)FW_OUT2_BASE, pi4_l[p], pj4_l[p], g_srp_p);
    }
    uint32_t t1s = rdcycle();
    uint32_t c_srp = (t1s - t0s) / (uint32_t)SRP_PAIRS_TEST;   /* 折算到**每对** */

    uint32_t p_arg = 0;
    uint32_t p_sum = 0;
    srp_argmax_sum(&p_arg, &p_sum);

    /* ── 落结果 ──────────────────────────────────────────────────── */
    RES(0)  = (uint32_t)d;                /* 点积结果 */
    RES(2)  = (uint32_t)(int32_t)y;       /* FIR 结果 */
    RES(4)  = (uint32_t)e;                /* 能量结果 */
    RES(7)  = (uint32_t)NTAP;
    RES(6)  = c_fft;                      /* 标量 FFT cycles/次 */
    RES(20) = c_fft_hw;                   /* 硬件 VFFT cycles/次 */
    RES(14) = peak_k;                     /* FFT 峰值 bin */

    RES(1)  = c_dot;                      /* 差值 */
    RES(3)  = c_fir;
    RES(5)  = c_eng;
    RES(8)  = c_gcc;                      /* GCC-PHAT 一对的 cycles */
    RES(9)  = (uint32_t)g_tau_dump;       /* τ 转储缓冲的**地址**（TB 按它去读）*/
    RES(10) = (uint32_t)g_srp_p;          /* P 累加器的地址 */
    RES(11) = c_srp;                      /* SRP 每对（256 格）的 cycles */
    RES(12) = p_arg;                      /* SRP 的 P 峰值格号 */
    RES(13) = (uint32_t)gcc_lag;          /* GCC-PHAT 峰值滞后（期望 +7）*/

    /* DAS：只留指纹（P 被 SRP 覆盖了，见上面顺序说明）*/
    RES(16) = c_xcorr;                    /* 互相关（不白化）cycles */
    RES(17) = das_arg;                    /* DAS 峰值格号 */
    RES(18) = das_sum;                    /* DAS 的 P 校验和 */
    RES(19) = c_das;                      /* DAS 每对（256 格）cycles */

    /* ── 7. DAS 波束形成器（真波束形成，不是上面那个 SRP 核指纹）──────────
     * 上面 §5 的 "DAS 基线" 只是拿不白化的 R 跑了一遍 SRP 核、留了峰值格号，
     * **不输出增强音频、也不能指向任意方向**。这里才是 §26.1 的
     * y[n] = Σ w_m x_m[n−τ_m]：按 θ̂ 的延迟把 8 路对齐后等权求和。
     * 放在最后：它不碰 FW_OUT/FW_OUT2，只写结果块 21 起的槽位。 */
    {
        uint32_t t0 = rdcycle();
        fw_das_run();
        uint32_t t1 = rdcycle();
        RES(DAS_RES_CYCLES) = t1 - t0;
    }

    /* Fixed FIR: same samples and coefficients for scalar and SIMD. */
    {
        uint32_t t0 = rdcycle();
#if FW_BENCH_ROUND
        fw_fir_run(0);
        AUDIO(4) = rdcycle() - t0;
#endif
        t0 = rdcycle();
        fw_fir_run(FW_HAVE_HW ? 1 : 0);
        AUDIO(5) = rdcycle() - t0;
    }

    /* ── 9. 转向闭环：SRP 峰值 → 硬件转向块 → 受控 DAS ────────────────
     * 这是「定位 → 定向增强」那根箭头的最后一节。前面 §7 的 DAS 用的是
     * fw_das_scene.h 里**编译期钉死在目标方向**的表 —— 它当然最好，但它
     * 和 SRP 报出来的方位没有任何关系，也就是箭头**没接上**。这一节把它接上：
     *   p_arg（§7 的 SRP 峰值格号）→ 写进转向块的 TARGET → 等它 commit →
     *   从 RDATA 窗口读 8 路 comp' → 按 comp'_ref − comp'_now 改延迟再跑一遍。
     *
     * 判据（TB 侧）：
     *   GRID     应该落在目标附近（目标 (0.12,−0.08) → gx=12, gy 卡在 4/5 正中，
     *            所以 76 或 92 都算对）—— 它证明**这个格号是从数据里算出来的**，
     *            不是写死的。
     *   CK_NOW   必须等于 golden（--dump), 这是块真的跑了、驱动真的读对了。
     *   DAS_PT/PO 与 §7 的 P_TARGET/P_OTHER 比：转向对了，两趟应当**很接近**；
     *            偏得远说明 D_m 拼错了（符号或口径）。
     * ⚠ 放在 §8 之后：它要 SRP 的 p_arg，也只写 FW_STEER_BASE，不碰
     *   结果块和两个输出区 —— 前面那些内核的指纹不会被它动。 */
    {
        int32_t comp_now[STEER_N_MIC];
        uint32_t ck = 0;
        int rc;
        int m;

        fw_steer_init();
        rc = fw_steer_query(p_arg, comp_now);

        for (m = 0; m < STEER_N_MIC; m++) {
            ck = (ck + (uint32_t)comp_now[m]) & 0xFFFFFFFFu;
        }
        STEER(STEER_RES_GRID)   = (int32_t)p_arg;
        STEER(STEER_RES_STATUS) = (rc == 0) ? 3 : 0;   /* bit0 OK / bit1 LOCKED */
        STEER(STEER_RES_CK_NOW) = (int32_t)ck;

        /* ⚠ 参照这一趟必须**先解包再累加**，与上面 CK_NOW 同口径。
           直接累加 g_steer_comp_ref 里打包的 14 位字是**不可比**的 ——
           那样 CK_REF 只是"常量表有没有被改"的自检，回答不了"硬件块这次报的
           comp 是不是等于目标方向的 comp"。解包后两个数可以直接对：查到的格号
           就是真目标方向时它们相等，差一格就差一点。 */
        ck = 0;
        for (m = 0; m < STEER_N_MIC; m++) {
            ck = (ck + (uint32_t)fw_steer_unpack14(
                          (uint32_t)(uint16_t)g_steer_comp_ref[m])) & 0xFFFFFFFFu;
        }
        STEER(STEER_RES_CK_REF) = (int32_t)ck;

        if (rc == 0) {
            uint32_t t0 = rdcycle();
            fw_das_run_steered(comp_now);
            uint32_t t1 = rdcycle();
            STEER(STEER_RES_CYCLES) = (int32_t)(t1 - t0);
        } else {
            STEER(STEER_RES_CYCLES) = 0;   /* 查询失败就不跑，留 0 让 TB 看得出来 */
        }
    }

    /* ── 10. 逐帧抖动（只在 FW_JITTER_N > 0 的构建里编）──────────────────
     * 把一帧的链连跑 N 次，量每次的拍数。README §36 的判据是
     *     J = T_max − T_min
     * 所以这里存 min/max/sum/N —— 核上只要 min == max 就说明 J = 0，
     * P95/P99 与均值三者相等，没有更多可说；A9 那边另有逐帧数组算百分位。
     *
     * ⚠ 这一段会覆盖 DAS/FIR 的结果槽（它俩每跑一次就写一次 RES）。
     *   所以**它是独立的计量构建**：这一版不跑声学验收的指纹判据
     *   （正确性由不带 FW_JITTER_N 的那一版负责）。见 docs/measurements.md §16。 */
#if FW_JITTER_N > 0
    {
        uint32_t jmin = 0xFFFFFFFFu, jmax = 0, jsum = 0, d = 0;
        int it;
        for (it = 0; it < FW_JITTER_N; it++) {
            const uint32_t a = rdcycle();
            frame_once();
            d = rdcycle() - a;
            if (d < jmin) jmin = d;
            if (d > jmax) jmax = d;
            jsum += d;
            if (fw_jit_trace) fw_jit_trace[it] = (int32_t)d;
        }
        STEER(0) = (int32_t)jmin;
        STEER(1) = (int32_t)jmax;
        STEER(2) = (int32_t)jsum;
        STEER(3) = (int32_t)FW_JITTER_N;
        STEER(4) = (int32_t)d;              /* 最后一次，便于看尾巴 */
    }
#endif

    RES(15) = 0xC0DE0001u;                /* 完成标记（放在最后，TB 等它）*/
    MMIO_MBOX = 0xC0DE0001u;

#ifndef FW_MAIN_RETURNS
    /* sw/ps_only.c 把本文件整个编进 Cortex-A9 的程序（`#define main`），那边
       要的是"跑完就返回"，好让外层量它的周期数。见 docs/issues/088。 */
    for (;;) {
        /* main 返回也没关系，start.S 里有死循环；这里显式停住更清楚 */
    }
#else
    return 0;
#endif
}
