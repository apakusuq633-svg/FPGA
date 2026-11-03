/* GCC-PHAT 固件内核 —— 一对麦克风的 TDOA，标量基线。
 *
 *     x_i, x_j  加 Hann 窗
 *     Xi = rfft(x_i)   Xj = rfft(x_j)      ← fw_fft.c，实数 FFT
 *     G  = Xi · conj(Xj)                    互谱
 *     Ψ  = (G / |G|) · M(f)                 PHAT 白化 + **限带**
 *     R  = irfft(Ψ)                         ← fw_fft.c，打包逆变换
 *     τ̂ = argmax|R|
 *
 * ⚠ **限带不是可选项**。全带白化会把源信号没有能量的频段（那里只有混响残余
 *   和数值噪声）抬到与信号同权，在相关域造出跨对一致的伪结构，28 对求和时
 *   反而叠加。实测：全带 PHAT 在 40 dB 混响下把定位误差从 0.85 cm 劣化到
 *   5.32 cm。详见 docs/issues/027。
 *
 * ⚠ 与 scripts/golden/fw_gcc_model.py **逐位等价**。改这里必须同步改那边。
 *
 * 为什么分「灌 A / 灌 B / 收口」三步
 *   不是接口洁癖，是**内存**：DTCM 只有 16 KB，同时留住两路原始帧（4 KB）
 *   就挤掉频谱缓冲。分三步之后只需要一块 2 KB 的帧缓冲 —— 这也正是真实
 *   数据流的形状：样点进来就变换掉，不留原始帧。
 *
 * 定标
 *   Xi/Xj  Q15（标度 = 真值/1024，见 fw_fft.c）
 *   G      Q15（两个 Q15 相乘 >>15）
 *   Ψ      **Q14**（1.0 = 16384）。Q15 装不下 1.0 —— 同一个坑见 docs/issues/029
 *   R      int16，标度 = 输入/1024
 *   τ̂      样点，正值表示 A 比 B **晚**到
 */
#include <stdint.h>

#include "fw_fft.h"
#include "fw_gcc.h"
#include "fw_cycle_profile.h"
#if FW_CYCLE_PROFILE
uint32_t fw_gcc_profile[5];
#endif

#define GCC_N       FFT_N              /* 1024 */
#define GCC_NBIN    FFT_NBIN           /* 513  */

/* 工作频带。f = k·fs/N，fs = 39062.5 Hz、N = 1024 ⇒ 每 bin 38.15 Hz。
   200 Hz → k ≥ 6，8000 Hz → k ≤ 209。RTL 里就是两个下标比较，不用乘法器。 */
#define BAND_LO_BIN 6
#define BAND_HI_BIN 209

/* 两路频谱。re/im 交替存，各 513 条。 */
static int16_t g_xi[2 * GCC_NBIN] __attribute__((aligned(4)));
static int16_t g_xj[2 * GCC_NBIN];
#if defined(FW_GCC_AUDIT) && FW_GCC_AUDIT
void gcc_audit_phi(int16_t *out) { for(unsigned k=0;k<1026;k++)out[k]=g_xi[k]; }
#endif
static void finish_common(int phat, const int16_t *xi, const int16_t *xj,
                          volatile int16_t *r_out, int32_t *peak_lag, int ring_only);
#ifndef FW_SIMD_PHAT
#define FW_SIMD_PHAT 0
#endif
#ifndef FW_SIMD_PHAT_MODEL
#define FW_SIMD_PHAT_MODEL 0
#endif

