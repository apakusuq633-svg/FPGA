/*
 * A4.1 / A4.6  PS-side reference implementation of the bearing envelope-spectrum pipeline,
 * run on Cortex-A9 #1, checked term by term against MATLAB.
 *
 * Why this exists: bearing_synth_frame.m / bearing_synth_compare.m / bearing_leakage_check.m /
 * bearing_bpfo_sweep.m / bearing_pipeline_final.m developed the pipeline in MATLAB and settled
 * on a set of parameters. Nobody has yet shown that the same six steps can be written in C, on
 * the part that will actually run them, and produce the same numbers. Until that is shown the
 * MATLAB result is a plot, not a specification.
 *
 * The C here is a transcription of the pipeline() local function in bearing_pipeline_final.m,
 * not a reimplementation. Where the two look different it is only because MATLAB is 1-based and
 * C is 0-based, and every such place carries a comment saying so.
 *
 * -- The six steps, and where C is allowed to disagree with MATLAB ---------------------------
 *
 *   step  what                                        checkpoint  what it proves
 *   ----  ------------------------------------------  ----------  -------------------------
 *   1     X  = fft(x)                                   --        (no separate check)
 *   2     H  = one-sided x band-pass; xa = ifft(X.*H)   CP1 xa[0..7]
 *   3     env = |xa|                                    CP2 env[0..7]
 *   4     m = sum(env.*w)/sum(w); eac = env - m         CP3 m, eac[0..7]
 *   5     E = fft(eac.*w)/sum(w)                        CP4 E @ bins 4,8,12,16
 *   6     feat[k] = max|E| over k*BPFO +- 2 bins        CP5 feat[1..4]
 *
 * CP1 is the one that matters. If the twiddle table, the bit-reversal or the H mask were wrong,
 * CP1 is where it shows, and CP1 is one step away from the input -- not six. Every later
 * checkpoint being right then follows with nothing left to explain.
 *
 * -- The alignment tolerance is 1e-6 ABSOLUTE, and here is why it is not 1e-9 -----------------
 *
 * The input frame in frame_input.h is stored as float. MATLAB computed the expected values from
 * x as a double; C reads a float-rounded copy of the same x. That is 6e-8 of relative error
 * baked into the input before this file executes a single instruction, and it propagates:
 * worked through the FFT and the 69-bin mask it lands at about 3e-8 absolute at CP1..CP3 and
 * about 1e-9 at CP5. A 1e-9 tolerance would fail on the input format alone and say nothing
 * about the C.
 *
 * So the tolerance is 1e-6: roughly 30x above the error the input format makes unavoidable, and
 * about four orders BELOW any real bug. A wrong H mask, a transposed twiddle, an N vs N-1 in
 * the window or an off-by-one in the peak search all move the answer by 1e-2 or more. The
 * measured deviation is printed for every checkpoint, so the margin is visible rather than
 * assumed -- if the printed numbers sit near 3e-8 the alignment is exact and the 1e-6 is slack;
 * if they sit near 1e-6 something is wrong even though the check says [ok].
 *
 * Regenerating frame_input.h with write_f64 instead of write_f32 would remove the input-format
 * error entirely and let this drop to 1e-9. Not done yet, so that the input keeps the shape the
 * eventual capture front end will produce.
 *
 * -- No libm ---------------------------------------------------------------------------------
 *
 * The Vitis link line is -Wl,--start-group,-lxil,-lgcc,-lc,--end-group: there is no -lm, so
 * sin, cos, sqrt, fabs and log10 are all undefined symbols. xil_printf has no float support
 * either, which is why every double below is printed by a hand-written formatter. Depending on
 * libm would have meant a build-setting change on top of an algorithm that is already new, and
 * then two unknowns behind one failure.
 *
 * The replacements are not approximations in the loose sense: sin/cos is a Taylor series whose
 * first dropped term is below 1e-18 on the interval used, sqrt is the VFP's own VSQRT.F64 (IEEE
 * correctly rounded, one instruction), log10 is an atanh series good to 1e-17.
 * verify_twiddle_poly.m checks the first and third against MATLAB over every angle used here.
 *
 * Two other xil_printf facts this file had to be written around, both already learned the hard
 * way in ps_dualcore.c: it does not support width or padding modifiers (%-12s, %10u, %08x all
 * print garbage), and %f does not exist at all. Every column below is either unpadded or is a
 * hand-written formatter.
 *
 * -- What was read off the toolchain, not recalled -------------------------------------------
 *
 * | fact             | value                                              | where from |
 * |------------------|----------------------------------------------------|------------|
 * | build flags      | -O0 -g3 -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard | Debug/src/subdir.mk |
 * | link libraries   | -lxil -lgcc -lc, NO -lm                            | Debug/objects.mk |
 * | CPU1 release     | 0xFFFFFFF0 boot addr + sev                         | ps_dualcore.c, measured |
 * | global timer     | 0xF8F00200, ctl +0x08, lo +0x00                    | ps_dualcore.c, measured |
 * | tick rate        | core clock / 2 = 333,333,343 Hz                    | BSP, ps_dualcore.c |
 * | shared page      | 0xFFFF0000 (OCM), 32 KB free below CPU1's stack    | ps_dualcore.c |
 * | CPU1 stack       | 0xFFFF8000, growing down                           | ps_dualcore.c |
 *
 * -mfloat-abi=hard is the one that changes what this file measures. With the soft ABI every
 * double operation would be a libgcc call and the timings below would measure the ABI, not the
 * algorithm. Note that VFPv3 on Cortex-A9 is D16 -- 16 double registers and a 32-bit datapath --
 * so doubles run at roughly a third the rate of floats. Quantifying that is what the float swap
 * later in the plan is for.
 *
 * -- How to run it ---------------------------------------------------------------------------
 *
 * Vitis: right-click ps_dualcore.c -> Exclude from Build, drop ps_fft_test.c, frame_input.h and
 * frame_expect.h into src/, rebuild, run. Nothing here touches a board peripheral, so it runs on
 * the same bitstream ps_dualcore.c ran on.
 *
 * Convention: ASCII only in every string and comment, because a Vitis import reads UTF-8 as GBK
 * and writes it back mangled.
 */

#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_mmu.h"
#include "xil_cache_l.h"

