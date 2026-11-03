/* 1024 点实数 FFT —— 定位链的第一块固件内核，也是**标量基线**。
 *
 * 后面 GCC-PHAT / SRP / 波束形成全建在它上面：互谱是 FFT 的乘积、IFFT 是同一个
 * 内核、SRP 的相关序列是 IFFT 的输出。所以这一块的 cycles 决定了整条链的量级。
 *
 * ⚠ 与 scripts/golden/fw_fft_model.py **逐位等价**。改这里必须同步改那边并重跑
 *   它的自检 —— 那边对不上 float 金标准就是算法错了，这边对不上那边就是搬写错了。
 *   两类错的查法完全不同，别混。
 *
 * 定标（改了要重算溢出，见模型头部的推导）
 *   输入 x     Q15 int16
 *   旋转因子   Q14 int16（Q15 装不下 1.0，见 docs/issues/029）
 *   工作数组   int16，靠**每级 >>1** 把幅度钉在 32767 以内
 *   输出 X     Q15 int16，标度 = 真值 / 1024
 *
  * 实测：198915 拍（1024 点）；精度对 float 金标准 SNR 51.9 dB（模型自检给出）。
 * 上限来自 16 位数据通路 —— 每级都要 >>1，9 级下来就是这样。要提高得上 64 位
 * 乘积（RV32IM 的 mulh+mul），代价是每条乘积多 4 条指令。**先不做**：
 * 下游 PHAT 会白化，只吃相位；真影响定位精度的话再回头换，那时有实测数字撑腰。
 */
#include <stdint.h>

#include "fw_fft.h"        /* FW_HAVE_HW / FW_ACCEL —— 本文件的两个 #if 都靠它 */
#include "fw_tables.h"

#include "fw_cycle_profile.h"
#if FW_CYCLE_PROFILE
uint32_t fw_fft_profile[3];
uint32_t fw_ifft_profile[3];
#endif
#define FFT_N       1024
#define FFT_M       (FFT_N / 2)        /* 512：复数 FFT 的点数 */
#define FFT_NBIN    (FFT_N / 2 + 1)    /* 513：实数 FFT 的输出条数 */
#define FFT_LOG2M   9

/* 工作区。.bss，启动代码清零，不进镜像。
   注意**没有**输出数组：结果直接写调用方给的 out（固定输出区 0x2400），
   省掉一份 2 KB 的中转缓冲 —— 那块存储器本来就是 RAM，直写不多花一拍。

   **也没有位反转表**：512 条的 uint16 表要 1 KB，而就地交换的写法每次只多
   两条指令（实测 FFT 总拍数没有可分辨的变化），DTCM 只有 16 KB，这 1 KB
   留给 GCC-PHAT 的频谱缓冲更值。 */
static int16_t g_zr[FFT_M], g_zi[FFT_M];

void fft_init(void)
{
    /* 表已经不建了，函数保留是为了接口稳定（调用方不必知道这件事）。 */
}

/* 位反转置换（就地交换，不建表）。经典增量算法：
   把 j 当成 i 的位反转，靠「从低位往上找第一个 0」逐次推进。 */