#if FW_HAVE_HW && FW_SIMD_PHAT
static void cached_ring_simd(const int16_t *a,const int16_t *b,volatile int16_t *out)
{
    const uint32_t *x=(const uint32_t *)a,*y=(const uint32_t *)b;
#if FW_CYCLE_PROFILE
    uint32_t t0=read_cycles();
#endif
    /* Both 208-word transfers wrap the shared pointer; last four bins are masked. */
    for(unsigned k=6;k<214;k++) {
        uint32_t w=x[k];
        __asm__ volatile(".insn r 0x0b, 4, 0x40, x0, %0, x0" ::"r"(w));
    }
    for(unsigned k=6;k<214;k++) {
        uint32_t w=y[k];
        __asm__ volatile(".insn r 0x0b, 5, 0x40, x0, %0, x0" ::"r"(w));
    }
#if FW_CYCLE_PROFILE
    uint32_t t1=read_cycles();
#endif
    __asm__ volatile(".insn r 0x0b, 6, 0, x0, x0, x0");
#if FW_CYCLE_PROFILE
    uint32_t t2=read_cycles();
#endif
    __asm__ volatile(".insn r 0x0b, 5, 0, x0, x0, x0");
#if FW_CYCLE_PROFILE
    uint32_t t3=read_cycles();
#endif
    volatile uint32_t *psi=(volatile uint32_t *)g_xi;
    for(unsigned k=0;k<6;k++)psi[k]=0;
    for(unsigned k=6;k<214;k++) {
        uint32_t w;__asm__ volatile(".insn r 0x0b, 6, 0x40, %0, x0, x0":"=r"(w));
        psi[k]=w;
    }
    for(unsigned k=214;k<513;k++)psi[k]=0;
#if FW_CYCLE_PROFILE
    uint32_t t4=read_cycles();
#endif
    ifft512_real_ring_hw(g_xi,out);
#if FW_CYCLE_PROFILE
    uint32_t t5=read_cycles();
    fw_gcc_profile[0]=t1-t0;fw_gcc_profile[1]=t2-t1;fw_gcc_profile[2]=t3-t2;
    fw_gcc_profile[3]=t4-t3;fw_gcc_profile[4]=t5-t4;
#endif
}
#endif
#if FW_SIMD_PHAT_MODEL
static int32_t phat_lut(int32_t component,int32_t magnitude)
{
    static const uint16_t lut[16]={15888,14895,14014,13233,12537,11915,11357,10855,
                                   10402,9993,9621,9281,8969,8682,8417,8192};
    if(!magnitude)return 0;
    unsigned e=0;while(((uint32_t)magnitude>>(e+1))!=0)e++;
    uint32_t mant=e>=14?(uint32_t)magnitude>>(e-14):(uint32_t)magnitude<<(14-e);
    return (component*(int32_t)lut[(mant>>10)&15])>>e;
}
#endif

/* Hann 窗直接从旋转因子表算：w[n] = 0.5 − 0.5·cos(2πn/N)，
   而 cos(2πn/N) 就是 Re(W_1024^n) —— **不额外占一张表**。
   n > 512 用 cos 的对称性折回去（cos(2πn/N) = cos(2π(N−n)/N)），代价一个比较。
   Q14 不是随便挑的：w[512] = 1.0 在 Q15 里是 32768，装不下（见 029）。 */
static inline int32_t hann_q14(uint32_t n)
{
    const uint32_t k = (n <= (uint32_t)FFT_N / 2u) ? n : ((uint32_t)FFT_N - n);
    return 8192 - (g_tw_re[k] >> 1);
}

/* 加窗 + 实数 FFT，频谱落进 dst。窗是 Q14、样本是 Q15，乘完 >>14 回 Q15。
 *
 * ⚠ 加窗是**就地**做的（x 被改写）。不是为了省一次循环，是 DTCM 只有 16 KB：
 *   另外留一块 2 KB 的加窗缓冲就把频谱缓冲挤出去了。调用方传进来的那块内存
 *   从此就是「加过窗的帧」，原始帧不再保留 —— 与真实数据流一致（样点进来就
 *   变换掉），但**调用方不能指望 x 还是原样**。 */