/* -- Which test frame this build runs ------------------------------------------------------
 *
 * One number to flip. Both frames come out of the same generator (bearing_pipeline_final.m) and
 * drive the same code path; they differ only in BPFO, and that is the whole point of having two.
 *
 *   frame A   BPFO = 187.50 Hz = bin 4.00   integer bin -- the alignment reference
 *   frame B   BPFO = 103.56 Hz = bin 2.21   non-integer, near the 46.875 Hz resolution limit
 *
 * Test with `#if CASE_B`, NOT `#ifdef CASE_B`. CASE_B is defined either way -- its value is the
 * switch, and #ifdef would be true for both settings.
 *
 * The generator gives frame B its own macro and array prefixes (FRAME_B_*, exp_b_*) so the two
 * headers can coexist in one translation unit without redefinition. Rather than rename every use
 * site below, the block under CASE_B aliases frame B's names onto frame A's. Everything past this
 * point is written once and never knows which frame it is running. Frame A needs no aliases at
 * all, so CASE_B 0 compiles to exactly the bytes that were already verified on the board.
 */
/* 0 = frame A (187.50 Hz),  1 = frame B (103.56 Hz).
 * Overridable from the Vitis compiler symbols (-DCASE_B=0) so switching frames does not
 * need an edit here. Plain #define made the command line a redefinition error, which is
 * why scripts/check_ps_apps.py could only ever cover one of the two frames. */
#ifndef CASE_B
#define CASE_B  1
#endif

#if CASE_B
  #include "frame_b_input.h"
  #include "frame_b_expect.h"
  #define FRAME_N            FRAME_B_N
  #define FRAME_FS           FRAME_B_FS
  #define FRAME_BPFO         FRAME_B_BPFO
  #define FRAME_FRES         FRAME_B_FRES
  #define FRAME_BANDPASS_BW  FRAME_B_BANDPASS_BW
  #define EXP_N              EXP_B_N
  #define EXP_CBIN           EXP_B_CBIN
  #define EXP_HW             EXP_B_HW
  #define EXP_K              EXP_B_K
  #define frame_fault        frame_b_fault
  #define frame_heal         frame_b_heal
  #define exp_xa_re          exp_b_xa_re
  #define exp_xa_im          exp_b_xa_im
  #define exp_env_fault      exp_b_env_fault
  #define exp_env_heal       exp_b_env_heal
  #define exp_mean_w         exp_b_mean_w
  #define exp_eac_fault      exp_b_eac_fault
  #define exp_E_re           exp_b_E_re
  #define exp_E_im           exp_b_E_im
  #define exp_feat_fault     exp_b_feat_fault
  #define exp_feat_heal      exp_b_feat_heal
  #define exp_contrast_db    exp_b_contrast_db
  #define exp_E_mag_fault    exp_b_E_mag_fault
  #define exp_E_mag_heal     exp_b_E_mag_heal
  #define EXP_EBINS          EXP_B_EBINS
#else
  #include "frame_input.h"
  #include "frame_expect.h"
#endif

/* -- What the compiler decided, printed into the log -------------------------------------- */
#if defined(__ARM_PCS_VFP)
  #define FLOAT_ABI_STR  "hard (VFP registers really used)"
#else
  #define FLOAT_ABI_STR  "soft (doubles are libgcc calls; timings here are the ABI, not the DSP)"
#endif

/* -- Registers and memory ------------------------------------------------------------------ */
#define SLCR_UNLOCK_REG   0xF8000008u
#define SLCR_LOCK_REG     0xF8000004u
#define SLCR_UNLOCK_KEY   0xDF0Du
#define SLCR_LOCK_KEY     0x767Bu

#define A9_CPU_RST_CTRL   0xF8000244u
#define A9_RST1           (1u << 1)
#define A9_CLKSTOP1       (1u << 5)
#define CPU1_RELEASE_MASK (A9_RST1 | A9_CLKSTOP1)

#define CPU1_BOOT_ADDR    0xFFFFFFF0u

#define GTIMER_BASE       0xF8F00200u
#define GTIMER_CTL_OFF    0x08u
#define GTIMER_LO_OFF     0x00u
#define TICKS_PER_SEC     333333343u
#define POLL_STEP         (TICKS_PER_SEC / 40u)   /* exactly 25 ms */

/* The frame budget. 512 samples of hop at 48 kHz: at 50% overlap a new 1024-sample frame starts
 * every 512 samples, and the thing that must not happen is a frame being skipped. 10.667 ms is
 * the stricter of the two readings and the one the plan settled on. */
#define BUDGET_SEC        (512.0 / 48000.0)

/* The shared page. OCM, which the BSP maps cacheable by default; main() rewrites it to
 * non-cacheable before CPU1 exists, and that call is load-bearing (see ps_dualcore.c).
 *
 * Every double crosses this boundary as two 32-bit words. The page is non-cacheable, so a 64-bit
 * store would still be two bus transactions and CPU0 could read between them. It cannot, because
 * CPU1 writes every field before it writes STATE and only reads STATE after a dsb. */
#define SHARED_BASE       0xFFFF0000u
#define CPU1_STACK_TOP    0xFFFF8000u

#define SH_MAGIC          0    /* CPU1_MAGIC once CPU1 is past its own bring-up            */
#define SH_STATE          1    /* 1 = fault frame published, 2 = everything done           */
#define SH_CPU1_SCTLR     2
#define SH_CPU1_CPACR     3
#define SH_T_TOTAL        4    /* ticks, fault frame, all six steps                        */
#define SH_T_STAGE        5    /* 6 words: ticks for step 1..6 on the fault frame          */
#define SH_T_HEAL         11   /* ticks, heal frame, all six steps                         */
#define SH_T_REP          12   /* ticks, SH_REPS back-to-back fault pipelines              */
#define SH_REPS           13
#define SH_CBIN           14   /* double: k*BPFO in bins, as the code computed it          */
#define SH_XA_RE          16   /* CP1, double[8]                                           */
#define SH_XA_IM          32   /* CP1, double[8]                                           */
#define SH_ENV_F          48   /* CP2, double[8]                                           */
#define SH_ENV_H          64
#define SH_EAC_F          80   /* CP3, double[8]                                           */
#define SH_MEAN_W         96   /* CP3, double                                              */
#define SH_E_RE           98   /* CP4, double[4] at bins 4, 8, 12, 16                      */
#define SH_E_IM           106
#define SH_FEAT_F         114  /* CP5, double[4]                                           */
#define SH_FEAT_H         122
#define SH_ENV_F_MAX      130
#define SH_ENV_F_MEAN     132
#define SH_ENV_H_MAX      134
#define SH_ENV_H_MEAN     136
#define SH_ACC            138  /* folded over the repeat loop; proves it ran SH_REPS times  */
#define SH_HW             140  /* the peak-search half-width the code used, in bins        */
#define SH_EMAG_F         144  /* A4.2, double[EXP_EBINS]: |E| of the fault frame          */
#define SH_EMAG_H         (SH_EMAG_F + 2 * EXP_EBINS)
#define SH_WORDS          (SH_EMAG_H + 2 * EXP_EBINS)

