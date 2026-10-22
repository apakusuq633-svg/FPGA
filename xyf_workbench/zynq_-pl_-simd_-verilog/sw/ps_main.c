/* PS acceptance of the real RV32 acoustic firmware. Fixed FIR replaces GSC.
 * Build scripts/build_acoustic_acceptance.sh first, then install -App rv32.
 * PASS requires independent FFT/GCC/DAS/FIR results, not LED activity.
 * This test uses generated deterministic acoustic scenes; live PDM is separate.
 */
#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#ifdef ACOUSTIC_JITTER
#include "acoustic_image_jit.h"    /* FW_JITTER_N>0 的逐帧抖动镜像 */
#elif defined(ACOUSTIC_BASELINE_IMAGE)
#include "acoustic_image_base.h"   /* FW_ACCEL=0 的全标量镜像 */
#else
#include "acoustic_image.h"
#endif

#ifndef RV32_BASE
#define RV32_BASE 0x43C00000u
#endif
#define R_CTRL       0x000u
#define R_STATUS     0x004u
#define R_IRQ_STAT   0x018u
#define R_IRQ_MASK   0x01Cu
#define R_RETIRE_CNT 0x020u
#define R_TRAP_CNT   0x030u
#define R_TOHOST     0x034u
#define R_FROMHOST   0x03Cu
#define R_MEM_ADDR   0x080u
#define R_MEM_WDATA  0x084u
#define R_MEM_RDATA  0x088u
#define R_MEM_CTRL   0x08Cu
#define R_COEF_ADDR  0x0C0u
#define R_COEF_WDATA 0x0C4u
#define R_COEF_RDATA 0x0C8u
#define R_STEER_CTRL 0x600u
#define R_STEER_STAT 0x604u
#define R_STEER_ADDR 0x608u
#define R_STEER_DATA 0x60Cu
#define CTRL_HALT 2u
#define CTRL_START 1u
#define CTRL_SOFT_RST 16u
#define ST_HALTED 4u
#define ST_ERR 16u
#define MEM_SEL_DTCM 0x80000000u
#define ACOUSTIC_DONE 0xC0DE0001u

static int failures;
static inline void wr(uint32_t off, uint32_t v) { Xil_Out32(RV32_BASE + off, v); }
static inline uint32_t rd(uint32_t off) { return Xil_In32(RV32_BASE + off); }

static void delay_ms(uint32_t ms)
{
    for (volatile uint32_t i = 0; i < ms * 130000u; ++i) __asm__ volatile("nop");
}

static void hex32(uint32_t v)
{
    const char *digits = "0123456789abcdef";
    char s[9];
    for (int i = 7; i >= 0; --i) { s[i] = digits[v & 15u]; v >>= 4; }
    s[8] = 0;
    xil_printf("%s", s);
}

static uint32_t downloads_ok = 1u;

/* 不经 check() 的那几处失败（结果块的逐字比对）也要跟着计量模式走，
   否则基线镜像会在日志末尾留下一个 FAIL —— 而那只是"阵列版的指纹对不上
   标量版的结果"，本来就不该相等。留一个假的 FAIL 比留一个假的 PASS 更坏：
   下一个人会去查一个不存在的故障。 */
static void note_failure(void)
{
#ifndef ACOUSTIC_MEASURE_ONLY
    ++failures;
#endif
}

static void check(int ok, const char *label)
{
#ifdef ACOUSTIC_MEASURE_ONLY
    /* 计量模式（整机加速比对照用）：判据照打，但不计入失败。
       基线镜像在 "VFFT executed" / "SIMD FIR executed" 那几条上**本来**就该是
       n/a —— 它一条自定义指令都没发（那正是它的定义）。对照要的是拍数。 */
    xil_printf("  [%s] %s\r\n", ok ? "ok" : "n/a", label);
    (void)ok;
#else
    xil_printf("  [%s] %s\r\n", ok ? "ok" : "FAIL", label);
    if (!ok) ++failures;
#endif
}

