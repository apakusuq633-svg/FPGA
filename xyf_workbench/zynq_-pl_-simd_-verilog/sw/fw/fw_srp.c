/* SRP-PHAT 空间扫描 —— 固件标量基线。
 *
 *     P[g] = Σ_对  interp( R_ij, τ_ij(g) )
 *     τ_ij(g) = (d_i(g) − d_j(g)) / c · fs      d = 格点到麦克风的距离
 *
 * ══ 内存账：这一块**同时**被算力和内存卡住 ═══════════════════════════════
 *
 * DTCM 一共 16 KB。SRP 想要的两样东西都放不下：
 *
 *   延迟 LUT      1024 格 × 28 对 × 2 B  = 57 KB     ← 规格里那张表
 *   28 对的相关序列 28 × 1024 × 2 B      = 57 KB
 *
 * 所以固件的结构只能是**逐对流式**：算一对的 R → 把这一对的贡献累加进 P →
 * 丢掉 R → 下一对。常驻只剩 1 份 R（2 KB）+ P。
 *
 * 代价是**距离按对重算**：每个格点每对要 2 次开方；28 对就是 56 次。
 * 若能把 8 个麦克风的距离缓存下来只要 8 次，但那要 8 × 1024 × 2 B = 16 KB ——
 * **还是放不下**。这是硬件 LUT 存在的直接理由，也是这份基线的价值：
 * 它量出来的不只是算力，还有「内存逼出来的冗余计算」这笔账。
 *
 * 连 P 本身都要缩水：32×32 的 P 是 4 KB（int32 × 1024），连续空间腾不出来，
 * 基线取 **16×16 = 256 点**（1 KB）。见 fw_srp.h 的说明。
 *
 * ══ 定点约定（与 scripts/golden/fw_srp_model.py 一字不差）══════════════════
 *   位置单位 2^-14 m：麦克风半径 0.05 m → 819，扫描半宽 0.2 m → 3277，
 *   平面 z 0.3 m → 4915。d² ≤ 5.8e7，int32 安全。
 *   τ_q16 = (d_i − d_j) · 456，idx = τ_q16 >> 16（算术），frac4 = (τ_q16 >> 12) & 0xF
 *   interp = v0 + ((v1 − v0) · frac4 >> 4)   —— 与 RTL 同一条，>> 向下取整
 *
 * ⚠ `>>` 对负数是算术右移（GCC/RISC-V 的 srai），Python 的 >> 也是 floor ——
 *   两边能逐位对上的前提。idx 取模用 `& (N−1)` 而不是 `%`：C 的 `%` 对负数
 *   给负余数，而 Python 的 `%` 给非负，两边会在这里分叉。
 */
#include <stdint.h>

#include "fw_srp.h"
#include "fw_tables.h"
#ifdef FW_MIC_GEOMETRY_HEADER
#include FW_MIC_GEOMETRY_HEADER
#endif

#define POS_SH      14
#define MIC_R_U     819        /* 0.05 m  × 2^14 */
#define GRID_HALF_U 3277       /* 0.2 m   × 2^14 */
#define PLANE_Z_U   4915       /* 0.3 m   × 2^14 */
#define TAU_K       456        /* 见 fw_srp_model.py：τ[样点] = d_u · 456 / 2^16 */
#define R_LEN       1024       /* 相关序列长度（= FFT_N） */

static int16_t g_xs[SRP_GRID_W], g_ys[SRP_GRID_W];

void srp_init(void)
{
    for (int j = 0; j < SRP_GRID_W; j++) {
        const int32_t v = -GRID_HALF_U + (j * 2 * GRID_HALF_U) / (SRP_GRID_W - 1);
        g_xs[j] = (int16_t)v;
        g_ys[j] = (int16_t)v;
    }
}

/* 整数平方根（恢复法）。d² ≤ 5.8e7 只需 16 轮，每轮几条指令。
 * 不用浮点、不用除法 —— RV32IM 上这就是最省的写法。 */
