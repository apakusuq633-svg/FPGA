/* GCC-PHAT 内核的 host 侧验证 —— 与 fw_fft_host.c 同一套路数。
 *
 * 把 sw/fw/fw_fft.c + fw_tables.c + fw_gcc.c **原样**编到 host 上，对着
 * Python 生成的参照逐条比。秒级出结果，仿真要跑上百万拍。
 *
 * 编译运行见 scripts/golden/fw_gcc_host_check.sh。
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "fw_fft.h"
#include "fw_gcc.h"

#define LCG_A       1103515245u
#define LCG_C       12345u
#define LCG_SEED    0x12345678u
#define TEST_DELAY  7

/* 与固件 fw_main.c 逐字相同的两份生成器（三方一致的第三份） */
static int16_t frm[FFT_N];

static int16_t sample_at(uint32_t s, int m)
{
    int32_t noise = (int32_t)((s >> 16) & 0x3FFFu);
    int32_t ph = m & 63;
    int32_t tri = (ph < 32) ? (ph * 1024 - 16384) : (49152 - ph * 1024);
    return (int16_t)(tri + (noise - 8192));
}

static void make_frame(void)
{
    uint32_t s = LCG_SEED;
    for (int i = 0; i < FFT_N; i++) {
        s = s * LCG_A + LCG_C;
        frm[i] = sample_at(s, i);
    }
}

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
        frm[n] = sample_at(s, m);
    }
}

int main(int argc, char **argv)
{
    const char *ref_path = (argc > 1) ? argv[1] : "build/fw_gcc_ref.hex";
    FILE *f = fopen(ref_path, "r");
    if (!f) { fprintf(stderr, "打不开参照 %s\n", ref_path); return 2; }

    static int16_t ref[FFT_N], r[FFT_N];
    for (int i = 0; i < FFT_N; i++) {
        unsigned v;
        if (fscanf(f, "%x", &v) != 1) { fprintf(stderr, "参照读到第 %d 条就断了\n", i); return 2; }
        ref[i] = (int16_t)v;
    }
    fclose(f);

    int32_t lag = 0;
    make_frame();
    gcc_load_a(frm);
    make_frame_shifted(TEST_DELAY);
    gcc_load_b(frm);
    gcc_finish(r, &lag);

    int bad = 0;
    for (int i = 0; i < FFT_N; i++) {
        if (r[i] != ref[i]) bad++;
    }

    printf("=== GCC-PHAT 内核 host 侧比对 ===\n");
    printf("  峰值滞后 %+d（期望 %+d）\n", lag, TEST_DELAY);
    printf("  相关序列 %d/%d 条不符\n", bad, FFT_N);
    if (bad == 0 && lag == TEST_DELAY) {
        printf("PASS: C 内核与 Python 定点模型逐位一致，已知时延复现\n");
        return 0;
    }
    printf("FAIL: 先查 fw_gcc.c / fw_fft.c，别去查仿真\n");
    return 1;
}