static void spectrum(int16_t *x, int16_t *dst)
{
#if FW_DETAIL_PROFILE
    uint32_t t0=read_cycles();
#endif
    for (uint32_t n = 0; n < (uint32_t)FFT_N; n++) {
        x[n] = (int16_t)(((int32_t)x[n] * hann_q14(n)) >> 14);
    }
#if FW_DETAIL_PROFILE
    fw_prepare_detail[4]+=read_cycles()-t0;
#endif
    /* 生产路径的正变换：FW_ACCEL=1 走核内 VFFT，=0 走标量。
       两条**逐位等价**（docs/vfft_design.md），所以 golden 只写一份、对谁都成立，
       整机对照里改的只有"谁在算"。见 fw_fft.h 的加速开关。 */
    fft1024_run(x, dst);
}

/* |a+jb| 的 α-max-β-min 近似：max + min/2 − min/8 + min/32 + min/128。
   大幅值欧氏模误差最高约 +8.24%；0.4140625 的系数误差不是模误差。 */
static inline int32_t mag_approx(int32_t re, int32_t im)
{
    int32_t a = (re < 0) ? -re : re;
    int32_t b = (im < 0) ? -im : im;
    int32_t mx = (a > b) ? a : b;
    int32_t mn = (a > b) ? b : a;
    return mx + (mn >> 1) - (mn >> 3) + (mn >> 5) + (mn >> 7);
}

void gcc_load_a(int16_t *x) { spectrum(x, g_xi); }
void gcc_load_b(int16_t *x) { spectrum(x, g_xj); }

/* Cache each microphone FFT once; the cached spectra remain read-only. */
void gcc_spectrum(int16_t *x, int16_t *out) { spectrum(x, out); }
void gcc_spectrum_windowed(int16_t *x,int16_t *out) { fft1024_run(x,out); }

void gcc_cached_pair(const int16_t *a, const int16_t *b,
                     volatile int16_t *out)
{
    /* SRP consumes the correlation map, not a single-pair peak lag. */
    finish_common(1, a, b, out, 0, 0);
}

void gcc_cached_ring(const int16_t *a, const int16_t *b, volatile int16_t *out)
{
#if FW_HAVE_HW && FW_SIMD_PHAT
    cached_ring_simd(a,b,out);
#else
    finish_common(1, a, b, out, 0, 1);
#endif
}

/* 互谱 +（可选）PHAT 白化 → Ψ 写回 g_xi → 逆变换 → 峰值。
 *
 * phat = 1  GCC-PHAT：Ψ = G/|G|，**定位**用
 * phat = 0  纯互相关：Ψ = G>>1，**波束形成（DAS）**用
 *
 * 为什么 DAS 也走这里：频域 DAS 的功率展开就是
 *     |Σ_i X_i e^{-jωτ_i}|² = Σ_ij R_ij(τ_i − τ_j)
 * —— 与 SRP 是**同一个内核**，只差 R 做不做白化。所以后面那个
 * 「按延迟查表累加」的部分两边复用（见 fw_srp.c）。 */