#define CPU1_MAGIC        0xF0F0F0F0u

/* -- FFT ---------------------------------------------------------------------------------- */

#define FFT_N     1024

/* Where the envelope spectrum stops being interesting. The envelope of a signal band-limited to
 * [f_res - B/2, f_res + B/2] carries nothing above B/2, so bins past this one are noise. Integer
 * arithmetic on purpose -- this has to be usable in an #if. 3200/2 Hz at 46.875 Hz/bin is bin
 * 34.13, so E_USEFUL_BIN is 34 and the peak test also looks one bin further to get a right-hand
 * neighbour for bin 34. */
#define E_USEFUL_BIN  ((FRAME_BANDPASS_BW * FFT_N) / (2 * FRAME_FS))

/* The comparisons below index the expected arrays by hand, and the peak search is written for
 * exactly four harmonics. A regenerated header with a different N, K or frame length must fail
 * the build rather than quietly compare the wrong things. */
#if FRAME_N != FFT_N
#error "frame_input.h was generated for a different N than FFT_N"
#endif
#if EXP_N != FFT_N
#error "frame_expect.h was generated for a different N than FFT_N"
#endif
#if EXP_K != 4
#error "this file compares exactly 4 harmonics; regenerate with K=4 or extend the loops"
#endif

/* A4.2 exports the whole envelope spectrum and sizes both its array and its comparison loop from
 * EXP_EBINS -- the generator's number, not a second copy of it. These two bounds are what would
 * quietly go wrong if the generator were rerun with a different E_BINS: a curve that no longer
 * reaches the useful band, or one that runs off the end of the transform. */
#if EXP_EBINS > FFT_N / 2
#error "EXP_EBINS runs past the Nyquist bin"
#endif
#if EXP_EBINS < E_USEFUL_BIN + 2
#error "EXP_EBINS stops short of B/2; raise E_BINS in bearing_pipeline_final.m and regenerate"
#endif

/* Alignment tolerance. See the header block -- 1e-6 absolute, not 1e-9, and the reason is the
 * float storage format of the input frame, not the arithmetic here. */
#define ALIGN_TOL 1e-6

/* The contrast is a ratio of two numbers that each carry ~1e-8, so its own error floor is
 * 8.686 * (1e-8/0.14 + 1e-8/0.0086) ~ 1e-5 dB. 1e-3 dB is 100x that and still four orders below
 * any real defect. */
#define ALIGN_TOL_DB  1e-3

/* Repeat-loop length for the A4.6 throughput number: long enough that one timer tick of jitter
 * is under 1 part in 10^4, short enough to stay well inside CPU0's poll cap. */
#define REPS      20

/* The compiler barrier, the no-libm math, the FFT, the frame setup and the six-step pipeline
 * itself all live in sw/ps_env_pipeline.h rather than here: a pipeline checked against MATLAB
 * cannot exist in two copies, and that header is
 * expanded against the FFT_N / FRAME_FS / FRAME_FRES / FRAME_BANDPASS_BW / EXP_EBINS below, so
 * the include has to come after their definitions; bpfo is passed in at every call site. */
#include "ps_env_pipeline.h"

/* -- Shared-page helpers -------------------------------------------------------------------
 * CPU0 and CPU1 compile from this same file, so there is one implementation of the layout and
 * the two sides cannot disagree about it. */
static void sh_put_f64(volatile uint32_t *sh, int w, double v)
{
    union { double d; uint32_t u[2]; } x;
    x.d = v;
    sh[w]     = x.u[0];
    sh[w + 1] = x.u[1];
}

static double sh_get_f64(volatile uint32_t *sh, int w)
{
    union { double d; uint32_t u[2]; } x;
    x.u[0] = sh[w];
    x.u[1] = sh[w + 1];
    return x.d;
}

/* -- CPU1 side -----------------------------------------------------------------------------
 * Same bring-up as ps_dualcore.c, plus one thing that file did not need: the floating-point
 * unit. See fpu_enable().
 */

void cpu1_main(void);
void cpu1_prep(void);

__attribute__((naked, noinline))
void cpu1_entry(void)
{
    __asm__ __volatile__(
        "movw sp, #0x8000     \n"
        "movt sp, #0xFFFF     \n"
        "b    cpu1_prep       \n"
    );
}

/* The VFP is per-core, and CPU1 never runs the BSP's _boot -- it enters at cpu1_entry above. So
 * whatever CPU0 was given at boot, CPU1 has not got, and the first double instruction on CPU1
 * would trap as an undefined instruction. Doing it here for both cores removes the question
 * instead of reasoning about which boot path each one took.
 *
 *   CPACR (p15,0,c1,c0,2): bits 20-21 = CP10, bits 22-23 = CP11, both 0b11 for full access.
 *   FPEXC (p10,7,c8,c0,0): bit 30 = EN, gates the FPU itself.
 *   FPSCR (p10,7,c8,c1,0): 0 = round to nearest, no traps, flush-to-zero OFF. FTZ matters: with
 *                          it on, subnormal intermediates would be flushed to zero and the C
 *                          would diverge from MATLAB, which never flushes. */
static void fpu_enable(void)
{
    __asm__ __volatile__(
        "mrc  p15, 0, r0, c1, c0, 2  \n"
        "orr  r0, r0, #(0xF << 20)   \n"
        "mcr  p15, 0, r0, c1, c0, 2  \n"
        "isb                         \n"
        "movw r0, #0                 \n"
        "movt r0, #0x4000            \n"   /* 1 << 30 */
        "fmxr fpexc, r0              \n"
        "mov  r0, #0                 \n"
        "fmxr fpscr, r0              \n"
        ::: "r0", "memory"
    );
}