static int download(const uint32_t *data, uint32_t count, uint32_t select)
{
    wr(R_MEM_ADDR, select);
    for (uint32_t i = 0; i < count; ++i) wr(R_MEM_WDATA, data[i]);
    wr(R_MEM_ADDR, select);
    for (uint32_t i = 0; i < count; ++i) {
        if (rd(R_MEM_RDATA) != data[i]) {
            xil_printf("  [FAIL] TCM readback index %u\r\n", (unsigned)i);
            return 0;
        }
    }
    return 1;
}

static uint32_t dtcm(uint32_t byte_addr)
{
    wr(R_MEM_ADDR, MEM_SEL_DTCM | (byte_addr >> 2));
    return rd(R_MEM_RDATA);
}

static int prepare(void)
{
    wr(R_CTRL, CTRL_SOFT_RST | CTRL_HALT);
    delay_ms(10);
    check((rd(R_STATUS) & ST_HALTED) != 0u, "RV32 halted before download");
    wr(R_IRQ_STAT, 7u);
    wr(R_IRQ_MASK, 0u);
    wr(R_MEM_CTRL, 2u);
    {
        const uint32_t itcm_ok = download(acoustic_itcm, ACOUSTIC_ITCM_WORDS, 0u);
        const uint32_t dtcm_ok = download(acoustic_dtcm, ACOUSTIC_DTCM_WORDS, MEM_SEL_DTCM);
        downloads_ok = itcm_ok & dtcm_ok;
        check(itcm_ok != 0u, "acoustic ITCM readback");
        check(dtcm_ok != 0u, "acoustic DTCM readback");
    }
    /* Clear prior results; an old successful run must not pass a timeout. */
    wr(R_MEM_ADDR, MEM_SEL_DTCM | (0x2800u >> 2));
    for (unsigned i = 0; i < 32; ++i) wr(R_MEM_WDATA, 0u);
    wr(R_MEM_ADDR, MEM_SEL_DTCM | (0x3C40u >> 2));
    for (unsigned i = 0; i < 16; ++i) wr(R_MEM_WDATA, 0u);
    wr(R_MEM_ADDR, MEM_SEL_DTCM | (0x38C0u >> 2));
    for (unsigned i = 0; i < 8; ++i) wr(R_MEM_WDATA, 0u);
    wr(R_COEF_ADDR, 0u);
    for (unsigned i = 0; i < ACOUSTIC_FIR_COEFF_WORDS; ++i)
        wr(R_COEF_WDATA, acoustic_fir_coeff[i]);
    wr(R_COEF_ADDR, 0u);
    int coef_ok = 1;
    for (unsigned i = 0; i < ACOUSTIC_FIR_COEFF_WORDS; ++i)
        if (rd(R_COEF_RDATA) != acoustic_fir_coeff[i]) coef_ok = 0;
    check(coef_ok, "fixed FIR coefficients loaded and verified");
    wr(R_STEER_CTRL, 2u);
    wr(R_STEER_ADDR, 0u);
    for (unsigned i = 0; i < ACOUSTIC_STEER_LUT_WORDS; ++i)
        wr(R_STEER_DATA, acoustic_steer_lut[i]);
    check((rd(R_STEER_STAT) & 8u) == 0u, "steering LUT preload accepted");
    check((rd(R_STATUS) & ST_ERR) == 0u, "no rejected preload writes");
#ifdef ACOUSTIC_MEASURE_ONLY
    /* 计量模式下 check() 不计失败，所以"装没装上"必须自己盯 —— 下载回读失败
       的镜像跑出来的拍数是没有意义的（而且会好看得多）。 */
    return downloads_ok != 0u;
#else
    return failures == 0;
#endif
}

