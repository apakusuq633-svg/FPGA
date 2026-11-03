/* ps_diag_test.c —— 站 11 → 站 12 → 站 13 整条链的板载自检（**自成 app，跑在 CPU0**）
 *
 * ⚠ 本文件自带 main()（:296 调 run_chain），是一个独立 app，**不在站 15 的两核分工里**。
 *   站 15（sw/ps_ui.c）的 CPU1 走的是 ps_diag.h 的 dia_frame()，不调用本文件。
 *   （原注写的是"PS 侧，CPU1" —— 那时以为自检挂在 CPU1 上，去找会白找。）
 *
 * 它验证的**不是** PL 固件，而是 PS 侧自己的三段：
 *   站 11  sw/ps_features.h     波形 → 18 维
 *   站 12  sw/ps_classifier.h   18 维 → 类别
 *   站 13  sw/ps_output.h       类别 + 方位 + 严重程度 → 一行 ASCII
 *
 * -- 它证明什么、不证明什么 -----------------------------------------------------------------
 *
 * 证明（都是精确的，没有容差）：
 *   1. 站 11 建出来的 H 掩码口径对：b1=295、b2=966、带内 672 个 2.0、**DC 与 Nyquist 是 0**。
 *      这四个数就是从 fs=39062.5、N=8192、带 1400-4600 推出来的。
 *      ⚠ 这条能抓住"有人改了带宽或 N 却没重训模型"这类静默错误。
 *   2. 站 13 的整数助手对：格号拆格、归一化方位、越界拒绝。
 *   3. 整条链在板上跑得通，打出来的行是格式正确的 ASCII，票数合计 = CLF_N_TREE。
 *   4. 站 11 一帧的真实耗时（A9 全局计时器，1 拍 3 ns）。这一条只有在板上才量得到。
 *
 * **不**证明：分类准确率。这一帧是程序自己造的合成信号，不在训练分布里
 *   （噪声是 LCG 均匀噪声不是高斯，转速和相位都对不齐），所以它报出的类别**不作为判据**，
 *   只打出来给人看。站 11/12 的正确性判据在宿主机上：
 *     - 18/18 维与 MATLAB 逐位一致（build/scratch/gen_feat_golden.m + feat_host_check.c）
 *     - 4 段分布内样本 4/4 报对（build/scratch/gen_feat_chain4.m + chain_host_check.c）
 *   板载这一条是"能跑、能打"，不是"报得对"。
 *
 * -- 内存 -----------------------------------------------------------------------------------
 * 站 11 自己 5 条 8192 double（320 KB）+ twiddle 2 × 4096 double（64 KB）+ 本文件的
 * 合成帧 40000 double（320 KB）= 约 700 KB，全在 DDR（static / .bss）。
 * **别往 DTCM 里放** —— DTCM 只有 16 KB，而且 PL 固件在用。
 */

#include <stdint.h>

#include "xil_io.h"
#include "xil_printf.h"

#include "ps_features.h"
#include "ps_classifier.h"
#include "ps_output.h"

/* Cortex-A9 全局计时器，FCLK/2 = 333 MHz ⇒ 1 拍 3 ns。只用低 32 位：
 * 12.9 s 才回绕，本程序远用不到，无符号减法跨回绕也是对的。 */
#define GTIMER_BASE      0xF8F00200u
#define GTIMER_LO_OFF    0x00u
#define GTIMER_CTL_OFF   0x08u

/* RV32 的 AXI 窗口。DTCM 不是 PS 能按物理地址直接读的 —— 得写 R_MEM_ADDR 选中，
 * 再从 R_MEM_RDATA 取。地址字段是**字下标**（字节地址 >> 2）并与选中位或在一起。 */
#define RV32_BASE        0x43C00000u
#define R_MEM_ADDR       0x080u
#define R_MEM_RDATA      0x088u
#define MEM_SEL_DTCM     0x80000000u

/* PL 固件的结果区，见 sw/fw/fw_mem.h 的 FW_STEER_BASE = 0x3C60。
 * 这里写死地址是和 sw/ps_main.c 一样的做法（它读 dtcm(0x3C60)）——
 * PS 侧不 include PL 固件的头，免得把两边的地址绑死。 */
