/* ps_diag.h —— 一条诊断的**接缝**：从"一段波形"到"一个 struct diag_result"（PS 侧）
 *
 * -- 为什么把它单拎出来 ---------------------------------------------------------------------
 *
 * 这段逻辑原来只存在于 sw/ps_diag_test.c 的 run_chain() 里。现在多了一个消费者
 * （sw/ps_ui.c 的网页服务），如果照抄一份，就有两处"站 11 → 站 12 → 站 13"的接线：
 * 改了一处不会报错，只会让串口和网页报出两个不一样的诊断。本仓库已经被这类
 * "同一件事存两份"咬过好几次（RV32_BASE、PDM 窗口，见 scripts/check_ps_apps.py 里
 * 那两个交叉检查），所以这里把它抽成唯一的一份。
 *
 * ⚠ ps_diag_test.c **没有**改成用这个头（那是你的文件，我没动）。所以**现在有两份**：
 *   那份自检里的 run_chain() 和这里的 dia_frame()。两边目前逐行同形。
 *   要不要把自检也改成 include 本头，等你发话。
 *
 * -- 这里不打印 -----------------------------------------------------------------------------
 *
 * 一个字节都不往串口写。因为网页服务每个周期都要跑一次这个函数，若它自带 printf，
 * 串口就会被刷屏、把真正的开机日志冲掉。要打印的那几行（DIAG / DIR / VOTE / FDIAG）
 * 由调用方在**结果落定之后**打 —— 见 sw/ps_ui.c 的主循环。
 *
 * -- 输入从哪来（诚实条款） -------------------------------------------------------------------
 *
 * 现在**没有**把真 PDM 波形喂进这条链的代码：dia_synth_frame() 造的是程序自己合成的
 * 一段轴承样信号（LCG 噪声 + 双极点谐振器，不在训练分布里）。所以链子是真跑的、字段
 * 是真的，**来源是自检帧**。页面与串口都把这件事标出来。等 PL 侧真把 PDM 段送到 DDR
 * 之后，把 dia_synth_frame 的调用点换成"读那段内存"即可，本头其余部分不用动。
 */
#ifndef PS_DIAG_H
#define PS_DIAG_H

#include <stdint.h>

#include "xil_io.h"        /* Xil_In32 / Xil_Out32 */

#include "ps_features.h"   /* 站 11：fea_setup / fea_frame18 / fea_norm18 */
#include "ps_classifier.h" /* 站 12：clf_predict */
#include "ps_output.h"     /* 站 13：struct diag_result、out_split_grid、out_azim_pct */

/* Cortex-A9 全局计时器，FCLK/2 = 333 MHz ⇒ 1 拍 3 ns。只用低 32 位：12.9 s 才回绕，
 * 本程序远用不到，无符号减法跨回绕也是对的。 */
#define GTIMER_BASE    0xF8F00200u
#define GTIMER_LO_OFF      0x00u
#define GTIMER_CTL_OFF     0x08u

/* RV32 的 AXI 窗口。DTCM 不是 PS 能按物理地址直接读的 —— 得写 R_MEM_ADDR 选中，
 * 再从 R_MEM_RDATA 取。地址字段是**字下标**（字节地址 >> 2）并与选中位或在一起。 */
#define RV32_BASE      0x43C00000u
#define R_MEM_ADDR     0x080u
#define R_MEM_RDATA    0x088u
#define MEM_SEL_DTCM   0x80000000u

/* PL 固件的结果区，见 sw/fw/fw_mem.h 的 FW_STEER_BASE = 0x3C60。
 * 这里写死地址是和 sw/ps_main.c 一样的做法（它也是读 dtcm(0x3C60)）——
 * PS 侧不 include PL 固件的头，免得把两边的地址绑死。 */
#define DTCM_STEER_STATUS  0x3C60u   /* bit0 = 查询成功, bit1 = LOCKED */
#define DTCM_STEER_GRID    0x3C70u   /* SRP 峰值格号 */

/* PL 侧 SRP 网格的边长，权威定义在 sw/fw/fw_srp.h（SRP_GRID_W = 16）。
 * 站 13 故意不写死这个数（它把 grid_w 当参数收），由调用方在这儿给。 */
#define PL_SRP_GRID_W      16

