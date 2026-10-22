/* The six-step envelope-spectrum pipeline, used by the PS-side FFT app (sw/ps_fft_test.c).
 *
 * The source of truth was already in this repo: the implementation in sw/ps_fft_test.c that was
 * checked term by term against MATLAB (CP1-CP6). This is not a rewrite of it, it is that code
 * moved out verbatim into a header, so the app and anything else that later needs the same
 * pipeline run identical instructions. A second copy
 * would leave the MATLAB-checked one without authority over anything -- and "this code computes
 * the right thing" is the only value it has.
 *
 * The includer must define, before this file:
 *   FFT_N                         transform length, which is also the frame length
 *   FRAME_FS                      sample rate in Hz. A double: the board's is 39062.5
 *   FRAME_FRES, FRAME_BANDPASS_BW resonance centre and band-pass width (mechanical, not
 *                                 board-specific)
 *   EXP_EBINS                     length of struct caps' e_mag[]
 * and must provide static uint32_t gtimer_now(void) -- the Cortex-A9 global timer, which is
 * hardware, not algorithm.
 *
 * Only FFT_N is needed from that list if the includer defines PS_ENV_PIPELINE_MATH_ONLY, which
 * takes the math core alone (no frame_setup, no pipeline_run, no working buffers, no
 * gtimer_now) -- the other macros are read only by the station 9 layer, which that switch drops.
 * sw/ps_features.h is the one user of that mode; see also the block above the station 9 layer.
 *
 * The order being looked for (bpfo) is a parameter for the same reason fs is: offline it is the
 * study's constant, on the board it is the shaft rate the tacho measured times the order of
 * interest. The one number that must differ between those two runs is exactly the one number
 * the code cannot be told.
 *
 * Deliberately not here:
 *   - the input frame buffer: whoever acquires the frame owns it (ps_fft_test.c keeps its g_x).
 *   - libm: the Vitis link line has no -lm, so sin/cos/sqrt/log10 are all written out below
 */

#ifndef PS_ENV_PIPELINE_H
#define PS_ENV_PIPELINE_H

#include <stdint.h>

/* Compiler barrier around a timer read. The reads themselves are volatile, which orders them
 * against each other; this stops the surrounding arithmetic from being moved across them. */
#define GT_BARRIER()  __asm__ __volatile__("" ::: "memory")

/* -- No-libm math -------------------------------------------------------------------------- */

/* sin(x)/x and cos(x) as Taylor series, highest power first for Horner.
 *
 * Evaluated only on |x| <= pi/4, where the first dropped terms are x^19/19! = 6.2e-20 and
 * x^20/20! = 3.1e-21. Ten Horner steps then round to within a few ulp -- checked against MATLAB
 * over all 512 twiddle angles and all 1024 window angles. */
static const double CS[9] = {
     2.8114572543455206e-15,   /*  1/17! */
    -7.6471637318198164e-13,   /* -1/15! */
     1.6059043836821613e-10,   /*  1/13! */
    -2.5052108385441720e-08,   /* -1/11! */
     2.7557319223985893e-06,   /*   1/9! */
    -1.9841269841269841e-04,   /*  -1/7! */
     8.3333333333333332e-03,   /*   1/5! */
    -1.6666666666666666e-01,   /*  -1/3! */
     1.0
};

static const double CC[10] = {
    -1.5619206968586225e-16,   /* -1/18! */
     4.7794773323873853e-14,   /*  1/16! */
    -1.1470745597729725e-11,   /* -1/14! */
     2.0876756987868100e-09,   /*  1/12! */
    -2.7557319223985888e-07,   /* -1/10! */
     2.4801587301587302e-05,   /*   1/8! */
    -1.3888888888888889e-03,   /*  -1/6! */
     4.1666666666666664e-02,   /*   1/4! */
    -0.5,                      /*  -1/2! */
     1.0
};

/* sin(th) and cos(th) for any th, without libm.
 *
 * Reduce to a multiple of pi/2 plus a remainder in [-pi/4, pi/4]. The rotation by q*(pi/2) is
 * then exact -- a sign flip and a swap, no sqrt(2) anywhere -- and only the remainder reaches
 * the polynomial.
 *
 * pi/2 is split into a high and a low part for the subtraction. th - q*PI2_HI is exact by
 * Sterbenz whenever th is within a factor of two of q*PI2_HI, which it is by construction of q;
 * subtracting the low part afterwards restores the bits PI2_HI's own rounding dropped. A
 * one-part reduction would cost ~1e-15 in the remainder, which is several ulp -- still far below
 * the tolerance, but this costs one extra multiply.
 *
 * |th| is under 2*pi for every caller (twiddles stop at pi, the window stops just under 2*pi),
 * so q stays at 4 or below and the split does not need a third part. */
