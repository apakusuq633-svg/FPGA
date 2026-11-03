/* ps_features.h —— 站 11：把一段波形变成分类器要的 18 维特征（PS 侧，Cortex-A9）
 *
 * 这 18 维不是设计出来的，是**训练脚本定的**：
 *   F:\RISC-V\26fpga创新设计赛道\算法学习笔记\matlab\clf_train_export_demo.m
 * 那个脚本产出 sw/clf_model.h（100 棵树）。特征是它的输入契约，所以本文件的唯一
 * 职责是**逐字复刻那个脚本的数**，不是"实现一个合理的包络谱"。任何"顺手改得更合理"
 * 的改动都会让 18 维离开模型的训练分布，而模型不会报错，只会答错。
 *
 * 契约（全部来自上面那个脚本，行号为 2026-10-07 的版本）：
 *   fs = 39062.5 Hz          N_fft = 8192        df = 4.76837158203125 Hz（= fs/8192，二进制精确）
 *   N_seg = 40000（1.024 s）  Hann, 分母 N-1
 *   H = zeros(N,1); H(b1:b2) = 2;  b1 = max(1, round(1400/df)+1), b2 = min(N/2, round(4600/df)+1)
 *       即只留 1400–4600 Hz 这一个边带，**DC 与 Nyquist 都是 0**
 *   每个 8192 窗做：xa = ifft(fft(x.*w).*H); env = |xa|; acc += |fft((env-mean(env)).*w)|
 *   50% 重叠 → 40000 个点正好 8 个窗（步长 4096）
 *   P = acc/8，取前 N/2 = 4096 根
 *   18 维 = 4 个阶次 × 4 次谐波 + 1X + 2X：
 *       ORDERS = [0.398 2.357 3.572 5.428]   (6205 的 FTF/BSF/BPFO/BPFI)
 *       v[(o-1)*4 + k] = max(P) 在 k*ORDERS(o)*f_r 附近 ±HW 根内取（HW = 2）
 *       v[16+k]         = max(P) 在 k*f_r 附近 ±HW 根内取，k = 1,2
 *   归一化（**每帧一次，中位数取在这 18 维上**）：
 *       v_db = 20*log10((v + eps)/(median(v) + eps)),  eps = 2^-52
 *
 * ⚠ 这 18 维和 README §28 的 21 维（时域 7 + 频域 6 + 机械 8）**不是一回事**。
 *   模型只吃机械族 18 维。要换成 21 维必须重训，不是改这里。
 *
 * ⚠ 与站 9（sw/ps_env_pipeline.h）的关系：**是兄弟，不是父子**。
 *   站 9 是 N=1024 单窗、一个阶次参数、H 在 DC/Nyquist 上是 1；
 *   站 11 是 N=8192 八窗平均、固定四个阶次、H 是"带外全 0"。
 *   站 9 的 df=38 Hz 分辨不出 4 次谐波（BPFI 4X = 542.8 Hz 处相邻谐波间隔 135.7 Hz），
 *   所以站 11 不是站在站 9 上面加一层，是另一条**更长窗、多窗平均**的谱路。
 *   两者只是共用同一份 FFT/三角函数（PS_ENV_PIPELINE_MATH_ONLY）。
 *
 * ⚠ 本 TU 的 FFT_N 被本文件钉成 8192；同一 TU 里不能再有站 9 的 1024。
 *
 * 成本：每帧 8 窗 × 3 次 8192 点 FFT = 24 次，是站 9（2 次 1024 点）的约 120 倍 FFT 量。
 *   但**输入单位是 1.024 s 一段，不是 26 ms 一帧** —— 一段音频算一次，
 *   所以这是"离线/准实时"的量级，不是逐帧实时的量级。别按站 9 的节奏去用它。
 */
#ifndef PS_FEATURES_H
#define PS_FEATURES_H

#include <stddef.h>   /* 本头文件自带依赖，不靠包含它的程序去凑 */

/* ------------------------------------------------------------------------------------------
 * 借数学核：三角函数 / log10 / FFT。站 9 那一层（frame_setup、pipeline_run、工作缓冲、
 * gtimer_now）在这里既用不到也不需要定义，见 ps_env_pipeline.h 里的那段注释。
 * FFT_N 必须在包含它之前定好 —— tw_re/tw_im 是按 FFT_N 开的数组。
 * ------------------------------------------------------------------------------------------ */