#define DTCM_STEER_STATUS 0x3C60u    /* STEER_RES_STATUS：bit0 = 查询成功, bit1 = LOCKED */
#define DTCM_STEER_GRID   0x3C70u    /* STEER_RES_GRID：SRP 峰值格号 */

/* PL 侧 SRP 网格的边长，权威定义在 sw/fw/fw_srp.h（SRP_GRID_W = 16）。
 * 站 13 故意不写死这个数（它把 grid_w 当参数收），由调用方在这儿给。 */
#define PL_SRP_GRID_W    16

#define FRAME_N          40000       /* 1.024 s @ 39062.5 Hz，与训练脚本同口径 */
#define FRAME_FS         39062.5

static int g_fail;

static void check(int cond, const char *what)
{
    xil_printf("%s %s\r\n", cond ? "OK  " : "FAIL", what);
    if (!cond) {
        g_fail++;
    }
}

static uint32_t gtimer_now(void)
{
    return Xil_In32(GTIMER_BASE + GTIMER_LO_OFF);
}

static uint32_t dtcm(uint32_t byte_addr)
{
    Xil_Out32(RV32_BASE + R_MEM_ADDR, MEM_SEL_DTCM | (byte_addr >> 2));
    return Xil_In32(RV32_BASE + R_MEM_RDATA);
}

/* ------------------------------------------------------------------------------------------
 * 相位累加器。
 *
 * d_sincos 的契约是 |th| < 2*pi（只做两步归约，够四个象限用，见它的注释）。
 * 而本文件的相位是 2*pi*f*t，t 到 1.024 s 就有上万弧度 —— 直接把 th 交出去是在用它的
 * 文档之外，误差不再有保证。所以相位自己攒：每步加一个增量、超了就减一圈，
 * 相位恒在 [0, 2*pi)，而每一步的舍入是 ulp(2*pi) 量级、不随 t 放大。
 *
 * 也可以写成"先对 2*pi 取模再交给 d_sincos"，但那是**错**的：th=19300 时
 * th - 2*pi 每减一次就丢几位，减三千次比不归约还差。
 * ------------------------------------------------------------------------------------------ */
static double ph_wrap(double ph)
{
    const double TWO_PI = 6.283185307179586232;
    while (ph >= TWO_PI) { ph -= TWO_PI; }
    while (ph < 0.0)     { ph += TWO_PI; }
    return ph;
}

/* ------------------------------------------------------------------------------------------
 * 合成一段轴承样信号。**不是**训练分布里的样本，只用来说明链子跑得通。
 *
 * 共振用双极点谐振器，不用 exp()：y[n] = 2r*cos(w0)*y[n-1] - r^2*y[n-2] + a[n] 的冲激响应
 * 正好是 r^n*sin(w0 n)，而链接行没有 -lm（exp 拿不到）。
 *   r = exp(-500/fs) = 0.98728157159029051 —— 和训练脚本的 exp(-500*tau) 同一个衰减率
 * 内圈故障：每 288 个样点一次冲击（= 135.63 Hz ≈ BPFI 5.428 x 25 Hz），
 * 幅度被转频 25 Hz 调制（1 + 0.8*cos(2*pi*f_r*t)），与训练脚本 synth_segment 的 cls=3 同形。
 * ------------------------------------------------------------------------------------------ */
