/* FFT 内核的 **host 侧**验证 —— 四层验证里最快的一层。
 *
 *    Python 定点模型  →  **本文件（同一份 C 源码，x86 上跑）**  →  仿真  →  上板
 *
 * 把 sw/fw/fw_fft.c **原样**编到 host 上，对着 Python 生成的参照逐字比。
 * 秒级出结果，而同样的错在仿真里要跑 74 万拍才发现，还分不清是「算法错」
 * 还是「内存/Soc 搬写错」。
 *
 * 编译运行（scripts/golden/fw_fft_host_check.sh 会做这件事）：
 *     gcc -O2 -I sw/fw -o build/fw_fft_host \
 *         scripts/golden/fw_fft_host.c sw/fw/fw_fft.c
 *     ./build/fw_fft_host build/fw_fft_ref.hex
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "fw_fft.h"

/* 与固件 fw_main.c 的 make_frame() 逐字相同（三方一致的第三份） */
#define FFT_IN_N    1024
#define LCG_A       1103515245u
#define LCG_C       12345u
#define LCG_SEED    0x12345678u

static int16_t frame[FFT_IN_N];
static int16_t out[2 * FFT_NBIN];

static void make_frame(void)
{
    uint32_t s = LCG_SEED;
    for (int i = 0; i < FFT_IN_N; i++) {
        s = s * LCG_A + LCG_C;
        int32_t noise = (int32_t)((s >> 16) & 0x3FFFu);
        int32_t ph = i & 63;
        int32_t tri = (ph < 32) ? (ph * 1024 - 16384) : (49152 - ph * 1024);
        frame[i] = (int16_t)(tri + (noise - 8192));
    }
}

int main(int argc, char **argv)
{
    const char *ref_path = (argc > 1) ? argv[1] : "build/fw_fft_ref.hex";
    FILE *f = fopen(ref_path, "r");
    if (!f) { fprintf(stderr, "打不开参照 %s\n", ref_path); return 2; }

    static int16_t ref[2 * FFT_NBIN];
    for (int i = 0; i < 2 * FFT_NBIN; i++) {
        unsigned v;
        if (fscanf(f, "%x", &v) != 1) { fprintf(stderr, "参照读到第 %d 条就断了\n", i); return 2; }
        ref[i] = (int16_t)v;
    }
    fclose(f);

    make_frame();
    fft_init();
    fft1024(frame, out);

    int bad = 0, first = -1;
    for (int k = 0; k < FFT_NBIN; k++) {
        if (out[2*k] != ref[2*k] || out[2*k+1] != ref[2*k+1]) {
            bad++;
            if (first < 0) {
                first = k;
                printf("  首个不符 bin %d: 实测 (%d, %d)  期望 (%d, %d)\n",
                       k, out[2*k], out[2*k+1], ref[2*k], ref[2*k+1]);
            }
        }
    }

    printf("=== FFT 内核 host 侧比对 ===\n");
    printf("  %d/%d 条不符\n", bad, FFT_NBIN);
    if (bad == 0) {
        printf("PASS: C 内核与 Python 定点模型逐位一致\n");
        return 0;
    }
    printf("FAIL: 算法或定标与模型不一致 —— 先查 fw_fft.c，别去查仿真\n");
    return 1;
}