#define PS_ENV_PIPELINE_MATH_ONLY 1

#define PS_FEAT_NFFT 8192

#ifndef FFT_N
#define FFT_N PS_FEAT_NFFT
#elif FFT_N != PS_FEAT_NFFT
#error "ps_features.h 要求 FFT_N == 8192；同一 TU 里已经有别的 FFT_N（站 9 是 1024）"
#endif

#include "ps_env_pipeline.h"

#define PS_FEAT_NORD     4                                   /* FTF/BSF/BPFO/BPFI       */
#define PS_FEAT_NHARM    4                                   /* 每个阶次取 1..4 次谐波   */
#define PS_FEAT_NFEAT    18                                  /* 4*4 + 1X + 2X           */
#define PS_FEAT_HW       2                                   /* ±2 根                    */
#define PS_FEAT_NBIN     (PS_FEAT_NFFT / 2)                  /* P 只留 4096 根           */
#define PS_FEAT_EPS      2.220446049250313080847e-16         /* MATLAB eps()            */

static const double fea_orders[PS_FEAT_NORD] = { 0.398, 2.357, 3.572, 5.428 };

/* -- 工作缓冲 ------------------------------------------------------------------------------
 * 5 × 8 KB = 320 KB，走 DDR（static ⇒ .bss），别往 DTCM 里放。
 * 站 11 自己一份，不复用站 9 的 g_fr/g_h/g_w：长度不同，H 的口径也不同。 */
static double fea_w[PS_FEAT_NFFT];       /* Hann，分母 N-1                         */
static double fea_H[PS_FEAT_NFFT];       /* MATLAB 的 H：带内 2，其余 0             */
static double fea_acc[PS_FEAT_NFFT];     /* 多窗累加                                */
static double fea_re[PS_FEAT_NFFT];      /* FFT 实部 / 逆变换后放 env                */
static double fea_im[PS_FEAT_NFFT];      /* FFT 虚部                                */

/* setup 时记住 fs 和带宽，之后算帧就不再要这两个数 —— 免得出现"建 H 用一套、算 df 用另一套" */
static double fea_fs_g, fea_df_g, fea_blo_g, fea_bhi_g;
static int    fea_b1_g, fea_b2_g;

/* ------------------------------------------------------------------------------------------
 * MATLAB 的 round()：**四舍五入、.5 远离 0**，不是 C 的 trunc。负半轴也照 MATLAB 走，
 * 虽然本文件里所有入参都是正的 —— 这里唯一的目的就是"和脚本同口径"。
 * ------------------------------------------------------------------------------------------ */
static double fea_round(double v)
{
    if (v >= 0.0) {
        return (double)(long long)(v + 0.5);
    }
    return -(double)(long long)(0.5 - v);
}

/* ------------------------------------------------------------------------------------------
 * 建 H、建 Hann、建 twiddle。与 fs 和带宽有关的一切只在这里发生，和站 9 的 frame_setup
 * 是同一个理由：都是常数，跑一次。
 * ------------------------------------------------------------------------------------------ */
__attribute__((noinline, optimize("O2")))
static void fea_setup(double fs, double blo, double bhi)
{
    const int n = PS_FEAT_NFFT;
    int i, k;

    fea_fs_g  = fs;
    fea_df_g  = fs / (double)n;
    fea_blo_g = blo;
    fea_bhi_g = bhi;

    /* MATLAB 1 起：b1 = max(1, round(B_lo/df)+1), b2 = min(N/2, round(B_hi/df)+1)
     * → 0 起就是下标 b1-1 .. b2-1。若 b1 > b2，MATLAB 的 H(b1:b2) 是空集，
     *   这里的 for 天然不执行 —— 同口径。 */
    fea_b1_g = (int)fea_round(blo / fea_df_g) + 1;
    if (fea_b1_g < 1) { fea_b1_g = 1; }
    fea_b2_g = (int)fea_round(bhi / fea_df_g) + 1;
    if (fea_b2_g > n / 2) { fea_b2_g = n / 2; }

    /* ⚠ 全 0 起手，只点亮带内 —— **不是**站 9 那套 "DC=1 / Nyquist=1"。
     *   这两个 bin 的差别会真的改变包络：env = |ifft(fft(x.*w).*H)|，abs 不是线性运算。 */
    for (i = 0; i < n; i++) {
        fea_H[i] = 0.0;
    }
    for (k = fea_b1_g; k <= fea_b2_g; k++) {
        fea_H[k - 1] = 2.0;
    }

    /* Hann：w = 0.5 - 0.5*cos(2*pi*i/(N-1))。分母是 N-1，不是 N —— 这才是 MATLAB hann(N)
     * 的对称形式，写错会让每个 w[i] 挪约一根 bin。和站 9 的 frame_setup 同一表达式。 */
    for (i = 0; i < n; i++) {
        double s, c;
        d_sincos((6.283185307179586232 / (double)(n - 1)) * (double)i, &s, &c);
        fea_w[i] = 0.5 - 0.5 * c;
    }

    twiddle_build(n);
}