__attribute__((noinline, optimize("O2")))
static void d_sincos(double th, double *ps, double *pc)
{
    static const double PI2_HI = 1.5707963267948966;       /* pi/2, as a double   */
    static const double PI2_LO = 6.1232339957367660e-17;   /* pi/2 - PI2_HI       */

    long   q;
    double r, x2, s, c;
    int    m, i;

    q = (long)(th / PI2_HI + (th >= 0.0 ? 0.5 : -0.5));
    r = (th - (double)q * PI2_HI) - (double)q * PI2_LO;

    x2 = r * r;

    s = CS[0];
    for (i = 1; i < 9; i++) {
        s = s * x2 + CS[i];
    }
    s = s * r;

    c = CC[0];
    for (i = 1; i < 10; i++) {
        c = c * x2 + CC[i];
    }

    m = (int)(q & 3L);
    switch (m) {
    case 0:  *ps =  s;  *pc =  c;  break;
    case 1:  *ps =  c;  *pc = -s;  break;
    case 2:  *ps = -s;  *pc = -c;  break;
    default: *ps = -c;  *pc =  s;  break;
    }
}

/* sqrt without libm: one VFP instruction, and ARM's VSQRT.F64 is correctly rounded, so this is
 * bit-identical to MATLAB's sqrt rather than merely close to it.
 *
 * always_inline because this build is -O0, where a static function is a real call: step 3 makes
 * 1024 of them, and a call plus a stack frame per sample would show up in the A4.6 numbers as
 * overhead the shipped code would not have.
 *
 * If the assembler rejects the %P modifier, the fallback is sqrt() from <math.h> -- but that
 * also needs m added to the linker's library list, because the Vitis link line has no -lm
 * (see Debug/objects.mk).
 *
 * The off-target branch is for the host, which is where this code gets checked against MATLAB
 * (build/scratch/): x86 has no vsqrt.f64, and an inline asm is a hard error there rather than a
 * warning. __builtin_sqrt compiles to sqrtsd, which is correctly rounded for the same reason
 * VSQRT.F64 is, so the host and the board agree bit for bit and the check transfers. On the
 * target the preprocessor picks the asm and nothing changes. */
static inline __attribute__((always_inline)) double d_sqrt(double v)
{
    if (v <= 0.0) {
        return 0.0;
    }
#if defined(__arm__) || defined(__aarch64__)
    {
        double r;
        __asm__ __volatile__("vsqrt.f64 %P0, %P1" : "=w"(r) : "w"(v));
        return r;
    }
#else
    return __builtin_sqrt(v);
#endif
}

static inline __attribute__((always_inline)) double d_abs(double v)
{
    return v < 0.0 ? -v : v;
}

static inline __attribute__((always_inline)) double d_hypot(double a, double b)
{
    return d_sqrt(a * a + b * b);
}

/* log10 without libm, for the one place the answer is wanted in dB.
 *
 * Argument reduction m * 2^e with m in [sqrt(1/2), sqrt(2)), then ln(m) by the atanh series in
 * t = (m-1)/(m+1), where |t| <= 0.1716. The eighth term is 2.8e-18 against ln(m) ~ 0.34, so the
 * series is not the error term. */
__attribute__((noinline, optimize("O2")))
static double d_log10(double v)
{
    static const double LN2      = 0.69314718055994530942;
    static const double INV_LN10 = 0.43429448190325182765;

    union { double d; uint64_t u; } c;
    double m, t, t2, s;
    int    e, i;

    if (v <= 0.0) {
        return 0.0;
    }

    c.d = v;
    e   = (int)((c.u >> 52) & 0x7FFu) - 1023;
    c.u = (c.u & 0x000FFFFFFFFFFFFFu) | 0x3FF0000000000000u;
    m   = c.d;
    if (m > 1.4142135623730951) {
        m *= 0.5;
        e += 1;
    }

    t  = (m - 1.0) / (m + 1.0);
    t2 = t * t;

    s = 1.0 / 15.0;
    for (i = 6; i >= 0; i--) {
        s = s * t2 + 1.0 / (double)(2 * i + 1);
    }
    s = s * t * 2.0;

    return (s + (double)e * LN2) * INV_LN10;
}

/* -- The FFT ------------------------------------------------------------------------------
 * Radix-2, decimation in time, in place. Written out rather than taken from a library because
 * the cost of this transform is one of the things being measured (A4.6), and because a library's
 * scaling convention would have to be reverse-engineered before CP1 could be interpreted.
 * MATLAB's fft() is FFTW, which uses a different decomposition -- the two agree to a few ulp,
 * not bit for bit, which is why ALIGN_TOL is not zero.
 */