static inline uint32_t isqrt_u32(uint32_t v)
{
    uint32_t res = 0;
    uint32_t bit = 1u << 30;
    while (bit > v) bit >>= 2;
    while (bit != 0) {
        if (v >= res + bit) {
            v -= res + bit;
            res = (res >> 1) + bit;
        } else {
            res >>= 1;
        }
        bit >>= 2;
    }
    return res;
}

/* 麦克风 i 的位置（2^-14 m）。
 *
 * **从旋转因子表取**，不另建表：W_1024^{128i} = e^{-jπi/4}，
 * 所以 cos(πi/4) = Re(W^{128i})、sin(πi/4) = −Im(W^{128i})。
 * 这样麦克风坐标和 FFT 用的是同一份常量，不会各自漂移（对照 019）。 */
static inline int32_t mic_x_u(int i)
{
#ifdef FW_MIC_GEOMETRY_HEADER
    return fw_mic_xy_q14[i][0];
#else
    return ((int32_t)g_tw_re[128 * i] * MIC_R_U) >> POS_SH;
#endif
}
static inline int32_t mic_y_u(int i)
{
#ifdef FW_MIC_GEOMETRY_HEADER
    return fw_mic_xy_q14[i][1];
#else
    return (-(int32_t)g_tw_im[128 * i] * MIC_R_U) >> POS_SH;
#endif
}

/* 格点 (x,y) 到麦克风 mi 的距离（2^-14 m） */
static inline int32_t dist_u(int32_t x, int32_t y, int mx, int my)
{
    const int32_t dx = x - mx, dy = y - my;
    return (int32_t)isqrt_u32((uint32_t)(dx * dx + dy * dy +
                                         PLANE_Z_U * PLANE_Z_U));
}

/* 格点 (x,y) 上 mi/mj 这一对的延迟（Q16 样点） */
static inline int32_t tau_q16(int32_t x, int32_t y, int mi, int mj)
{
    const int32_t di = dist_u(x, y, mic_x_u(mi), mic_y_u(mi));
    const int32_t dj = dist_u(x, y, mic_x_u(mj), mic_y_u(mj));
    return (di - dj) * TAU_K;
}

void srp_acc_pair(const int16_t *r_seq, int mi, int mj, int32_t *p_acc)
{
    const int mxi = mic_x_u(mi), myi = mic_y_u(mi);
    const int mxj = mic_x_u(mj), myj = mic_y_u(mj);
    const int32_t zz = PLANE_Z_U * PLANE_Z_U;

    for (int gy = 0; gy < SRP_GRID_W; gy++) {
        const int32_t y = g_ys[gy];
        const int32_t dyi = y - myi, dyj = y - myj;
        for (int gx = 0; gx < SRP_GRID_W; gx++) {
            const int32_t x = g_xs[gx];
            const int32_t dxi = x - mxi, dxj = x - mxj;
            const int32_t di = (int32_t)isqrt_u32(
                (uint32_t)(dxi * dxi + dyi * dyi + zz));
            const int32_t dj = (int32_t)isqrt_u32(
                (uint32_t)(dxj * dxj + dyj * dyj + zz));

            const int32_t tq   = (di - dj) * TAU_K;
            const int32_t idx  = tq >> 16;              /* 算术右移，可为负 */
            const int32_t frac = (tq >> 12) & 0xF;
            const int32_t i0 = idx & (R_LEN - 1);       /* 负 idx 也落在 [0,1023] */
            const int32_t i1 = (i0 + 1) & (R_LEN - 1);
            const int32_t v0 = r_seq[i0];
            const int32_t v1 = r_seq[i1];
            p_acc[gy * SRP_GRID_W + gx] += v0 + (((v1 - v0) * frac) >> 4);
        }
    }
}

void srp_dump_tau(int mi, int mj, int16_t *out)
{
    for (int gy = 0; gy < SRP_GRID_W; gy++) {
        for (int gx = 0; gx < SRP_GRID_W; gx++) {
            const int32_t tq = tau_q16(g_xs[gx], g_ys[gy], mi, mj);
            /* 打包成 (idx<<4)|frac4。idx 在 ±12 样点内，int16 装得下。 */
            out[gy * SRP_GRID_W + gx] =
                (int16_t)((((tq >> 16) << 4) | ((tq >> 12) & 0xF)) & 0xFFFF);
        }
    }
}