/* ------------------------------------------------------------------------------------------
 * peak_near：在 f0 附近取 ±hw 根内的最大值。逐字对应脚本里的
 *   b = round(f0/df) + 1;  a = max(1, b-HW);  z = min(numel(P), b+HW);  p = max(P(a:z));
 * b >= 1 ⇒ a <= z 恒成立，不会出现空区间。
 * 每维只扫 5 根（2*hw+1），18 维一共 90 次比较，可以忽略。
 * ------------------------------------------------------------------------------------------ */
static double fea_peak_near(const double *P, int nP, double f0, double df, int hw)
{
    int b = (int)fea_round(f0 / df) + 1;      /* MATLAB 是 1 起 */
    int a = b - hw;
    int z = b + hw;
    int i;
    double p;

    if (a < 1) { a = 1; }
    if (z > nP) { z = nP; }
    p = P[a - 1];
    for (i = a; i <= z; i++) {
        if (P[i - 1] > p) { p = P[i - 1]; }
    }
    return p;
}

/* ------------------------------------------------------------------------------------------
 * 多窗平均包络谱。x 长 n（本项目的口径是 40000），P_out 收前 N/2 = 4096 根。
 *
 * 每个窗三步，和脚本 avg_envelope_spectrum 一一对应：
 *   1. X = fft(x(s:s+N-1) .* w)
 *   2. xa = ifft(X .* H)      —— H 在这里生效，只留 1400–4600 Hz 边带
 *   3. env = |xa|，去均值再乘 w，acc += |fft(去均值后的 env .* w)|
 *
 * 窗数由数据长度定：步长 N/2，起点 0、4096、…、31808，共 8 个（n=40000）。
 * n 略小于 N 时这里会退化成 0 个窗 —— 那说明调用方给错了段长，P 会全 0，
 * 特征全 0、归一化后全 0 dB。模型不会报错，只会答错，所以宁可调用方自己保证 n >= N。
 * ------------------------------------------------------------------------------------------ */
__attribute__((noinline, optimize("O2")))
static void fea_env_spectrum_mode(const double *x, int n, double *P_out, int *nw_out, int display)
{
    const int nfft = PS_FEAT_NFFT;
    const int half = nfft / 2;
    int i, s, nw = 0;
    double mean;

    for (i = 0; i < nfft; i++) {
        fea_acc[i] = 0.0;
    }

    for (s = 0; s + nfft <= n; s += half) {           /* MATLAB: s = 1:(N/2):(numel(x)-N+1) */
        for (i = 0; i < nfft; i++) {
            fea_re[i] = display ? x[s+i] : x[s+i] * fea_w[i];
            fea_im[i] = 0.0;
        }
        fft_core(fea_re, fea_im, nfft);

        for (i = 0; i < nfft; i++) {                  /* .* H */
            fea_re[i] *= fea_H[i];
            fea_im[i] *= fea_H[i];
        }
        fft_inv(fea_re, fea_im, nfft);

        /* env 先存进 fea_im：fea_re/fea_im 这就要拿去做第二次 FFT 了。
         * 先求和是为了 mean(env)，第二趟再减掉 —— 和 MATLAB env = abs(xa) 后 mean(env) 同值。 */
        mean = 0.0;
        for (i = 0; i < nfft; i++) {
            fea_im[i] = d_hypot(fea_re[i], fea_im[i]);   /* env = |xa| */
            mean += fea_im[i] * (display ? fea_w[i] : 1.0);
        }
        mean /= display ? 0.5*(nfft-1) : (double)nfft;

        for (i = 0; i < nfft; i++) {
            fea_re[i] = (fea_im[i] - mean) * fea_w[i];   /* (env - mean) .* w */
            fea_im[i] = 0.0;
        }
        fft_core(fea_re, fea_im, nfft);

        for (i = 0; i < nfft; i++) {
            fea_acc[i] += d_hypot(fea_re[i], fea_im[i]); /* acc += |fft(...)| */
        }
        nw++;
    }

    if (nw < 1) { nw = 1; }                              /* MATLAB: max(1, nw) */
    for (i = 0; i < PS_FEAT_NBIN; i++) {
        P_out[i] = fea_acc[i] / (double)nw;
    }
    if (nw_out != NULL) { *nw_out = nw; }
}