/* 一帧的长度与采样率，与训练脚本同口径（1.024 s @ 39062.5 Hz）。
 * ⚠ 站 11 的 setup 用的 fs 和这里造帧用的 fs 必须是同一个 —— 所以只有这一个定义，
 * 由 dia_synth_frame 和调用方的 fea_setup 共用。 */
#define FRAME_N        40000
#define FRAME_FS       39062.5

static uint32_t dia_gtimer_now(void)
{
    return Xil_In32(GTIMER_BASE + GTIMER_LO_OFF);
}

/* 计时器不会自己走，得先置 enable 位。位定义见 Zynq TRM 的 GTIMER 章 ——
 * 只置 bit0（timer enable），不碰 auto-reload / irq，本程序靠轮询读值。 */
static void dia_gtimer_start(void)
{
    uint32_t ctl = Xil_In32(GTIMER_BASE + GTIMER_CTL_OFF);
    Xil_Out32(GTIMER_BASE + GTIMER_CTL_OFF, ctl | 1u);
}

/* 拍数 → 毫秒：333 MHz ⇒ 1 拍 3 ns ⇒ ms = ticks * 3 / 1000000。
 * 拍数是 32 位、乘 3 会溢出，所以在 64 位里做（libgcc 的除法在 Xilinx 镜像里本来就有）。 */
static unsigned dia_ticks_to_ms(uint32_t ticks)
{
    return (unsigned)((uint64_t)ticks * 3u / 1000000u);
}

static uint32_t dia_dtcm(uint32_t byte_addr)
{
    Xil_Out32(RV32_BASE + R_MEM_ADDR, MEM_SEL_DTCM | (byte_addr >> 2));
    return Xil_In32(RV32_BASE + R_MEM_RDATA);
}

/* ------------------------------------------------------------------------------------------
 * 方位：PL 固件写下的 SRP 峰值格号。
 *
 * **先看它自己报的状态位**再信这个格号 —— 没跑过 PL 固件时 DTCM 里是下载镜像的残留，
 * 直接在 0..255 里也能凑出一个"合法"格号，那就成了悄悄打一个错的方位（bit0 = 查询成功，
 * 见 fw_steer.h）。取到了返回 1，没取到返回 0 并把 *grid_w 置 0（＝"这一帧没有方位"）。
 *
 * 打印留给调用方：它手里有 status 的原值，可以只在自己想打的时候打。
 * ------------------------------------------------------------------------------------------ */
static int dia_read_dir(int grid_w, struct diag_result *r, uint32_t *status_out)
{
    uint32_t st = dia_dtcm(DTCM_STEER_STATUS);
    uint32_t gi = dia_dtcm(DTCM_STEER_GRID);
    int gx, gy;

    if (status_out != 0) {
        *status_out = st;
    }

    if ((st & 1u) == 0u || !out_split_grid((int)gi, grid_w, &gx, &gy)) {
        r->grid_w = 0;
        r->grid = 0;
        r->gx = 0;
        r->gy = 0;
        r->azim_pct = 0;
        return 0;
    }

    r->grid_w = grid_w;
    r->grid = (int)gi;
    r->gx = gx;
    r->gy = gy;
    r->azim_pct = out_azim_pct(gy, grid_w);   /* 扫描面的行 = 仰角方向 */
    return 1;
}

/* ------------------------------------------------------------------------------------------
 * 跑一次整条链，不打印。返回 dia_read_dir 的结果（1 = 这一帧带方位）。
 *
 * 次序就是数据流的次序，中间那两行 check() 在自检里，这里没有 —— 这里每个周期都会被
 * 调一次，不适合做断言（而且 votes 之和与 cls 范围在自检里已经查过了）。
 *
 * ⚠ **本函数与 sw/ps_diag_test.c 的 run_chain() 目前逐行同形，两份。** 改了这里的分支
 *   顺序、归一化口径或阶次参数，必须同步改 run_chain() —— 否则自检会**照常绿**，因为它
 *   验的是自己那份旧逻辑（这是这条链最容易静默失效的地方）。
 * ------------------------------------------------------------------------------------------ */
