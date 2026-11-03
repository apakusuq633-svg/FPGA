/* SRP 扫描内核的 host 侧验证。见 fw_fft_host.c 的说明。 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#include "fw_srp.h"

#define R_LEN 1024

static int16_t r_seq[R_LEN];
static int16_t tau[SRP_GRID_N];
static int32_t p_acc[SRP_GRID_N];

static int load_hex16(const char *path, int16_t *dst, int n)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "打不开 %s\n", path); return -1; }
    for (int i = 0; i < n; i++) {
        unsigned v;
        if (fscanf(f, "%x", &v) != 1) { fclose(f); return -1; }
        dst[i] = (int16_t)v;
    }
    fclose(f);
    return 0;
}

static int load_hex32(const char *path, int32_t *dst, int n)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "打不开 %s\n", path); return -1; }
    for (int i = 0; i < n; i++) {
        unsigned v;
        if (fscanf(f, "%x", &v) != 1) { fclose(f); return -1; }
        dst[i] = (int32_t)v;
    }
    fclose(f);
    return 0;
}

int main(void)
{
    static int16_t tau_ref[SRP_GRID_N];
    static int32_t p_ref[SRP_GRID_N];
    int bad_tau = 0, bad_p = 0;

    if (load_hex16("build/fw_srp_tau.hex", tau_ref, SRP_GRID_N) < 0) return 2;
    if (load_hex32("build/fw_srp_p.hex", p_ref, SRP_GRID_N) < 0) return 2;
    if (load_hex16("build/fw_gcc_ref.hex", r_seq, R_LEN) < 0) return 2;

    srp_init();
    srp_dump_tau(0, 1, tau);
    for (int i = 0; i < SRP_GRID_N; i++) if (tau[i] != tau_ref[i]) bad_tau++;

    for (int i = 0; i < SRP_GRID_N; i++) p_acc[i] = 0;
    const int pi4[4] = {0, 0, 0, 0}, pj4[4] = {1, 2, 3, 4};
    for (int p = 0; p < 4; p++) srp_acc_pair(r_seq, pi4[p], pj4[p], p_acc);
    for (int i = 0; i < SRP_GRID_N; i++) if (p_acc[i] != p_ref[i]) bad_p++;

    printf("=== SRP 扫描内核 host 侧比对 ===\n");
    printf("  延迟转储 %d/%d 条不符\n", bad_tau, SRP_GRID_N);
    printf("  累加器   %d/%d 条不符\n", bad_p, SRP_GRID_N);
    if (bad_tau == 0 && bad_p == 0) {
        printf("PASS: C 内核与 Python 定点模型逐位一致\n");
        return 0;
    }
    printf("FAIL: 先查 fw_srp.c，别去查仿真\n");
    return 1;
}