static inline void fea_env_spectrum(const double *x,int n,double *out,int *nw)
{ fea_env_spectrum_mode(x,n,out,nw,0); }

/* ------------------------------------------------------------------------------------------
 * 起停通道：一次把 18 维原值算出来。
 *   x 长 n（40000），shaft_hz 是**转频 f_r**，不是阶次。
 *   fea_setup() 必须先跑过（df 在那儿定的）。
 * ------------------------------------------------------------------------------------------ */
static double fea_last_envelope[PS_FEAT_NBIN];
static void fea_frame18_orders(const double *x, int n, double shaft_hz,
                               const double orders[PS_FEAT_NORD], double *v18)
{

    int o, k;

    fea_env_spectrum(x, n, fea_last_envelope, NULL);

    for (o = 0; o < PS_FEAT_NORD; o++) {
        for (k = 1; k <= PS_FEAT_NHARM; k++) {
            /* MATLAB v((o-1)*K + k)，1 起 → 这里 o*4 + (k-1) */
            v18[o * PS_FEAT_NHARM + (k - 1)] =
                fea_peak_near(fea_last_envelope, PS_FEAT_NBIN, (double)k * orders[o] * shaft_hz,
                              fea_df_g, PS_FEAT_HW);
        }
    }
    for (k = 1; k <= 2; k++) {
        /* MATLAB v(numel(ORDERS)*K + k)，1 起 → 16、17 */
        v18[PS_FEAT_NORD * PS_FEAT_NHARM + (k - 1)] =
            fea_peak_near(fea_last_envelope, PS_FEAT_NBIN, (double)k * shaft_hz, fea_df_g, PS_FEAT_HW);
    }
}

/* Preserve the trained legacy feature contract for every existing caller. */
static inline void fea_frame18(const double *x, int n, double shaft_hz, double *v18)
{ fea_frame18_orders(x,n,shaft_hz,fea_orders,v18); }

/* ------------------------------------------------------------------------------------------
 * 原地归一化：v_db = 20*log10((v+eps)/(median(v)+eps))，中位数就取在这 18 维上。
 *
 * 18 是偶数 ⇒ MATLAB median 取**中间两个的平均**，不是任取一个。差一格就是几分之一 dB，
 * 而随机森林的阈值是在这个坐标下定出来的。
 *
 * 插入排序：18 个元素，无递归、无库调用。对数用 ps_env_pipeline.h 里那份手写的 d_log10
 * （链接行没有 -lm）。两者对 (v+eps)/(med+eps) > 0 恒成立 —— 分子分母都带着 eps，
 * 全 0 的谱会得到 0/0 → 1 → 0 dB，和 MATLAB 一致。
 *
 * 返回 median(v)：归一化的刻度参照，调参和排错时想看的就是它（也可以和脚本的 med 对）。
 * ------------------------------------------------------------------------------------------ */
static double fea_norm18(double *v18)
{
    double s[PS_FEAT_NFEAT];
    double med;
    int i, j;

    for (i = 0; i < PS_FEAT_NFEAT; i++) {
        s[i] = v18[i];
    }
    for (i = 1; i < PS_FEAT_NFEAT; i++) {
        double key = s[i];
        j = i - 1;
        while (j >= 0 && s[j] > key) {
            s[j + 1] = s[j];
            j--;
        }
        s[j + 1] = key;
    }
    med = 0.5 * (s[PS_FEAT_NFEAT / 2 - 1] + s[PS_FEAT_NFEAT / 2]);   /* 偶数个 */

    for (i = 0; i < PS_FEAT_NFEAT; i++) {
        v18[i] = 20.0 * d_log10((v18[i] + PS_FEAT_EPS) / (med + PS_FEAT_EPS));
    }
    return med;
}

#endif /* PS_FEATURES_H */