static double tw_re[FFT_N / 2];
static double tw_im[FFT_N / 2];

/* W_n^k = cos(2*pi*k/n) - i*sin(2*pi*k/n) for k < n/2.
 *
 * Only the first half is stored: a radix-2 butterfly never asks for k >= n/2, and W^(k+n/2) =
 * -W^k, so the second half is a sign flip of the first if it is ever wanted. */
__attribute__((noinline, optimize("O2")))
static void twiddle_build(int n)
{
    const double delta = 6.283185307179586232 / (double)n;

    for (int k = 0; k < n / 2; k++) {
        double s, c;
        d_sincos((double)k * delta, &s, &c);
        tw_re[k] = c;
        tw_im[k] = -s;
    }
}

__attribute__((noinline, optimize("O2")))
static void fft_core(double *re, double *im, int n)
{
    int i, j, len, half, stride, blk, s;

    /* Bit reversal. j tracks i read backwards; the inner loop carries the carry. */
    j = 0;
    for (i = 1; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            double t;
            t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }

    for (len = 2; len <= n; len <<= 1) {
        half   = len >> 1;
        stride = n / len;              /* W_len^s == W_n^(s*stride) */
        for (blk = 0; blk < n; blk += len) {
            for (s = 0; s < half; s++) {
                int    tw = s * stride;
                double wr = tw_re[tw];
                double wi = tw_im[tw];
                int    a  = blk + s;
                int    b  = a + half;
                double tr = re[b] * wr - im[b] * wi;
                double ti = re[b] * wi + im[b] * wr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
    }
}

/* IDFT = conj( DFT( conj(Y) ) ) / n. Conjugating the data is the same as conjugating the
 * twiddle, so this reuses fft_core instead of carrying a second table -- which also means the two
 * directions cannot drift apart. */
__attribute__((noinline, optimize("O2")))
static void fft_inv(double *re, double *im, int n)
{
    const double inv = 1.0 / (double)n;
    int i;

    for (i = 0; i < n; i++) {
        im[i] = -im[i];
    }
    fft_core(re, im, n);
    for (i = 0; i < n; i++) {
        re[i] *= inv;
        im[i] = -im[i] * inv;
    }
}

/* ==========================================================================================
 * Below this line is station 9's own layer: the frame mask/Hann build, the six-step run, and
 * the five working buffers they own.
 *
 * Station 11 (sw/ps_features.h) needs only the math core above -- d_sincos, d_log10, twiddle_build,
 * fft_core, fft_inv -- on a longer transform, and shares none of what follows. Left unguarded, all
 * of it would be defined-but-unused in station 11's translation unit, which this repo's -Werror
 * (-Wunused-function / -Wunused-variable) turns into a build failure. So the layer is opt-out:
 * define PS_ENV_PIPELINE_MATH_ONLY to take just the core. ps_fft_test.c does not define it and is
 * unaffected.
 *
 * Note station 11 cannot reuse frame_setup() even if it wanted to: that mask is
 * h[0]=1, h[1..n/2-1]=2, h[n/2]=1 then band-passed, while the classifier was trained on MATLAB's
 * H = zeros(N,1); H(b1:b2) = 2 -- DC and Nyquist zero. The two masks differ at two bins, and
 * |ifft(fft(x.*w).*H)| is not linear in H, so the envelopes differ. Different spectrums, not a
 * longer one and a shorter one.
 * ========================================================================================== */
#ifndef PS_ENV_PIPELINE_MATH_ONLY

/* -- Working buffers -----------------------------------------------------------------------
 * All static, all DDR, all cacheable under the BSP's own mapping. None of it is shared with
 * CPU0, so none of it needs cache maintenance. The input frame is not one of them: whoever
 * acquired it owns it. */
static double g_fr[FFT_N];       /* working buffer, real part                       */
static double g_fi[FFT_N];       /* working buffer, imaginary part                  */
static double g_h[FFT_N];        /* the one-sided + band-pass mask, real            */
static double g_w[FFT_N];        /* Hann window                                     */
static double g_env[FFT_N];      /* envelope, kept for step 4                       */

/* -- Frame setup, done once ----------------------------------------------------------------
 * H and w depend only on N, fs and the band -- all fixed for the life of the program -- so they
 * are built here rather than inside the pipeline. That is not just tidiness: building H is ~513
 * iterations and building w is 1024 calls to d_sincos, which together are the same order as an
 * FFT. Left inside step 4 they would have shown up in the A4.6 breakdown as time the shipped
 * system never spends, and the whole point of that breakdown is to know where the budget goes.
 *
 * fs is a double, not an int: the board's rate is FCLK/1024 = 39062.5 Hz, and truncating it
 * would move df by 1.3e-5 relative -- invisible in the mask, but there is no reason to bake a
 * wrong number into the one place that defines what a bin means.
 */
__attribute__((noinline, optimize("O2")))
static void frame_setup(int n, double fs)
{
    const double df = (double)fs / (double)n;
    const double lo = FRAME_FRES - (double)FRAME_BANDPASS_BW / 2.0;
    const double hi = FRAME_FRES + (double)FRAME_BANDPASS_BW / 2.0;
    int i;

    /* H, matching MATLAB's  H(1)=1; H(2:N/2)=2; H(N/2+1)=1; H = H .* bp_mask
     *
     * MATLAB is 1-based: H(1) is DC, H(N/2+1) is the Nyquist bin, H(2:N/2) is every other
     * positive frequency, and 513..1024 are zero. In 0-based C that is h[0]=1,
     * h[1..n/2-1]=2, h[n/2]=1, h[n/2+1..n-1]=0.
     *
     * The band test uses the same expression MATLAB used, so the two agree on where the edges
     * fall. df is 48000/1024 = 46.875 Hz, exact in binary, and k*df is exact for every k below
     * n, so both languages decide f >= lo with the identical comparison and there is no edge
     * case hiding at bin 30 or bin 98. */
    for (i = 0; i <= n / 2; i++) {
        double fk = (double)i * df;
        double h;
        if (i == 0) {
            h = 1.0;
        } else if (i < n / 2) {
            h = 2.0;
        } else {
            h = 1.0;
        }
        g_h[i] = (fk >= lo && fk <= hi) ? h : 0.0;
    }
    for (i = n / 2 + 1; i < n; i++) {
        g_h[i] = 0.0;
    }

    /* Hann, symmetric: w[i] = 0.5*(1 - cos(2*pi*i/(N-1))). The N-1 rather than N is what makes
     * it symmetric and is what MATLAB's hann(N) produces; getting it wrong shifts every w[i] by
     * about a bin and moves the answer by far more than 1e-6. */
    for (i = 0; i < n; i++) {
        double s, c;
        d_sincos((6.283185307179586232 / (double)(n - 1)) * (double)i, &s, &c);
        g_w[i] = 0.5 * (1.0 - c);
    }
}

/* -- One run of the pipeline ---------------------------------------------------------------
 * Mirrors pipeline() in bearing_pipeline_final.m step for step. cp may be NULL, in which case
 * only feat[] is produced -- that is the path the repeat loop takes.
 */
struct caps {
    double   xa_re[8], xa_im[8];
    double   env[8];
    double   eac[8];
    double   e_re[4], e_im[4];
    double   mean_w;
    double   env_max, env_mean;
    uint32_t t_stage[6];
    uint32_t t_total;
    double   cbin;
    int      hw;
    double   e_mag[EXP_EBINS];   /* A4.2: |E| of whichever frame this run processed */
};

static uint32_t gtimer_now(void);

/* bpfo is a parameter rather than a macro for the same reason fs is: offline it is the study's
 * constant (frame A: 187.5 Hz at a 25 Hz shaft), on the board it is whatever the tacho measured
 * times the order being looked for. Baking it in would make the one number that changes between
 * the two runs the one number the code cannot be told. */
__attribute__((noinline, optimize("O2")))
static void pipeline_run(const double *x, int n, double bpfo, struct caps *cp, double *feat)
{
    uint32_t t0, t1;
    int      i, k;
    double   df, cbin, sum_w, sum_ew, m;
    int      hw;

    df   = (double)FRAME_FS / (double)n;
    cbin = bpfo / df;

    /* MATLAB: hw = max(1, min(2, floor(cbin/2))). Positive, so truncation is floor. */
    hw = (int)(cbin / 2.0);
    if (hw > 2) { hw = 2; }
    if (hw < 1) { hw = 1; }

    if (cp) {
        cp->cbin = cbin;
        cp->hw   = hw;
    }

    /* step 1 -- X = fft(x) */
    for (i = 0; i < n; i++) {
        g_fr[i] = x[i];
        g_fi[i] = 0.0;
    }
    GT_BARRIER();
    t0 = gtimer_now();
    fft_core(g_fr, g_fi, n);
    t1 = gtimer_now();
    GT_BARRIER();
    if (cp) {
        cp->t_stage[0] = t1 - t0;
    }

    /* step 2 -- xa = ifft(X .* H) */
    GT_BARRIER();
    t0 = gtimer_now();
    for (i = 0; i < n; i++) {
        g_fr[i] *= g_h[i];
        g_fi[i] *= g_h[i];
    }
    fft_inv(g_fr, g_fi, n);
    t1 = gtimer_now();
    GT_BARRIER();
    if (cp) {
        cp->t_stage[1] = t1 - t0;
        for (i = 0; i < 8; i++) {
            cp->xa_re[i] = g_fr[i];
            cp->xa_im[i] = g_fi[i];
        }
    }

    /* step 3 -- env = |xa| */
    GT_BARRIER();
    t0 = gtimer_now();
    for (i = 0; i < n; i++) {
        g_env[i] = d_hypot(g_fr[i], g_fi[i]);
    }
    t1 = gtimer_now();
    GT_BARRIER();
    if (cp) {
        cp->t_stage[2] = t1 - t0;
        for (i = 0; i < 8; i++) {
            cp->env[i] = g_env[i];
        }
        cp->env_max  = g_env[0];
        cp->env_mean = 0.0;
        for (i = 0; i < n; i++) {
            if (g_env[i] > cp->env_max) {
                cp->env_max = g_env[i];
            }
            cp->env_mean += g_env[i];
        }
        cp->env_mean /= (double)n;
    }

    /* step 4 -- m = sum(env.*w)/sum(w);  eac = env - m */
    GT_BARRIER();
    t0 = gtimer_now();
    sum_w  = 0.0;
    sum_ew = 0.0;
    for (i = 0; i < n; i++) {
        sum_w  += g_w[i];
        sum_ew += g_env[i] * g_w[i];
    }
    m = sum_ew / sum_w;
    for (i = 0; i < n; i++) {
        g_env[i] -= m;
    }
    t1 = gtimer_now();
    GT_BARRIER();
    if (cp) {
        cp->t_stage[3] = t1 - t0;
        cp->mean_w = m;
        for (i = 0; i < 8; i++) {
            cp->eac[i] = g_env[i];
        }
    }

    /* step 5 -- E = fft(eac .* w) / sum(w) */
    GT_BARRIER();
    t0 = gtimer_now();
    for (i = 0; i < n; i++) {
        g_fr[i] = g_env[i] * g_w[i];
        g_fi[i] = 0.0;
    }
    fft_core(g_fr, g_fi, n);
    for (i = 0; i < n; i++) {
        g_fr[i] /= sum_w;
        g_fi[i] /= sum_w;
    }
    t1 = gtimer_now();
    GT_BARRIER();
    if (cp) {
        cp->t_stage[4] = t1 - t0;
        for (k = 0; k < 4; k++) {
            int idx = (int)(cbin * (double)(k + 1));   /* bins 4, 8, 12, 16 */
            cp->e_re[k] = g_fr[idx];
            cp->e_im[k] = g_fi[idx];
        }
        /* A4.2: the whole curve, not just the four bins above. The magnitude is taken here
         * rather than left to step 6, which only ever looks at k*BPFO +- hw and so would fill in
         * four scattered bins and leave the other 60 undefined. */
        for (i = 0; i < EXP_EBINS; i++) {
            cp->e_mag[i] = d_hypot(g_fr[i], g_fi[i]);
        }
    }

    /* step 6 -- feat[k] = max|E| over k*BPFO +- hw bins
     *
     * MATLAB:  c = k*cbin; lo = max(1, floor(c)-hw+1); hi = min(N/2, floor(c)+hw+1)
     * 1-based E(lo:hi) is 0-based bins (lo-1)..(hi-1) = floor(c)-hw .. floor(c)+hw. MATLAB's
     * min is against N/2, i.e. the 0-based index n/2, which is the Nyquist bin and is reachable,
     * so the upper bound is inclusive. */
    GT_BARRIER();
    t0 = gtimer_now();
    for (k = 1; k <= 4; k++) {
        int    cf = (int)((double)k * cbin);
        int    a  = cf - hw;
        int    b  = cf + hw;
        double best = 0.0;
        if (a < 0) {
            a = 0;
        }
        if (b > n / 2) {
            b = n / 2;
        }
        for (i = a; i <= b; i++) {
            double mg = d_hypot(g_fr[i], g_fi[i]);
            if (mg > best) {
                best = mg;
            }
        }
        feat[k - 1] = best;
    }
    t1 = gtimer_now();
    GT_BARRIER();
    if (cp) {
        cp->t_stage[5] = t1 - t0;
    }
}

#endif /* PS_ENV_PIPELINE_MATH_ONLY -- station 9's layer */

#endif /* PS_ENV_PIPELINE_H */