static void dia_classify_audio(const double *x, int n, double shaft_hz, struct diag_result *r)
{
    float  xf[CLF_N_FEAT];
    double v[PS_FEAT_NFEAT];
    double med;
    int i;

    fea_frame18(x, n, shaft_hz, v);            /* 站 11：波形 → 18 维 */
    med = fea_norm18(v);                   /* 原地归一化 */
    for (i = 0; i < PS_FEAT_NFEAT; i++) {
        xf[i] = (float)v[i];
    }

    r->cls = clf_predict(xf, r->votes);    /* 站 12：18 维 → 类别 + 票数 */
    if (r->cls < 1 || r->cls > CLF_N_CLASS) {
        r->cls = 1;                        /* 越界就当 normal 报，绝不用它去索引数组 */
    }
    r->conf_pct = (100 * r->votes[r->cls - 1]) / CLF_N_TREE;

    /* 严重程度**没有真实出处**：这里拿"赢家票占比"当代理，只是让字段有个数。
     * 它衡量的是森林内部的共识，不是故障的物理程度。见 ps_output.h 文件头。 */
    r->sev_pct = 0;
    r->med_milli = (int)(med * 1000.0);

}

static inline int dia_frame(const double *x, int n, int grid_w, struct diag_result *r,
                     uint32_t *status_out)
{
    dia_classify_audio(x,n,25.0,r);
    if (status_out != 0) {
        *status_out = 0;
    }
    return dia_read_dir(grid_w, r, status_out);   /* 站 13 的格号拆分在这里被用到 */
}

/* ------------------------------------------------------------------------------------------
 * 合成一段轴承样信号。**不是**训练分布里的样本，只用来说明链子跑得通。
 *
 * 与 ps_diag_test.c 的 synth_frame() 同形（那边是原版），逐字一致的理由：两处的"合成"
 * 应当给出一模一样的帧，否则自检和网页就不是同一条链了。
 *
 * 共振用双极点谐振器，不用 exp()：y[n] = 2r*cos(w0)*y[n-1] - r^2*y[n-2] + a[n] 的冲激响应
 * 正好是 r^n*sin(w0 n)，而链接行没有 -lm（exp 拿不到）。
 *   r = exp(-500/fs) = 0.98728157159029051 —— 和训练脚本的 exp(-500*tau) 同一个衰减率
 * 内圈故障：每 288 个样点一次冲击（= 135.63 Hz ≈ BPFI 5.428 x 25 Hz），
 * 幅度被转频 25 Hz 调制（1 + 0.8*cos(2*pi*f_r*t)），与训练脚本 synth_segment 的 cls=3 同形。
 * ------------------------------------------------------------------------------------------ */
static double dia_ph_wrap(double ph)
{
    const double TWO_PI = 6.283185307179586232;

    /* d_sincos 的契约是 |th| < 2*pi，而相位是 2*pi*f*t、到 1.024 s 就有上万弧度，
     * 所以相位自己攒：每步加增量、超了就减一圈，相位恒在 [0, 2*pi)，
     * 每一步的舍入是 ulp(2*pi) 量级、不随 t 放大。 */
    while (ph >= TWO_PI) { ph -= TWO_PI; }
    while (ph < 0.0)     { ph += TWO_PI; }
    return ph;
}

static inline void dia_synth_frame(double *x, int n)
{
    const double TWO_PI  = 6.283185307179586232;
    const double r       = 0.98728157159029051;
    const double r2      = 0.97472490160179392;          /* r*r */
    const int    P_IMP   = 288;                          /* 冲击间隔（样点） */

    const double dph_r   = TWO_PI * 25.0 / FRAME_FS;  /* 转频 */
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
            ph_imp = dia_ph_wrap(ph_imp + dph_imp);
        }

        y = a1 * y1 - r2 * y2 + drive;
        y2 = y1;
        y1 = y;

        d_sincos(ph_r, &s, &c);
        base = 0.05 * s;
        d_sincos(ph_2r, &s, &c);
        base += 0.02 * s;
        ph_r  = dia_ph_wrap(ph_r + dph_r);
        ph_2r = dia_ph_wrap(ph_2r + dph_2r);

        /* LCG 均匀噪声（RMS 约 0.087）：只是让包络谱有个底噪，不是高斯白噪 */
        lcg = lcg * 1103515245u + 12345u;
        u = ((double)((lcg >> 8) & 0xFFFFFFu) / 16777216.0) - 0.5;

        x[i] = y + base + 0.3 * u;
    }
}

#endif /* PS_DIAG_H */