static void finish_common(int phat, const int16_t *xi, const int16_t *xj,
                          volatile int16_t *r_out, int32_t *peak_lag, int ring_only)
{
    int g_raw_shift = 0;

    /* 不做白化时先定块标度：扫一遍带内 |re|+|im| 的最大值，
       左移到接近 Q14 满幅。见下面 phat==0 分支的说明。 */
    if (!phat) {
        int32_t mx = 1;
        for (uint32_t k = BAND_LO_BIN; k <= BAND_HI_BIN; k++) {
            const int32_t xr = xi[2 * k],  xim = xi[2 * k + 1];
            const int32_t yr = xj[2 * k],  yim = xj[2 * k + 1];
            const int32_t gr = (xr * yr + xim * yim + 16384) >> 15;
            const int32_t gi = (xim * yr - xr * yim + 16384) >> 15;
            const int32_t a = ((gr < 0) ? -gr : gr) + ((gi < 0) ? -gi : gi);
            if (a > mx) mx = a;
        }
        /* 用 |re|+|im| 当上界：移完之后每一路都 ≤ 16384，不会顶到 int16 上界 */
        while (mx < 8192 && g_raw_shift < 14) { mx <<= 1; g_raw_shift++; }
    }

    /* G = Xi · conj(Xj)：Q15×Q15 = Q30，>>15 回 Q15。
       除法用真除（RV32IM 的 div，约 30 拍）—— 标量基线先要**准**；RTL 那边
       才是「4-bit 倒数 LUT 就够」（README §0.3.4 第 3 条）。两者的差是加速比
       的一部分，不要在这里提前用近似把它抹掉。 */
    for (uint32_t k = 0; k < GCC_NBIN; k++) {
        int32_t pr = 0, pi = 0;
        if (k >= BAND_LO_BIN && k <= BAND_HI_BIN) {
            const int32_t xr = xi[2 * k],  xim = xi[2 * k + 1];
            const int32_t yr = xj[2 * k],  yim = xj[2 * k + 1];
            const int32_t gr = (xr * yr + xim * yim + 16384) >> 15;
            const int32_t gi = (xim * yr - xr * yim + 16384) >> 15;
            if (phat) {
#if FW_SIMD_PHAT_MODEL
                if(ring_only) {
                    int32_t real=(int16_t)gr,imag=(int16_t)gi;
                    int32_t magnitude=mag_approx(real,imag);
                    pr=phat_lut(real,magnitude);pi=phat_lut(imag,magnitude);
                } else
#endif
                {
                int32_t mag = mag_approx(gr, gi);
                if (mag < 1) mag = 1;             /* 防 0 除；带内几乎不会发生 */
                /* 1/|G| 取 Q30，再 (G · inv) >> 16 → 单位幅度落在 Q14（16384） */
                const int32_t inv = (int32_t)(0x40000000 / mag);
                pr = (gr * inv) >> 16;
                pi = (gi * inv) >> 16;
                }
            } else {
                /* 不做白化：**必须块标度归一化**，不能直接 >>1 了事。
                   X 已经带了 FFT 的 ÷1024，G = X_i·conj(X_j)>>15 再掉 15 位，
                   实测大部分 bin 落在 1 LSB 以下 —— 相关序列出来只有 ±2，
                   整段是量化噪声。左移到接近 Q14 满幅即可。
                   全局标度不影响 argmax，所以在 DAS 里安全（PHAT 那条本来就
                   被归一化到 1.0，不需要这一步）。 */
                pr = gr << g_raw_shift;
                pi = gi << g_raw_shift;
            }
        }
        g_xi[2 * k]     = (int16_t)pr;
        g_xi[2 * k + 1] = (int16_t)pi;
    }

    /* ── 逆变换 → 相关序列 ───────────────────────────────────────── */
#if FW_HAVE_HW && defined(FW_VFFT_SEEK) && FW_VFFT_SEEK
    if(ring_only) ifft512_real_ring_hw(g_xi,r_out);
    else ifft512_real_run(g_xi,r_out);
#else
    (void)ring_only;
    ifft512_real_run(g_xi,r_out);
#endif
    if (!peak_lag) return;

    /* ── 峰值 → TDOA ────────────────────────────────────────────── */
    int32_t best = -1;
    uint32_t bk = 0;
    for (uint32_t n = 0; n < (uint32_t)GCC_N; n++) {
        const int32_t v = r_out[n];
        const int32_t a = (v < 0) ? -v : v;
        if (a > best) { best = a; bk = n; }
    }
    /* 后半段是负滞后：n ≥ N/2 对应 n − N */
    *peak_lag = (bk >= (uint32_t)(GCC_N / 2)) ? ((int32_t)bk - GCC_N)
                                              : (int32_t)bk;
}

void gcc_finish(volatile int16_t *r_out, int32_t *peak_lag)
{
    finish_common(1, g_xi, g_xj, r_out, peak_lag, 0);
}

int32_t gcc_finish_raw(volatile int16_t *r_out)
{
    int32_t lag;
    finish_common(0, g_xi, g_xj, r_out, &lag, 0);
    return lag;
}