static void synth_frame(double *x, int n)
{
    const double TWO_PI  = 6.283185307179586232;
    const double r       = 0.98728157159029051;
    const double r2      = 0.97472490160179392;          /* r*r */
    const int    P_IMP   = 288;                          /* 冲击间隔（样点） */

    const double dph_r   = TWO_PI * 25.0 / FRAME_FS;      /* 转频 */
    const double dph_2r  = 2.0 * dph_r;                   /* 2 倍转频 */
    const double dph_imp = dph_r * (double)P_IMP;         /* 冲击调制的相位步进 */

    double ph_r = 0.0, ph_2r = 0.0, ph_imp = 0.0;
    double y1 = 0.0, y2 = 0.0;
    double a1, s, c;
    uint32_t lcg = 12345u;
    int i;

    /* 谐振器的 2r*cos(w0)。w0 = 2*pi*3000/fs 在 2*pi 以内，直接调就够了 */
    d_sincos(TWO_PI * 3000.0 / FRAME_FS, &s, &c);
    a1 = 2.0 * r * c;

    for (i = 0; i < n; i++) {
        double drive = 0.0, y, base, u;

        if (i % P_IMP == 0) {                 /* 冲击起点 */
            d_sincos(ph_imp, &s, &c);
            drive = 1.0 + 0.8 * s;
            ph_imp = ph_wrap(ph_imp + dph_imp);
        }

        y = a1 * y1 - r2 * y2 + drive;
        y2 = y1;
        y1 = y;

        d_sincos(ph_r, &s, &c);
        base = 0.05 * s;
        d_sincos(ph_2r, &s, &c);
        base += 0.02 * s;
        ph_r  = ph_wrap(ph_r + dph_r);
        ph_2r = ph_wrap(ph_2r + dph_2r);

        /* LCG 均匀噪声（RMS ≈ 0.087）：只是让包络谱有个底噪，不是高斯白噪 */
        lcg = lcg * 1103515245u + 12345u;
        u = ((double)((lcg >> 8) & 0xFFFFFFu) / 16777216.0) - 0.5;

        x[i] = y + base + 0.3 * u;
    }
}

/* ------------------------------------------------------------------------------------------
 * 站 11 setup 的口径自检。
 * b1/b2 是这套参数的指纹：fs 变了、N 变了、带宽变了，这两个数都会动。
 * ------------------------------------------------------------------------------------------ */
static void check_feature_setup(void)
{
    int i, n2 = 0, bad = 0;

    for (i = 0; i < PS_FEAT_NFFT; i++) {
        if (fea_H[i] == 2.0) {
            n2++;
        } else if (fea_H[i] != 0.0) {
            bad++;
        }
    }

    /* df 是 double，xil_printf 又没有 %f —— 报成毫赫兹的整数 */
    xil_printf("fea: b1=%u b2=%u df_mHz=%u n2=%u bad=%u\r\n",
               (unsigned)fea_b1_g, (unsigned)fea_b2_g,
               (unsigned)(fea_df_g * 1000.0), (unsigned)n2, (unsigned)bad);

    check(fea_b1_g == 295 && fea_b2_g == 966, "station 11 band edges are the trained ones");
    check(n2 == 672 && bad == 0, "station 11 mask is exactly 672 bins of 2.0");

    /* DC 和 Nyquist 必须是 0 —— 这正是站 11 与站 9 的 H 分岔的那两个 bin。
     * 单列一条是因为它俩"看着都像低通"，改错了不会报错，只会让包络不是训练时那条。 */
    check(fea_H[0] == 0.0 && fea_H[PS_FEAT_NFFT / 2] == 0.0,
          "station 11 mask is zero at DC and Nyquist (not station 9's mask)");
}

/* ------------------------------------------------------------------------------------------
 * 站 13 的整数助手。纯整数，结果可以写死，不需要容差。
 * ------------------------------------------------------------------------------------------ */
static void check_output_helpers(void)
{
    int gx, gy;

    check(out_split_grid(53, PL_SRP_GRID_W, &gx, &gy) == 1 && gx == 5 && gy == 3,
          "grid 53 -> cell (5,3)");
    check(out_split_grid(0, PL_SRP_GRID_W, &gx, &gy) == 1 && gx == 0 && gy == 0,
          "grid 0 -> cell (0,0)");
    check(out_split_grid(255, PL_SRP_GRID_W, &gx, &gy) == 1 && gx == 15 && gy == 15,
          "grid 255 -> cell (15,15)");
    check(out_split_grid(256, PL_SRP_GRID_W, &gx, &gy) == 0,
          "grid 256 is rejected (out of range, not silently clamped)");
    check(out_split_grid(0, 0, &gx, &gy) == 0, "grid_w 0 is rejected");

    check(out_azim_pct(0, 16) == -100 && out_azim_pct(15, 16) == 100,
          "azimuth spans the scan plane ends");
    check(out_azim_pct(1, 16) == -87, "azimuth is the same linear map fw_srp.c builds");
}