__attribute__((noreturn, noinline))
void cpu1_prep(void)
{
    Xil_L1DCacheInvalidate();
    Xil_L1ICacheInvalidate();

    __asm__ __volatile__(
        "mov  r0, #0                \n"
        "mcr  p15, 0, r0, c8, c7, 0 \n"
        "movw r0, #:lower16:_vector_table \n"
        "movt r0, #:upper16:_vector_table \n"
        "mcr  p15, 0, r0, c12, c0, 0\n"
        "movw r0, #:lower16:MMUTable      \n"
        "movt r0, #:upper16:MMUTable      \n"
        "orr  r0, r0, #0x5B         \n"
        "mcr  p15, 0, r0, c2, c0, 0 \n"
        "mvn  r0, #0                \n"
        "mcr  p15, 0, r0, c3, c0, 0 \n"
        "movw r0, #0x1005           \n"
        "mcr  p15, 0, r0, c1, c0, 0 \n"
        "dsb                        \n"
        "isb                        \n"
        "mrc  p15, 0, r0, c1, c0, 1 \n"
        "orr  r0, r0, #(1 << 6)     \n"
        "orr  r0, r0, #1            \n"
        "mcr  p15, 0, r0, c1, c0, 1 \n"
        ::: "r0", "memory"
    );

    fpu_enable();
    cpu1_main();
    __builtin_unreachable();
}

/* The frame this program runs on, widened from float once. It deliberately does not live in
 * ps_env_pipeline.h: that header holds the pipeline, and a frame belongs to whoever produced it
 * -- here a compiled-in vector, on the board whatever the capture front end handed over. */
static double g_x[FFT_N];

static void fill_frame(double *dst, const float *src, int n)
{
    for (int i = 0; i < n; i++) {
        dst[i] = (double)src[i];
    }
}