int main(void)
{
    xil_printf("\r\n===== RV32 ACOUSTIC acceptance (DAS/FIR required) =====\r\n");
    xil_printf("ITCM SHA256 %s\r\n", ACOUSTIC_ITCM_SHA256);
    if (prepare()) {
        wr(R_FROMHOST, 0u);
        wr(R_CTRL, CTRL_START | CTRL_HALT);
        wr(R_CTRL, 0u);
        unsigned poll;
        for (poll = 0; poll < 10000u; ++poll) {
            if (rd(R_TOHOST) == ACOUSTIC_DONE || rd(R_TRAP_CNT) != 0u) break;
            delay_ms(1);
        }
        check(rd(R_TOHOST) == ACOUSTIC_DONE, "acoustic firmware completed (bounded wait)");
        wr(R_CTRL, CTRL_HALT);
        delay_ms(1);
        check((rd(R_STATUS) & ST_HALTED) != 0u, "RV32 stopped for stable result readback");
        check(rd(R_TRAP_CNT) == 0u, "no illegal instruction or trap");
        check(rd(R_RETIRE_CNT) > 0u, "acoustic firmware retired instructions");
        for (unsigned i = 0; i < ACOUSTIC_CHECK_ADDR_WORDS; ++i) {
            uint32_t got = dtcm(acoustic_check_addr[i]);
            if (got != acoustic_check_value[i]) {
                note_failure();
                xil_printf("  [FAIL] acoustic result at 0x"); hex32(acoustic_check_addr[i]);
                xil_printf(" want 0x"); hex32(acoustic_check_value[i]);
                xil_printf(" got 0x"); hex32(got); xil_printf("\r\n");
            }
        }
        unsigned fft_bad = 0, gcc_bad = 0;
        wr(R_MEM_ADDR, MEM_SEL_DTCM | (0x2880u >> 2));
        for (unsigned i = 0; i < ACOUSTIC_FFT_REF_WORDS; ++i)
            if (rd(R_MEM_RDATA) != acoustic_fft_ref[i]) ++fft_bad;
        wr(R_MEM_ADDR, MEM_SEL_DTCM | (0x30C0u >> 2));
        for (unsigned i = 0; i < ACOUSTIC_GCC_REF_WORDS / 2u; ++i) {
            uint32_t got = rd(R_MEM_RDATA);
            if ((got & 65535u) != (acoustic_gcc_ref[2*i] & 65535u)) ++gcc_bad;
            if ((got >> 16) != (acoustic_gcc_ref[2*i+1] & 65535u)) ++gcc_bad;
        }
        check(fft_bad == 0u, "VFFT 513 complex bins match independent golden");
        check(gcc_bad == 0u, "GCC-PHAT 1024 samples match independent golden");
        uint32_t fft_scalar = dtcm(0x2818u), fft_hw = dtcm(0x2850u);
        uint32_t fir_scalar = dtcm(0x38D0u), fir_vec = dtcm(0x38D4u);
        check(fft_hw > 0u && fft_hw < fft_scalar, "VFFT executed and reduced cycles");
        check(fir_vec > 0u && fir_vec < fir_scalar, "SIMD FIR executed and reduced cycles");
        check(dtcm(0x38C0u) == dtcm(0x38C8u) &&
              dtcm(0x38C4u) == dtcm(0x38CCu), "scalar and SIMD FIR fingerprints match");
        check(dtcm(0x3C60u) == 3u && dtcm(0x3C70u) == dtcm(0x2830u), "steering query locked to SRP result");
        check((rd(R_STATUS) & ST_ERR) == 0u, "result readback has no AXI/TCM error");
        xil_printf("cycles: FFT scalar=%u hardware=%u FIR scalar=%u SIMD=%u\r\n",
                   (unsigned)fft_scalar, (unsigned)fft_hw, (unsigned)fir_scalar, (unsigned)fir_vec);
#ifdef ACOUSTIC_JITTER
        /* 逐帧抖动的结果由固件写在 FW_STEER_BASE（那个构建里 §9 没跑，8 个字空着）。
           只在 FW_JITTER_N > 0 的构建里有意义 —— measurements §16。 */
        xil_printf("jitter: min=%d max=%d sum=%d n=%d last=%d\r\n",
                   (int)dtcm(0x3C60u), (int)dtcm(0x3C64u), (int)dtcm(0x3C68u),
                   (int)dtcm(0x3C6Cu), (int)dtcm(0x3C70u));
#endif
    }
#ifdef ACOUSTIC_MEASURE_ONLY
    xil_printf("ACOUSTIC_MEASURE_DONE\r\n");
#else
    xil_printf("ACOUSTIC_RESULT_%s (%d failures)\r\n", failures == 0 ? "PASS" : "FAIL", failures);
#endif
    return failures;
}