/* ------------------------------------------------------------------------------------------
 * 整条链跑一次。三个输入量的**出处**都在这里，站 13 只管打。
 *
 * ⚠ **本函数与 sw/ps_diag.h 的 dia_frame() 目前逐行同形，两份。** 改了这里的分支顺序、
 *   归一化口径或阶次参数，必须同步改那边 —— 否则自检会**照常绿**，因为它验的是自己这份
 *   旧逻辑（这是这条链最容易静默失效的地方）。
 * ------------------------------------------------------------------------------------------ */
static void run_chain(const double *x, int n)
{
    float  xf[CLF_N_FEAT];
    double v[PS_FEAT_NFEAT];
    double med;
    struct diag_result r;
    uint32_t t0, t1, ticks, st, gi;
    int i, sum = 0;

    t0 = gtimer_now();
    fea_frame18(x, n, 25.0, v);                 /* 站 11：波形 → 18 维 */
    med = fea_norm18(v);
    for (i = 0; i < PS_FEAT_NFEAT; i++) {
        xf[i] = (float)v[i];
    }
    t1 = gtimer_now();

    r.cls = clf_predict(xf, r.votes);           /* 站 12 */
    for (i = 0; i < CLF_N_CLASS; i++) {
        sum += r.votes[i];
    }
    check(sum == CLF_N_TREE, "station 12 votes add up to the tree count");
    check(r.cls >= 1 && r.cls <= CLF_N_CLASS, "station 12 returned a class in range");

    r.conf_pct = (100 * r.votes[r.cls - 1]) / CLF_N_TREE;

    /* 方位：PL 固件写下的 SRP 峰值格号。**先看它自己报的状态位**再信这个格号 ——
     * 没跑过 PL 固件时 DTCM 里是下载镜像的残留，直接在 0..255 里也能凑出一个"合法"格号，
     * 那就成了悄悄打一个错的方位。bit0 = 查询成功（见 fw_steer.h）。 */
    st = dtcm(DTCM_STEER_STATUS);
    gi = dtcm(DTCM_STEER_GRID);
    r.grid_w = PL_SRP_GRID_W;
    if ((st & 1u) == 0u || !out_split_grid((int)gi, r.grid_w, &r.gx, &r.gy)) {
        r.grid_w = 0;                           /* 这一帧没有方位 */
        r.grid = 0;
        r.azim_pct = 0;
        xil_printf("PL  : no steering result yet (status=0x%x)\r\n", (unsigned)st);
    } else {
        r.grid = (int)gi;
        r.azim_pct = out_azim_pct(r.gy, r.grid_w);   /* 扫描面的行 = 仰角方向 */
    }

    /* 严重程度**没有真实出处**：这里拿"赢家票占比"当代理，只是让字段有个数。
     * 它衡量的是森林内部的共识，不是故障的物理程度。见 ps_output.h 文件头。 */
    r.sev_pct   = r.conf_pct;
    r.med_milli = (int)(med * 1000.0);

    out_print_human(&r);
    if (!out_print_diag(&r)) {
        check(0, "station 13 class name lookup");
    }

    /* 333 MHz ⇒ 1 拍 3 ns ⇒ ms = ticks * 3 / 1000000。
     * 拍数是 32 位、乘 3 会溢出，所以在 64 位里做（libgcc 的除法在 Xilinx 镜像里本来就有）。 */
    ticks = (uint32_t)(t1 - t0);
    xil_printf("TIME: station 11+12 %u ticks = %u ms\r\n",
               (unsigned)ticks, (unsigned)((uint64_t)ticks * 3u / 1000000u));
}

int main(void)
{
    static double x[FRAME_N];
    uint32_t ctl;

    g_fail = 0;

    ctl = Xil_In32(GTIMER_BASE + GTIMER_CTL_OFF);
    Xil_Out32(GTIMER_BASE + GTIMER_CTL_OFF, ctl | 1u);

    xil_printf("ps_diag_test: station 11 -> 12 -> 13\r\n");

    /* 站 11 的 setup 必须在任何一帧之前：H、Hann、twiddle 都在这儿定 */
    fea_setup(FRAME_FS, 1400.0, 4600.0);
    check_feature_setup();
    check_output_helpers();

    synth_frame(x, FRAME_N);
    run_chain(x, FRAME_N);

    xil_printf("FDIAG_RESULT_%s (%d failures)\r\n", g_fail == 0 ? "PASS" : "FAIL", g_fail);
    return g_fail;
}