static void bitrev_swap(int16_t *re, int16_t *im)
{
    uint32_t j = 0;
    for (uint32_t i = 1; i < FFT_M; i++) {
        uint32_t bit = FFT_M >> 1;
        for (; (j & bit) != 0u; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            int16_t t;
            t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
}

/* 512 点复数基 2 DIT，每级 >>1。inv=1 时用共轭因子（即 IFFT，已含 1/M）。
   正变换与逆变换共用这一段 —— 逆变换的唯一差别就是因子的符号。 */
static void butterflies512(int16_t *re, int16_t *im, int inv)
{
    for (uint32_t len = 2; len <= FFT_M; len <<= 1) {
        const uint32_t half = len >> 1;
        /* ⚠ 表是 W_1024^k，这一级要的是 W_512^j = W_1024^{2j}，所以下标乘 2。
           漏掉这个 2 时 j=0 那条（w=1）永远是对的，从 j=1 起全错 ——
           看上去像「蝶形接反」，其实是因子取错频点。 */
        const uint32_t step = (FFT_M / len) * 2u;
        for (uint32_t start = 0; start < FFT_M; start += len) {
            const uint32_t hi = start + half;
            for (uint32_t j = 0; j < half; j++) {
                const int32_t wr = g_tw_re[j * step];
                const int32_t wim = g_tw_im[j * step];
                const int32_t wi = inv ? -wim : wim;
                const int32_t ar = re[start + j], ai = im[start + j];
                const int32_t br = re[hi + j],    bi = im[hi + j];
                const int32_t tr = (wr * br - wi * bi + (1 << (FW_TW_FRAC - 1)))
                                   >> FW_TW_FRAC;
                const int32_t ti = (wr * bi + wi * br + (1 << (FW_TW_FRAC - 1)))
                                   >> FW_TW_FRAC;
                re[start + j] = (int16_t)((ar + tr + 1) >> 1);
                im[start + j] = (int16_t)((ai + ti + 1) >> 1);
                re[hi + j]    = (int16_t)((ar - tr + 1) >> 1);
                im[hi + j]    = (int16_t)((ai - ti + 1) >> 1);
            }
        }
    }
}

/* 1024 点实数 FFT。x 是 1024 个 Q15；out 收 513 条复数，re/im 交替，Q15。
 *
 * ⚠ 这里所有 `>>` 都依赖「算术右移 = 向下取整」。C 标准把它留给实现，GCC 在
 *   RISC-V 上发的是 srai（算术移位），与 Python 的 // 一致 —— 这是两边能逐位
 *   对上的前提。换成会对负数向零取整的语言/编译器，模型就跟着错，而且只错负数，
 *   表现为「大信号对、小信号差一点」。
 */
void fft1024(const int16_t *x, volatile int16_t *out)
{
    /* ── 1. 打包：z[n] = x[2n] + j·x[2n+1] ────────────────────────── */
    for (uint32_t n = 0; n < FFT_M; n++) {
        g_zr[n] = x[2u * n];
        g_zi[n] = x[2u * n + 1u];
    }

    /* ── 2. 位反转 + 蝶形（9 级，每级 >>1）───────────────────────── */
    bitrev_swap(g_zr, g_zi);
    butterflies512(g_zr, g_zi, 0);

    /* ── 3. 拆分 E/O 并合成 X[k] = (E[k] + W^k·O[k]) >> 1 ─────────── */
    /* E[k] = (Z[k] + conj(Z[(M−k)%M]))/2 , O[k] = (Z[k] − conj(·))/2j */
    int32_t e0r = 0, o0r = 0;                 /* k=512 要用 E[0] 与 O[0] */
    for (uint32_t k = 0; k < FFT_M; k++) {
        const uint32_t m = (FFT_M - k) & (FFT_M - 1u);   /* (512−k) mod 512 */
        const int32_t zr = g_zr[k],  zi = g_zi[k];
        const int32_t zmr = g_zr[m], zmi = g_zi[m];
        const int32_t er  = (zr + zmr) >> 1;
        const int32_t ei  = (zi - zmi) >> 1;
        const int32_t orr = (zi + zmi) >> 1;
        const int32_t oi  = (zmr - zr) >> 1;
        const int32_t wr = g_tw_re[k], wi = g_tw_im[k];
        const int32_t tr = (wr * orr - wi * oi + (1 << (FW_TW_FRAC - 1)))
                           >> FW_TW_FRAC;
        const int32_t ti = (wr * oi + wi * orr + (1 << (FW_TW_FRAC - 1)))
                           >> FW_TW_FRAC;
        if (k == 0) { e0r = er; o0r = orr; }
        out[2u * k]      = (int16_t)((er + tr) >> 1);
        out[2u * k + 1u] = (int16_t)((ei + ti) >> 1);
    }

    /* ── 4. 第 513 条：k = 512，W^512 = −1 ⇒ X = (E[0] − O[0]) >> 1，纯实 ── */
    out[2u * FFT_M]      = (int16_t)((e0r - o0r) >> 1);
    out[2u * FFT_M + 1u] = 0;
}

/* ── 硬件 VFFT 通路 ────────────────────────────────────────────────────
 *
 * 一条 .insn 就是一条自定义指令。编码（见 rtl/rv32_defines.vh 与
 * rtl/acoustic/rv32_fft_bfly.v 头部）：
 *     funct3 = 111，instr[31] = 1 → VFFT
 *     instr[29]=1          → 运算
 *     instr[29]=0, [28]=0  → PUSH（rs1 = 一条复数）
 *     instr[29]=0, [28]=1  → POP （rd = 一条 bin）
 * 用 R 型的 funct7 表达：[31:25] = {bit31, bit30, bit29, bit28, 27, 26, 25}
 *     PUSH 0b1000000 = 0x40    RUN 0b1010000 = 0x50    POP 0b1001000 = 0x48
 *
 * ⚠ 用 .insn 而不是 `.word 0x8002F00B`：rs1 要随 C 变量变，手搓机器码就得
 *   自己拼位域 —— 而拼错一位不会报错，只会让单元收到别的指令。
 *
 * 与 fft1024() **逐位等价**（同一份 golden，这是验收标准）。
 */
#if FW_HAVE_HW
void fft1024_hw(const int16_t *x, volatile int16_t *out)
{
    MEM_PHASE(3);
    const uint32_t *src = (const uint32_t *)x;   /* 1024 个 int16 = 512 条复数 */
#if FW_CYCLE_PROFILE
    uint32_t t0=read_cycles();
#endif

    for (int i = 0; i < 512; i++) {
        const uint32_t w = src[i];
        __asm__ volatile(".insn r 0x0B, 7, 0x40, x0, %0, x0" :: "r"(w));
    }
#if FW_CYCLE_PROFILE
    uint32_t t1=read_cycles();
#endif
    MEM_PHASE(4);
    __asm__ volatile(".insn r 0x0B, 7, 0x50, x0, x0, x0");
#if FW_CYCLE_PROFILE
    uint32_t t2=read_cycles();
#endif
    MEM_PHASE(5);

    /* ⚠ 取回时**整字存**，不要拆成两次 int16。
     *   一次 16 位存储走 DTCM 是 2 拍，两条就是 4 拍；整字只要 2 拍。
     *   字节布局完全一样（小端：word = re | im<<16），所以 golden 与 TB 都不用改。
     *   实测：拆成两次时整台 FFT 10424 拍，整字之后降到 ~8370 拍。 */
    volatile uint32_t *dst = (volatile uint32_t *)out;
    for (int i = 0; i < 513; i++) {
        uint32_t v;
        __asm__ volatile(".insn r 0x0B, 7, 0x48, %0, x0, x0" : "=r"(v));
        dst[i] = v;
    }
#if FW_CYCLE_PROFILE
    uint32_t t3=read_cycles();
    fw_fft_profile[0]=t1-t0;
    fw_fft_profile[1]=t2-t1;
    fw_fft_profile[2]=t3-t2;
#endif
}

/* ── 硬件逆变换通路（VFFT-inv，指令的 instr[30] = 1）────────────────────
 *
 * 与上面的 fft1024_hw 是**同一条指令的三个 funct7**，只是把 instr[30] 打开：
 *     PUSH 0x60（rs1 = 一条复数 ψ）  RUN 0x70   POP 0x68（rd = 一条实样点对）
 *
 * ⚠ 两头的条数与正变换**不一样**，别照抄：
 *     灌 **513** 条（ψ 的 bin 0..512，Hermitian 谱），出 **512** 条
 *     （1024 个 int16 实样点 = 512 个字）。
 *   多出来的那一条输入（ψ[512]，Nyquist）在单元里走单独的寄存器，
 *   与正变换把 bin 512 放在 nyq_q 正好对称。
 *
 * 与 ifft512_real() **逐位等价**（同一份 golden，这是验收标准）。
 */
void ifft512_real_hw(const int16_t *psi, volatile int16_t *r_out)
{
    const uint32_t *src = (const uint32_t *)psi;   /* 513 条复数 = 513 字 */

    for (int i = 0; i < 513; i++) {
        const uint32_t w = src[i];
        __asm__ volatile(".insn r 0x0B, 7, 0x60, x0, %0, x0" :: "r"(w));
    }
    __asm__ volatile(".insn r 0x0B, 7, 0x70, x0, x0, x0");

    /* 同 fft1024_hw：**整字存**，不拆两次 int16（一次 16 位存储走 DTCM 是 2 拍）。
       小端下 word = re | im<<16，与 ifft512_real 的两次 int16 存字节布局一样。 */
    volatile uint32_t *dst = (volatile uint32_t *)r_out;
    for (int i = 0; i < 512; i++) {
        uint32_t v;
        __asm__ volatile(".insn r 0x0B, 7, 0x68, %0, x0, x0" : "=r"(v));
        dst[i] = v;
    }
}
/* SEEK changes only the registered read pointer; ordinary POP stays unchanged. */
void ifft512_real_ring_hw(const int16_t *psi, volatile int16_t *r_out)
{
    MEM_PHASE(7);
#if FW_CYCLE_PROFILE
    uint32_t t0=read_cycles();
#endif
    const uint32_t *src=(const uint32_t *)psi;
    for(unsigned i=0;i<513;i++) {
        uint32_t w=src[i];
        __asm__ volatile(".insn r 0x0B, 7, 0x60, x0, %0, x0" :: "r"(w));
    }
#if FW_CYCLE_PROFILE
    uint32_t t1=read_cycles();
#endif
    __asm__ volatile(".insn r 0x0B, 7, 0x70, x0, x0, x0");
#if FW_CYCLE_PROFILE
    uint32_t t2=read_cycles();
#endif
    volatile uint32_t *dst=(volatile uint32_t *)r_out;
    for(unsigned i=0;i<8;i++) {
        uint32_t w;
        __asm__ volatile(".insn r 0x0B, 7, 0x68, %0, x0, x0" : "=r"(w));
        dst[i]=w;
    }
    uint32_t index=504;
    __asm__ volatile(".insn r 0x0B, 7, 0x6c, x0, %0, x0" :: "r"(index));
    for(unsigned i=504;i<512;i++) {
        uint32_t w;
        __asm__ volatile(".insn r 0x0B, 7, 0x68, %0, x0, x0" : "=r"(w));
        dst[i]=w;
    }
#if FW_CYCLE_PROFILE
    uint32_t t3=read_cycles();
    fw_ifft_profile[0]=t1-t0;fw_ifft_profile[1]=t2-t1;fw_ifft_profile[2]=t3-t2;
#endif
    MEM_PHASE(6);
}
#endif /* FW_HAVE_HW */

/* 实数逆变换：Hermitian 频谱（513 条，re/im 交替）→ 1024 点实序列。
 *
 * 贴着正变换反着做（公式推导见 scripts/golden/fw_gcc_model.py 头部）：
 *   反向拆分 → Z（512 点复）→ 共轭因子 IFFT → unpack
 *
 * 为什么走打包而不是直白的 1024 点复 IFFT：**内存**。DTCM 只有 16 KB，
 * 1024 点复工作数组要 4 KB，打包版只要 512 点复（2 KB），而且**和正变换
 * 共用同一块工作区**。
 *
 * ⚠ 反向拆分里 X[k+M] 的取法是 conj(X[M−k])，k=0 时是第 **512** 条
 *   （Nyquist），不是第 0 条。写成 (M−k)%M 会把 DC 当 Nyquist 用 ——
 *   结果序列形状大致对、残差十几个百分点，很难一眼看出是下标错。
 */
void ifft512_real(const int16_t *psi, volatile int16_t *r_out)
{
    /* ── 1. 反向拆分：Psi → Z ─────────────────────────────────────── */
    for (uint32_t k = 0; k < FFT_M; k++) {
        const uint32_t m = FFT_M - k;                 /* 不取模！见函数头 */
        const int32_t pr = psi[2u * k],      pi = psi[2u * k + 1u];
        const int32_t qr = psi[2u * m],      qi = -psi[2u * m + 1u];
        const int32_t er = (pr + qr) >> 1;
        const int32_t ei = (pi + qi) >> 1;
        const int32_t hr = (pr - qr) >> 1;
        const int32_t hi = (pi - qi) >> 1;
        const int32_t wr = g_tw_re[k], wi = g_tw_im[k];
        /* O = (X[k]−X[k+M])/2 · conj(W^k) */
        const int32_t orr = (hr * wr + hi * wi + (1 << (FW_TW_FRAC - 1)))
                            >> FW_TW_FRAC;
        const int32_t oi = (hi * wr - hr * wi + (1 << (FW_TW_FRAC - 1)))
                           >> FW_TW_FRAC;
        /* Z[k] = E[k] + j·O[k]；两者各 ≤ 16384，差/和也 ≤ 16384（见模型里的
           能量关系），所以存 int16 不溢出。 */
        g_zr[k] = (int16_t)(er - oi);
        g_zi[k] = (int16_t)(ei + orr);
    }

    /* ── 2. 位反转 + 共轭因子 IFFT ────────────────────────────────── */
    bitrev_swap(g_zr, g_zi);
    butterflies512(g_zr, g_zi, 1);

    /* ── 3. unpack：R[2n] = Re z[n]，R[2n+1] = Im z[n] ────────────── */
    for (uint32_t n = 0; n < FFT_M; n++) {
        r_out[2u * n]      = g_zr[n];
        r_out[2u * n + 1u] = g_zi[n];
    }
}
