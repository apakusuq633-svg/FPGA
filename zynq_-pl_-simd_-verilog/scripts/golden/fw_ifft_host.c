/* 核内逆变换（VFFT-inv）与**满幅正变换**的测试向量生成器。
 *
 * 为什么要单独一份
 * ----------------
 * tb_fft_bfly 用的帧是固件里那个三角波（幅度 ≤ 24576），而逆变换在这条链上
 * **根本没有单元级 TB** —— 它以前只以标量形式存在（fw_fft.c 的 ifft512_real）。
 * 硬件那一条是 2026-10-07 才加的（指令 instr[30]），必须有自己的逐位判据。
 *
 * 向量用的是**同一份 C 源码**（sw/fw/fw_fft.c）在 host 上算出来的结果 ——
 * 与固件在核上跑的是同一份，所以"硬件 == golden"等价于"硬件 == 标量固件"。
 *
 * 三个向量
 * --------
 *   1. fft_frame_wide.hex / fw_fft_wide_ref.hex
 *      满幅帧（±30000）的正变换。为什么需要它：拆分那一段的中间和是
 *      (zk + zm)，两个操作数同号时能到 65534 —— 超过 int16。RTL 原来把它
 *      写在 16 位上下文里（**先溢出再移位**），而 C 是 int32_t。
 *      小幅度帧两个操作数不会同时越过 16384，所以那个错一直没被抓住。
 *      这个向量就是把它顶出来的（见 docs/issues/087）。
 *   2. fw_ifft_psi.hex / fw_ifft_ref.hex
 *      逆变换。ψ 直接取固件标量 FFT 的输出（build/fw_fft_ref.hex）——
 *      它是实序列的谱，天然 Hermitian，正是 GCC-PHAT 里 Ψ 的形状
 *      （互谱白化后也是 Hermitian 的）。
 *   3. fw_ifft_psi_wide.hex / fw_ifft_ref_wide.hex
 *      逆变换的**大幅度**版本：把 ψ 整体左移放大到接近满幅，逼出反向拆分
 *      与共轭蝶形里的定标边界。
 *
 * 用法（scripts/golden/fw_ifft_host_check.sh 会做这件事）：
 *     python3 scripts/golden/fw_fft_model.py --ref     # 先有 build/fw_fft_ref.hex
 *     gcc -O2 -I sw/fw -o build/fw_ifft_host \
 *         scripts/golden/fw_ifft_host.c sw/fw/fw_fft.c
 *     ./build/fw_ifft_host
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "fw_fft.h"

#define NBIN    FFT_NBIN            /* 513 */
#define N       FFT_N             /* 1024 */

/* 与固件 fw_main.c 的 make_frame() 逐字相同 —— 但本文件不用它，避免和第二份
   golden（fw_fft_ref.hex）重复。这里只用下面两个满幅帧。 */

static int16_t frame[N];
static int16_t psi[2 * NBIN];
static int16_t out[2 * NBIN];
static int16_t r[N];

static uint32_t rd16(const int16_t *p, int i)      /* 打包成一个小端 32 位字 */
{
    return (uint32_t)(uint16_t)p[i] | ((uint32_t)(uint16_t)p[i + 1] << 16);
}

static int write_words(const char *path, const uint32_t *w, int n, const char *what)
{
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "写不开 %s\n", path); return 1; }
    for (int i = 0; i < n; i++) fprintf(f, "%08x\n", w[i]);
    fclose(f);
    printf("  %-34s %4d 字%s\n", path, n, what);
    return 0;
}

static int read_ref16(const char *path, int16_t *dst, int n)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "打不开 %s —— 先跑 python3 scripts/golden/fw_fft_model.py --ref\n", path);
        return 1;
    }
    for (int i = 0; i < n; i++) {
        unsigned v;
        if (fscanf(f, "%x", &v) != 1) { fprintf(stderr, "%s 读到第 %d 条就断了\n", path, i); fclose(f); return 1; }
        dst[i] = (int16_t)v;
    }
    fclose(f);
    return 0;
}

int main(void)
{
    static uint32_t words[2 * NBIN > N ? 2 * NBIN : N];
    int bad = 0;

    printf("=== fw_ifft_host：生成 VFFT-inv / 满幅正变换的向量 ===\n");

    /* ── 向量 1：满幅帧的正变换 ───────────────────────────────────────
       形状选的是"方波 + 大台阶"—— 它让频域能量集中在少数 bin 上，
       于是拆分那一段能同时读到两个大幅度且同号的 z。 */
    for (int n = 0; n < N; n++) {
        const int ph = n & 127;
        frame[n] = (int16_t)((ph < 64) ? 30000 : -30000);
    }
    /* 前 8 个样点拉到接近满幅：直流分量把 bin 0 顶满 */
    for (int n = 0; n < 8; n++) frame[n] = (int16_t)32767;

    fft_init();
    fft1024(frame, out);
    for (int k = 0; k < NBIN; k++) words[k] = rd16(out, 2 * k);
    bad |= write_words("build/fw_fft_wide_ref.hex", words, NBIN, "（正变换 golden）");
    for (int n = 0; n < FFT_N / 2; n++) words[n] = rd16(frame, 2 * n);
    bad |= write_words("build/fft_frame_wide.hex", words, FFT_N / 2, "（满幅帧输入）");
    if (bad) return 1;

    /* ── 向量 2：逆变换，ψ 取固件标量 FFT 的输出 ───────────────────── */
    if (read_ref16("build/fw_fft_ref.hex", psi, 2 * NBIN)) return 1;
    for (int k = 0; k < NBIN; k++) words[k] = rd16(psi, 2 * k);
    bad |= write_words("build/fw_ifft_psi.hex", words, NBIN, "（ψ 输入）");

    ifft512_real(psi, r);
    for (int n = 0; n < N / 2; n++) words[n] = rd16(r, 2 * n);
    bad |= write_words("build/fw_ifft_ref.hex", words, N / 2, "（逆变换 golden）");

    /* ── 向量 3：逆变换的满幅版本 ───────────────────────────────────────
       把 ψ 整体左移到接近满幅。⚠ 直接乘会溢出 int16 —— 用"左移到 32767
       以下的最大 2 的幂"这种写法，逐位可复现，也没有取整歧义。 */
    {
        int32_t mx = 0;
        for (int k = 0; k < 2 * NBIN; k++) {
            const int32_t a = (psi[k] < 0) ? -psi[k] : psi[k];
            if (a > mx) mx = a;
        }
        int sh = 0;
        while (sh < 8 && (mx << (sh + 1)) <= 32767) sh++;
        for (int k = 0; k < 2 * NBIN; k++) psi[k] = (int16_t)((int32_t)psi[k] << sh);
        printf("  （满幅 ψ：整体左移 %d 位，最大值 %d → %d）\n", sh, mx, mx << sh);

        for (int k = 0; k < NBIN; k++) words[k] = rd16(psi, 2 * k);
        bad |= write_words("build/fw_ifft_psi_wide.hex", words, NBIN, "（满幅 ψ 输入）");

        ifft512_real(psi, r);
        for (int n = 0; n < N / 2; n++) words[n] = rd16(r, 2 * n);
        bad |= write_words("build/fw_ifft_ref_wide.hex", words, N / 2, "（满幅逆变换 golden）");
    }

    if (bad) { printf("FAIL: 有文件没写出去\n"); return 1; }
    printf("OK\n");
    return 0;
}