void cpu1_main(void)
{
    volatile uint32_t *sh = (volatile uint32_t *)SHARED_BASE;
    static struct caps cp;             /* static: 460 bytes, and CPU1's stack is 32 KB */
    static struct caps cph;
    double      feat_f[4], feat_h[4];
    double      acc = 0.0;
    uint32_t    sctlr, cpacr, t0, t1;
    int         i, n;

    n = FRAME_N;

    __asm__ __volatile__("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
    __asm__ __volatile__("mrc p15, 0, %0, c1, c0, 2" : "=r"(cpacr));
    sh[SH_CPU1_SCTLR] = sctlr;
    sh[SH_CPU1_CPACR] = cpacr;

    /* One-off setup, outside every timing below. The real system pays for this once at startup
     * too, so leaving it out of the frame budget is the honest accounting, not a free lunch. */
    twiddle_build(n);
    frame_setup(n, FRAME_FS);

    /* ---- fault frame, timed step by step -------------------------------------------- */
    fill_frame(g_x, frame_fault, n);

    GT_BARRIER();
    t0 = gtimer_now();
    pipeline_run(g_x, n, FRAME_BPFO, &cp, feat_f);
    t1 = gtimer_now();
    GT_BARRIER();
    cp.t_total = t1 - t0;

    for (i = 0; i < 6; i++) {
        sh[SH_T_STAGE + i] = cp.t_stage[i];
    }
    sh[SH_T_TOTAL] = cp.t_total;

    for (i = 0; i < 8; i++) {
        sh_put_f64(sh, SH_XA_RE + 2 * i, cp.xa_re[i]);
        sh_put_f64(sh, SH_XA_IM + 2 * i, cp.xa_im[i]);
        sh_put_f64(sh, SH_ENV_F + 2 * i, cp.env[i]);
        sh_put_f64(sh, SH_EAC_F + 2 * i, cp.eac[i]);
    }
    sh_put_f64(sh, SH_MEAN_W,     cp.mean_w);
    sh_put_f64(sh, SH_ENV_F_MAX,  cp.env_max);
    sh_put_f64(sh, SH_ENV_F_MEAN, cp.env_mean);

    /* cp.e_re/e_im are filled at bins (int)(cbin*(k+1)), which for this frame is 4, 8, 12, 16 --
     * the same bins exp_E_re/exp_E_im were taken at. CPU0 re-derives nothing here; it compares
     * against EXP_CBIN and EXP_HW separately, so if the two ever stopped lining up the CP4
     * comparison would fail loudly rather than compare the wrong bins. */
    for (i = 0; i < 4; i++) {
        sh_put_f64(sh, SH_E_RE   + 2 * i, cp.e_re[i]);
        sh_put_f64(sh, SH_E_IM   + 2 * i, cp.e_im[i]);
        sh_put_f64(sh, SH_FEAT_F + 2 * i, feat_f[i]);
    }
    sh_put_f64(sh, SH_CBIN, cp.cbin);
    sh[SH_HW] = (uint32_t)cp.hw;

    /* A4.2: the whole envelope spectrum of the fault frame. Published before STATE, like every
     * other field, so CPU0 cannot read a half-written curve. */
    for (i = 0; i < EXP_EBINS; i++) {
        sh_put_f64(sh, SH_EMAG_F + 2 * i, cp.e_mag[i]);
    }

    __asm__ __volatile__("dsb" ::: "memory");
    sh[SH_STATE] = 1u;

    /* ---- heal frame: same background and same noise, no impulses ---------------------
     * Only env[0..7] and feat are wanted. Timing it whole is still worth doing -- the frames are
     * the same length, so a large difference would mean the pipeline depends on the data, which
     * it should not. */
    fill_frame(g_x, frame_heal, n);
    GT_BARRIER();
    t0 = gtimer_now();
    pipeline_run(g_x, n, FRAME_BPFO, &cph, feat_h);
    t1 = gtimer_now();
    GT_BARRIER();
    sh[SH_T_HEAL] = t1 - t0;

    for (i = 0; i < 8; i++) {
        sh_put_f64(sh, SH_ENV_H + 2 * i, cph.env[i]);
    }
    sh_put_f64(sh, SH_ENV_H_MAX,  cph.env_max);
    sh_put_f64(sh, SH_ENV_H_MEAN, cph.env_mean);
    for (i = 0; i < 4; i++) {
        sh_put_f64(sh, SH_FEAT_H + 2 * i, feat_h[i]);
    }
    for (i = 0; i < EXP_EBINS; i++) {
        sh_put_f64(sh, SH_EMAG_H + 2 * i, cph.e_mag[i]);
    }

    /* ---- repeat loop: the A4.6 number ------------------------------------------------
     * The accumulator is the point. Without a value that depends on every iteration an optimiser
     * is free to keep one call and delete nineteen; acc is published and CPU0 checks it against
     * REPS * feat_f[0], so a deleted iteration shows up as a wrong number instead of as a
     * suspiciously good timing. */
    fill_frame(g_x, frame_fault, n);
    GT_BARRIER();
    t0 = gtimer_now();
    for (i = 0; i < REPS; i++) {
        pipeline_run(g_x, n, FRAME_BPFO, (struct caps *)0, feat_f);
        acc += feat_f[0];
    }
    t1 = gtimer_now();
    GT_BARRIER();
    sh[SH_T_REP] = t1 - t0;
    sh[SH_REPS]  = REPS;
    sh_put_f64(sh, SH_ACC, acc);

    __asm__ __volatile__("dsb" ::: "memory");
    sh[SH_MAGIC] = CPU1_MAGIC;
    sh[SH_STATE] = 2u;
    __asm__ __volatile__("dsb" ::: "memory");

    for (;;) {
        /* spin */
    }
}

/* -- CPU0 side --------------------------------------------------------------------------- */

extern uint32_t MMUTable;

static int failures = 0;
static int checks   = 0;

static uint32_t mpidr(void)
{
    uint32_t v;
    __asm__ __volatile__("mrc p15,0,%0,c0,c0,5" : "=r"(v));
    return v & 0xFu;
}

static uint32_t tlb_entry(uint32_t addr)
{
    return Xil_In32((INTPTR)&MMUTable + ((addr >> 20) & 0xFFFu) * 4u);
}

static uint32_t gtimer_now(void)
{
    return Xil_In32(GTIMER_BASE + GTIMER_LO_OFF);
}

static void wait_ticks(uint32_t ticks)
{
    uint32_t t0 = gtimer_now();
    while ((uint32_t)(gtimer_now() - t0) < ticks) {
        /* spin */
    }
}

/* print_hex32 / print_f64 live in sw/ps_report.h: xil_printf has neither %f nor width
 * modifiers, so these hand-written formatters are the only way a double reaches the console. */
#include "ps_report.h"

/* Display-only companion to print_f64, for the A4.2 spectrum tables. eps sits in the numerator as
 * well so a bin where both frames are essentially zero reads as 0 dB instead of -inf; d_log10
 * returns 0.0 for a non-positive argument, which would otherwise look like a real reading. The
 * number that decides anything is CP5's contrast, and that is computed from the doubles. */
static double band_db(double ef, double eh)
{
    static const double EPS = 2.2204460492503131e-16;
    return 20.0 * d_log10((ef + EPS) / (eh + EPS));
}

static void check(int cond, const char *what)
{
    checks++;
    if (cond) {
        xil_printf("  [ok]   %s\r\n", what);
    } else {
        xil_printf("  [FAIL] %s\r\n", what);
        failures++;
    }
}

/* One checkpoint. Prints the worst deviation whether it passes or fails, because the margin is
 * the interesting number: a pass at 3e-8 and a pass at 9e-7 mean very different things, and only
 * the second is worth investigating. On failure it also prints the offending index and both
 * values, which is enough to tell a wrong mask from a wrong window without a second run.
 *
 * `acc` is which running maximum this checkpoint feeds. It has to be two separate accumulators,
 * not one: ALIGN_TOL covers linear quantities (~1e-8 here) and ALIGN_TOL_DB covers a dB quantity
 * (~1e-6 here), and taking a max across both units reports the dB item as the headline every
 * time. Measured on both frames: CP5's contrast in dB came out at 1.567e-6 / 2.491e-6 while the
 * real largest linear deviation was 1.097e-8 / 1.010e-8 -- 143x / 246x smaller. Quoting the
 * headline as "worst deviation" was therefore wrong by two orders of magnitude. This is a
 * reporting bug only: each call below still compares against its own tol, so no pass/fail
 * decision changes. */
static double worst_dev_lin = 0.0;   /* ALIGN_TOL    bucket -- the number the report should quote */
static double worst_dev_db  = 0.0;   /* ALIGN_TOL_DB bucket -- dB, kept separate on purpose */

static void cp_check(const char *name, const double *got, const double *want, int n,
                     double tol, double *acc)
{
    double worst = 0.0;
    int    wi = -1, i;

    for (i = 0; i < n; i++) {
        double d = d_abs(got[i] - want[i]);
        if (d > worst) {
            worst = d;
            wi = i;
        }
    }
    if (worst > *acc) {
        *acc = worst;
    }

    checks++;
    if (worst <= tol) {
        xil_printf("  [ok]   ");
        xil_printf("%s", name);
        xil_printf("  max|diff| = ");
        print_f64(worst);
        xil_printf("\r\n");
    } else {
        xil_printf("  [FAIL] ");
        xil_printf("%s", name);
        xil_printf("  max|diff| = ");
        print_f64(worst);
        xil_printf("  at element %d\r\n", wi);
        xil_printf("           C      = ");
        print_f64(got[wi]);
        xil_printf("\r\n           MATLAB = ");
        print_f64(want[wi]);
        xil_printf("\r\n");
        failures++;
    }
}

static void sh_read_f64(volatile uint32_t *sh, int w, double *dst, int n)
{
    for (int i = 0; i < n; i++) {
        dst[i] = sh_get_f64(sh, w + 2 * i);
    }
}

int main(void)
{
    volatile uint32_t *sh = (volatile uint32_t *)SHARED_BASE;
    static double got[16];
    static double egot[EXP_EBINS];
    uint32_t tctl, rst_before, rst_after, state = 0u, magic = 0u;
    int      i, seen = 0;

    xil_printf("\r\n===== A4.1  envelope-spectrum pipeline: C on A9#1 vs MATLAB =====\r\n");
    xil_printf("running on core #%d\r\n", (int)mpidr());
    xil_printf("float ABI : ");
    xil_printf("%s\r\n", FLOAT_ABI_STR);
    xil_printf("N = %d, fs = %d Hz, df = 46.875 Hz, frame = 21.333 ms\r\n", FRAME_N, FRAME_FS);
    /* xil_printf has no %f, so this one line would render as "BPFO =  Hz  band = 10..0 Hz": the
     * double argument gets read as two 32-bit words and every %d after it picks up half of it.
     * The fractional digit is assembled as a second integer instead. */
    xil_printf("BPFO = %d.%03d Hz  band = %d..%d Hz\r\n",
               (int)FRAME_BPFO,
               (int)((FRAME_BPFO - (double)(int)FRAME_BPFO) * 1000.0),
               (int)(FRAME_FRES - FRAME_BANDPASS_BW / 2),
               (int)(FRAME_FRES + FRAME_BANDPASS_BW / 2));
    xil_printf("tolerance = 1e-6 absolute (file header explains why not 1e-9)\r\n\r\n");

    /* 0. Global timer. Nothing else in a bare-metal BSP enables it. */
    tctl = Xil_In32(GTIMER_BASE + GTIMER_CTL_OFF);
    Xil_Out32(GTIMER_BASE + GTIMER_CTL_OFF, tctl | 1u);
    tctl = Xil_In32(GTIMER_BASE + GTIMER_CTL_OFF);
    xil_printf("[0] global timer ctl = 0x");
    print_hex32(tctl);
    xil_printf("  (bit0 = enable)\r\n");

    /* 1. Make the shared page non-cacheable. Without this CPU0 serves its own stale copies and
     *    never sees a single value CPU1 published. */
    xil_printf("[1] shared page 0x");
    print_hex32(SHARED_BASE);
    xil_printf(" entry 0x");
    print_hex32(tlb_entry(SHARED_BASE));
    Xil_SetTlbAttributes((INTPTR)SHARED_BASE, NORM_NONCACHE);
    xil_printf(" -> 0x");
    print_hex32(tlb_entry(SHARED_BASE));
    xil_printf("\r\n");
    check(tlb_entry(SHARED_BASE) == ((SHARED_BASE & 0xFFF00000u) | NORM_NONCACHE),
          "the shared page's translation table entry is non-cacheable");

    for (i = 0; i < SH_WORDS; i++) {
        sh[i] = 0u;
    }
    sh[SH_MAGIC] = 0xAAAAAAAAu;
    check(sh[SH_MAGIC] == 0xAAAAAAAAu, "CPU0 can write and read back the shared page");
    sh[SH_MAGIC] = 0u;

    /* 2. Release CPU1. */
    xil_printf("\r\n[2] releasing CPU1, entry = cpu1_entry\r\n");
    rst_before = Xil_In32(A9_CPU_RST_CTRL);
    Xil_Out32(SLCR_UNLOCK_REG, SLCR_UNLOCK_KEY);
    Xil_Out32(CPU1_BOOT_ADDR, (uint32_t)cpu1_entry);
    __asm__ __volatile__("dsb" ::: "memory");
    __asm__ __volatile__("sev");
    Xil_Out32(A9_CPU_RST_CTRL, rst_before & ~CPU1_RELEASE_MASK);
    Xil_Out32(SLCR_LOCK_REG, SLCR_LOCK_KEY);
    rst_after = Xil_In32(A9_CPU_RST_CTRL);
    xil_printf("    A9_CPU_RST_CTRL = 0x");
    print_hex32(rst_after);
    xil_printf("\r\n");
    check((rst_after & CPU1_RELEASE_MASK) == 0, "CPU1 reset and clock-stop bits are cleared");

    /* 3. Poll. The cap matters: if CPU1 never reaches STATE 2 the run still ends and the checks
     *    below report what actually happened, which is worth more than a silent hang. */
    xil_printf("\r\n[3] waiting for CPU1 (poll every %u ticks)\r\n", POLL_STEP);
    for (i = 0; i < 200; i++) {
        magic = sh[SH_MAGIC];
        if (magic == CPU1_MAGIC) {
            seen = 1;
        }
        state = sh[SH_STATE];
        if (state >= 2u) {
            break;
        }
        xil_printf("    round %d  magic 0x", i);
        print_hex32(magic);
        xil_printf("  state %u\r\n", state);
        wait_ticks(POLL_STEP);
    }

    if (state < 2u) {
        xil_printf("\r\nCPU1 did not finish. Stopping rather than comparing partial data.\r\n");
        check(0, "CPU1 reached STATE 2");
        xil_printf("\r\n===== FAIL (%d failures) =====\r\n", failures);
        return failures;
    }

    xil_printf("[4] CPU1 done, %d rounds of polling\r\n", i);
    xil_printf("    CPU1 SCTLR = 0x");
    print_hex32(sh[SH_CPU1_SCTLR]);
    xil_printf("  (want bits 0x1005 = MMU | D$ | I$)\r\n");
    xil_printf("    CPU1 CPACR = 0x");
    print_hex32(sh[SH_CPU1_CPACR]);
    xil_printf("  (want bits 0x00F00000 = CP10/CP11 full access)\r\n");

    /* -- the checkpoints --------------------------------------------------------------- */
    xil_printf("\r\n[5] checkpoints -- C on A9#1 vs MATLAB double, tol 1e-6\r\n");

    sh_read_f64(sh, SH_XA_RE, got, 8);
    cp_check("CP1 real  xa[0..7]", got, exp_xa_re, 8, ALIGN_TOL,    &worst_dev_lin);
    sh_read_f64(sh, SH_XA_IM, got, 8);
    cp_check("CP1 imag  xa[0..7]", got, exp_xa_im, 8, ALIGN_TOL,    &worst_dev_lin);

    sh_read_f64(sh, SH_ENV_F, got, 8);
    cp_check("CP2 env fault     ", got, exp_env_fault, 8, ALIGN_TOL,    &worst_dev_lin);
    sh_read_f64(sh, SH_ENV_H, got, 8);
    cp_check("CP2 env heal      ", got, exp_env_heal, 8, ALIGN_TOL,    &worst_dev_lin);

    sh_read_f64(sh, SH_EAC_F, got, 8);
    cp_check("CP3 eac[0..7]      ", got, exp_eac_fault, 8, ALIGN_TOL,    &worst_dev_lin);

    got[0] = sh_get_f64(sh, SH_MEAN_W);
    cp_check("CP3 mean m         ", got, &exp_mean_w, 1, ALIGN_TOL,    &worst_dev_lin);

    sh_read_f64(sh, SH_E_RE, got, 4);
    cp_check("CP4 E real         ", got, exp_E_re, 4, ALIGN_TOL,    &worst_dev_lin);
    sh_read_f64(sh, SH_E_IM, got, 4);
    cp_check("CP4 E imag         ", got, exp_E_im, 4, ALIGN_TOL,    &worst_dev_lin);

    sh_read_f64(sh, SH_FEAT_F, got, 4);
    cp_check("CP5 feat fault     ", got, exp_feat_fault, 4, ALIGN_TOL,    &worst_dev_lin);
    sh_read_f64(sh, SH_FEAT_H, got, 4);
    cp_check("CP5 feat heal      ", got, exp_feat_heal, 4, ALIGN_TOL,    &worst_dev_lin);

    {
        double cf[4], chh[4], cgot[4];
        sh_read_f64(sh, SH_FEAT_F, cf, 4);
        sh_read_f64(sh, SH_FEAT_H, chh, 4);
        for (i = 0; i < 4; i++) {
            cgot[i] = 20.0 * d_log10(cf[i] / chh[i]);
        }
        cp_check("CP5 contrast dB    ", cgot, exp_contrast_db, 4, ALIGN_TOL_DB, &worst_dev_db);
    }

    /* A4.2: the whole envelope spectrum, not just the four bins CP4 sampled. CP1-CP5 all look at
     * a handful of indices, and a window or a normalisation that is wrong everywhere except at
     * k*BPFO would still pass them; this is the check that would catch it. Same 1e-6. */
    xil_printf("  .... A4.2 whole envelope spectrum, %d bins of each frame\r\n", EXP_EBINS);
    sh_read_f64(sh, SH_EMAG_F, egot, EXP_EBINS);
    cp_check("CP6 |E| whole fault", egot, exp_E_mag_fault, EXP_EBINS, ALIGN_TOL,    &worst_dev_lin);
    sh_read_f64(sh, SH_EMAG_H, egot, EXP_EBINS);
    cp_check("CP6 |E| whole heal ", egot, exp_E_mag_heal, EXP_EBINS, ALIGN_TOL,    &worst_dev_lin);

    /* CP4 was taken at bins (int)(cbin*(k+1)); exp_E_re/exp_E_im were taken at MATLAB's
     * k*BPFO/df. Those are the same four bins only because cbin and the two formulas agree, so
     * that is checked rather than assumed. */
    {
        double cbin_c = sh_get_f64(sh, SH_CBIN);
        double cbin_m = EXP_CBIN;
        int    hw_c   = (int)sh[SH_HW];
        xil_printf("\r\n[6] peak-search parameters\r\n");
        xil_printf("    cbin  C = "); print_f64(cbin_c);
        xil_printf("   MATLAB = ");   print_f64(cbin_m);
        xil_printf("   (bin index, so CP4's four bins are %d %d %d %d)\r\n",
                   (int)cbin_c, (int)(cbin_c*2), (int)(cbin_c*3), (int)(cbin_c*4));
        check(d_abs(cbin_c - cbin_m) < 1e-12, "the code's cbin equals MATLAB's EXP_CBIN");
        check(hw_c == EXP_HW, "the code's peak-search half-width equals MATLAB's EXP_HW");
    }

    /* The envelope max and mean are not in frame_expect.h, so they are checked against the
     * property that matters instead: for a rectified band-passed signal the mean must sit below
     * the max, and the fault frame's max must exceed the healthy frame's -- the impulses are the
     * only difference between the two. */
    {
        double e_fmax  = sh_get_f64(sh, SH_ENV_F_MAX);
        double e_fmean = sh_get_f64(sh, SH_ENV_F_MEAN);
        double e_hmax  = sh_get_f64(sh, SH_ENV_H_MAX);
        double e_hmean = sh_get_f64(sh, SH_ENV_H_MEAN);
        xil_printf("\r\n[7] envelope shape\r\n");
        xil_printf("    fault   max "); print_f64(e_fmax);
        xil_printf("   mean ");        print_f64(e_fmean);
        xil_printf("\r\n    healthy max "); print_f64(e_hmax);
        xil_printf("   mean ");        print_f64(e_hmean);
        xil_printf("\r\n");
        check(e_fmean < e_fmax && e_hmean < e_hmax, "each envelope's mean sits below its max");
        check(e_fmax > e_hmax, "the fault envelope peaks higher than the healthy one");
    }

    /* -- the feature table ------------------------------------------------------------- */
    {
        double cf[4], chh[4];
        sh_read_f64(sh, SH_FEAT_F, cf, 4);
        sh_read_f64(sh, SH_FEAT_H, chh, 4);

        xil_printf("\r\n[8] feature table  (col order: k, freq Hz, C feat_f, MATLAB, C feat_h, MATLAB, C dB, MATLAB dB)\r\n");
        xil_printf("    ");
        for (i = 0; i < 4; i++) {
            xil_printf("%d  ", i + 1);
            print_f64((double)(i + 1) * FRAME_BPFO);
            xil_printf("  ");
            print_f64(cf[i]);
            xil_printf("  ");
            print_f64(exp_feat_fault[i]);
            xil_printf("  ");
            print_f64(chh[i]);
            xil_printf("  ");
            print_f64(exp_feat_heal[i]);
            xil_printf("  ");
            print_f64(20.0 * d_log10(cf[i] / chh[i]));
            xil_printf("  ");
            print_f64(exp_contrast_db[i]);
            xil_printf("\r\n    ");
        }
    }

    /* -- A4.6: where the time goes ----------------------------------------------------- */
    {
        static const char *stage_name[6] = {
            "1 fft(x)", "2 mask+ifft", "3 |xa|", "4 win+mean", "5 fft(eac.w)", "6 peaks"
        };
        uint32_t tot  = sh[SH_T_TOTAL];
        uint32_t rep  = sh[SH_T_REP];
        uint32_t reps = sh[SH_REPS];
        double   budget_ticks = (double)TICKS_PER_SEC * BUDGET_SEC;
        int      worst_stage = 0;
        uint32_t worst_t = 0;

        xil_printf("\r\n[9] A4.6 timing -- A9#1, one %d-sample frame, %d Hz, doubles\n",
                   FRAME_N, FRAME_FS);
        for (i = 0; i < 6; i++) {
            uint32_t t = sh[SH_T_STAGE + i];
            xil_printf("    step ");
            xil_printf("%s", stage_name[i]);
            xil_printf("  %u ticks", t);
            if (tot > 0u) {
                xil_printf("  (%d%% of the frame)", (int)(100.0 * (double)t / (double)tot));
            }
            xil_printf("\r\n");
            if (t > worst_t) { worst_t = t; worst_stage = i; }
        }
        xil_printf("    total          %u ticks = ", tot);
        print_f64((double)tot / (double)TICKS_PER_SEC * 1000.0);
        xil_printf(" ms\r\n");
        xil_printf("    heal frame     %u ticks (same length, same noise, no impulses)\r\n",
                   sh[SH_T_HEAL]);
        xil_printf("    budget         ");
        print_f64(budget_ticks);
        xil_printf(" ticks = 10.667 ms (512/48000)\r\n");
        xil_printf("    budget used    ");
        print_f64(100.0 * (double)tot / budget_ticks);
        xil_printf(" %%\r\n");

        if (reps > 0u) {
            xil_printf("    back to back   %u ticks / %u reps = ", rep, reps);
            print_f64((double)rep / (double)reps);
            xil_printf(" ticks/frame\r\n");
        }
        xil_printf("    dominant step  ");
        xil_printf("%s", stage_name[worst_stage]);
        xil_printf("\r\n");

        check((double)tot < budget_ticks,
              "one frame fits inside the 10.667 ms budget (A4.6)");
    }

    /* -- the repeat loop actually ran -------------------------------------------------- */
    {
        double cf[4];
        double acc_want;
        sh_read_f64(sh, SH_FEAT_F, cf, 4);
        acc_want = (double)sh[SH_REPS] * cf[0];
        xil_printf("\r\n[10] repeat loop\r\n    accumulated ");
        print_f64(sh_get_f64(sh, SH_ACC));
        xil_printf("   expected ");
        print_f64(acc_want);
        xil_printf("\r\n");
        check(d_abs(sh_get_f64(sh, SH_ACC) - acc_want) < 1e-6 * (double)sh[SH_REPS],
              "the repeat loop ran every iteration (accumulator matches)");
    }

    /* -- A4.2: the envelope spectrum itself -------------------------------------------- */
    {
        static double ef[EXP_EBINS], eh[EXP_EBINS];
        double cbin_c = sh_get_f64(sh, SH_CBIN);
        double df     = (double)FRAME_FS / (double)FFT_N;
        int    hm;

        sh_read_f64(sh, SH_EMAG_F, ef, EXP_EBINS);
        sh_read_f64(sh, SH_EMAG_H, eh, EXP_EBINS);

        xil_printf("\r\n[11] A4.2 envelope spectrum |E|, bins 0..%d\r\n", EXP_EBINS - 1);
        xil_printf("     useful band ends at bin %d (B/2 = %d Hz); past that it is noise\r\n",
                   E_USEFUL_BIN, FRAME_BANDPASS_BW / 2);
        xil_printf("     MATLAB's copy is not reprinted here -- CP6 compares all %d bins\r\n",
                   EXP_EBINS);
        xil_printf("      bin      Hz       |E| fault      |E| heal        dB\r\n");
        for (i = 0; i < EXP_EBINS; i++) {
            hm = (int)((double)i * df * 1000.0 + 0.5);   /* Hz in milli-hertz, rounded */
            xil_printf("     %4d  %5d.%03d  ", i, hm / 1000, hm % 1000);
            print_f64(ef[i]);
            xil_printf("  ");
            print_f64(eh[i]);
            xil_printf("  ");
            print_f64(band_db(ef[i], eh[i]));
            xil_printf("\r\n");
        }

        /* The summary table. k != 0 marks one of the four bins CP5 actually uses, listed again
         * underneath; k = 0 means the peak is somewhere else. That distinction is the whole
         * point of the table, because on frame B it collapses: BPFO is 2.21 bins, so k=2..4 fall
         * on the falling skirt of k=1 and are not local maxima anywhere. A reader who takes this
         * table as "the harmonics" would conclude frame B has one and not four. It has four --
         * table [11] shows all four at bins 2, 4, 6 and 8, decaying smoothly. df simply cannot
         * separate them, which is the thing frame B exists to demonstrate. */
        xil_printf("\r\n[12] A4.2 local maxima of the fault |E|, bins 1..%d\r\n", E_USEFUL_BIN);
        xil_printf("     k marks one of the four bins CP5 uses; k = 0 is a peak somewhere else.\r\n");
        xil_printf("     A harmonic absent here is one df did not resolve, not one not present --\r\n");
        xil_printf("     read its value out of table [11] at its own bin number.\r\n");
        xil_printf("      bin      Hz       |E| fault      |E| heal        dB    k\r\n");
        for (i = 1; i <= E_USEFUL_BIN; i++) {
            if (ef[i] > ef[i - 1] && ef[i] >= ef[i + 1]) {
                int k, mark = 0;
                for (k = 1; k <= 4; k++) {
                    if ((int)(cbin_c * (double)k) == i) {
                        mark = k;
                    }
                }
                hm = (int)((double)i * df * 1000.0 + 0.5);
                xil_printf("     %4d  %5d.%03d  ", i, hm / 1000, hm % 1000);
                print_f64(ef[i]);
                xil_printf("  ");
                print_f64(eh[i]);
                xil_printf("  ");
                print_f64(band_db(ef[i], eh[i]));
                xil_printf("    %d\r\n", mark);
            }
        }
        /* Where each CP5 search actually landed. feat[k] is the max over the window, not the
         * value at k*BPFO, and those two coincide on frame A and diverge on frame B. With BPFO
         * at 2.21 bins and hw = 1, the window around floor(k*cbin) reaches back onto the falling
         * skirt of the previous harmonic, and the max of a monotonically falling skirt is always
         * its lowest bin -- so k=2..4 land one bin below their own harmonic every time. Frame B's
         * k=2..4 are therefore measuring leakage from lower orders, not order k. The separation
         * between the two frames is still >23 dB, so the detector is unaffected; what changes is
         * what the number is allowed to be called. */
        xil_printf("     where each CP5 search landed (feat[k] is the window max, not k*BPFO):\r\n");
        for (i = 1; i <= 4; i++) {
            int    b  = (int)(cbin_c * (double)i);
            int    lo = b - EXP_HW;
            int    hi = b + EXP_HW;
            int    am = lo;
            int    j;
            double mx = -1.0;

            if (lo < 0) { lo = 0; }
            if (hi > E_USEFUL_BIN) { hi = E_USEFUL_BIN; }
            for (j = lo; j <= hi; j++) {
                if (ef[j] > mx) {
                    mx = ef[j];
                    am = j;
                }
            }
            xil_printf("      k=%d  bin %d +-%d  ->  peak at bin %d", i, b, EXP_HW, am);
            xil_printf("   (bin %d itself = ", b);
            print_f64(ef[b]);
            xil_printf(")  %s\r\n", (am == b) ? "on the harmonic"
                                              : "OFF the harmonic bin");
        }
    }

    check(seen, "CPU1 wrote the magic value");
    check(mpidr() == 0, "this core is CPU0 (MPIDR says so)");

    xil_printf("\r\n===== summary =====\r\n");
    /* Two lines, one per unit -- see the comment on worst_dev_lin. The first is the number to
     * quote as the alignment margin; the second is a dB quantity and cannot be compared with it.
     * The shared prefix is deliberate: a script scraping this block still finds one place per
     * unit, with the unit spelled out in the label rather than left to the reader. */
    xil_printf("  worst deviation, linear (every checkpoint) = ");
    print_f64(worst_dev_lin);
    xil_printf("\r\n  worst deviation, dB (CP5 contrast only)    = ");
    print_f64(worst_dev_db);
    xil_printf("\r\n  checks %d, failures %d\r\n", checks, failures);

    xil_printf("\r\n===== %s (%d failures) =====\r\n",
               failures == 0 ? "PASS" : "FAIL", failures);
    return failures;
}
