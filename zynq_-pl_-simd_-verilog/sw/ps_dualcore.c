/*
 * PS-side bare-metal program: start Cortex-A9 #1 from Cortex-A9 #0 and prove it runs.
 *
 * Why this exists: the three-tier architecture claims L2 runs on A9#1 independently of L3 on
 * A9#0, and experiment 1 (group B) needs A9#1 loaded with real work. Neither claim has any
 * measurement behind it until CPU1 has actually been started once.
 *
 * Both cores execute THIS SAME ELF. CPU0 runs the normal BSP boot into main(); CPU1 is
 * released with its entry set to cpu1_entry() below. No second domain, no second ELF.
 *
 * Usage: in Vitis create an Empty Application (C) on the same platform and drop this file
 * into src/. Nothing else is needed -- the BSP's own boot code already parks any core that is
 * not CPU0 (see below), so CPU1 cannot accidentally re-run the BSP init.
 *
 * -- Everything below was read off the toolchain, not recalled ------------------------------
 *
 * | fact                      | value                                        | where from |
 * |---------------------------|----------------------------------------------|------------|
 * | A9_CPU_RST_CTRL           | 0xF8000244; bit1 = A9_RST1, bit5 = A9_CLKSTOP1 | BSP boot.S |
 * | SLCR unlock / lock        | 0xF8000008 <- 0xDF0D / 0xF8000004 <- 0x767B   | BSP boot.S |
 * | CPU1 start address        | 0xFFFFFFF0 (OCM boot-address register)        | Zynq TRM   |
 * | core id                   | MPIDR (`mrc p15,0,r1,c0,c0,5`), low 4 bits    | BSP boot.S |
 * | instruction set           | ARM (verified: _boot and main are at even addresses, 32-bit encodings) | readelf/objdump on the built ELF |
 * | code location             | .text at 0x00100000, i.e. DDR                 | linker script |
 * | OCM                       | 0x00000000 and 0xFFFF0000 are declared but UNUSED by the linker script | lscript.ld |
 * | SCTLR value the BSP uses  | 0x1005 = MMU + D-cache + I-cache              | BSP boot.S CRValMmuCac |
 * | TTBR0 OR value            | 0x5B (outer cacheable, write-back, walk)      | BSP boot.S |
 * | MMUTable address          | 0x00104000, 16 KB aligned, in DDR             | .mmu_tbl section header of the built ELF |
 *
 * The BSP's _boot opens with a RUNTIME check, not a compile-time one. It reads MPIDR with
 * `mrc p15,0,r1,c0,c0,5`, masks the low 4 bits, and branches to CheckEFUSE only if that is
 * zero; any other core falls into:
 *
 *     EndlessLoop0:
 *             wfe
 *             b EndlessLoop0
 *
 * So CPU1 pointed at _boot would be safe but useless (it would sit in wfe forever). CPU1's
 * entry therefore has to be our own function -- hence cpu1_entry().
 *
 * -- What the board said, 2026-09-19 --------------------------------------------------------
 *
 * First run PASSED, and two things came back different from what was assumed:
 *
 * 1. A9_CPU_RST_CTRL read back 0x00000000, not 0x22. CPU1 was never held in reset -- the
 *    BootROM leaves it parked in its own wfe loop, and 0xFFFFFFF0 is where it resumes. So the
 *    step that actually starts CPU1 is the boot-address write plus sev; clearing bit1/bit5 is
 *    a no-op here. It is kept because it costs nothing and covers a boot flow where CPU1
 *    really is held in reset, but it is not what does the work.
 * 2. CPU1 ran at roughly 5.8e5 increments per polling interval, i.e. ~23 MIPS. That is the
 *    uncached rate: with the MMU off, caches are dead on ARM and every instruction fetch goes
 *    to DDR. Hence the MMU/cache bring-up in cpu1_prep() below -- see the note there for why
 *    it is not optional.
 *
 * Second run added the MMU/cache bring-up in cpu1_prep() and FAILED its throughput check, but
 * for a reason that turned out to be the benchmark's fault rather than the CPU's: the loop it
 * measured read and wrote the shared page, which step 1 below had just made non-cacheable on
 * purpose. That check has been replaced -- see the benchmark note further down for the full
 * account and for what run 3 measures instead.
 *
 * Convention: ASCII only in every xil_printf string. Comments are English too, so that a Vitis
 * import cannot mangle them (Vitis reads UTF-8 as GBK and writes it back).
 */

#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#include "xil_mmu.h"
#include "xil_cache_l.h"

/* -- Registers -------------------------------------------------------------------------- */

#define SLCR_UNLOCK_REG   0xF8000008u
#define SLCR_LOCK_REG     0xF8000004u
#define SLCR_UNLOCK_KEY   0xDF0Du
#define SLCR_LOCK_KEY     0x767Bu

#define A9_CPU_RST_CTRL   0xF8000244u
#define A9_RST1           (1u << 1)   /* holds CPU1 in reset            */
#define A9_CLKSTOP1       (1u << 5)   /* stops CPU1's clock             */
#define CPU1_RELEASE_MASK (A9_RST1 | A9_CLKSTOP1)

#define CPU1_BOOT_ADDR    0xFFFFFFF0u

/* -- Shared memory ----------------------------------------------------------------------
 * OCM. Chosen over DDR on purpose: it is on-chip (no DDR controller dependency), and the
 * linker script does not use either OCM region, so nothing else can collide with it.
 *
 * OCM is CACHEABLE by default here -- the BSP's translation_table.S maps the 0xFFF00000
 * section as 0x4c0e (Normal, inner write-back), with its comment saying so outright. Without
 * the Xil_SetTlbAttributes() call in main() CPU0 would keep serving its own stale copies out
 * of the D-cache and never see a single one of CPU1's stores. That call is load-bearing.
 */
#define SHARED_BASE       0xFFFF0000u
#define SH_MAGIC          0   /* CPU1 publishes CPU1_MAGIC here once it is up     */
#define SH_STATE          1   /* CPU1's phase: 1 = timing cached, 2 = timing nc,
                                3 = both timed and published                        */
#define SH_TICKS_C        2   /* timer ticks CPU1 spent on BENCH_CALLS x bench1   */
#define SH_TICKS_NC       3   /* the same on bench_nc                             */
#define SH_CPU1_SCTLR     4   /* CPU1's SCTLR, read by CPU1 itself                */
#define SH_CPU1_ACTLR     5   /* CPU1's ACTLR, read by CPU1 itself                */
#define SH_CHECKSUM_C     6   /* checksum over the cacheable buffer               */
#define SH_CHECKSUM_NC    7   /* checksum over the non-cacheable buffer           */
#define SH_WORDS          8

#define CPU1_MAGIC        0xC0DE1BADu

/* -- Benchmark, and the three wrong turns it already took --------------------------------
 *
 * Run 1 measured a loop of `sh[SH_WORK] = sh[SH_WORK] + 1` -- a read-modify-write on the
 * shared page, in OCM. 5.8e5 per interval with the MMU off.
 *
 * Run 2 turned on the MMU and caches and changed nothing else. 1.38e6 per interval, a mere
 * 2.38x. That is not a disappointing CPU, it is a broken benchmark: OCM had deliberately been
 * made non-cacheable by Xil_SetTlbAttributes(), so the loop was bound by a non-cacheable
 * memory round trip, the one thing caching can never improve. What the 2.38x does prove is
 * that the bring-up itself worked -- instruction fetch went from ~10 cycles to ~1 per
 * instruction, which is the only component that could have changed.
 *
 * Run 3 measured an LCG over a private 1024-word cacheable array, and came back at 18.0 cycles
 * per element -- still wrong, for the opposite reason. The array was cacheable and the number
 * still would not move, because the loop was never bound by memory at all: it was bound by the
 * latency of its own multiply chain. Cortex-A9 issues in order, so with
 * `ldr -> mla -> mul -> add -> str` in program order, the next iteration's load cannot issue
 * until this iteration's store has, and the pipeline sits stalled on a chain that takes ~13
 * cycles to resolve. Whether the data came from L1 or from DDR made no difference to that.
 *
 * Run 4 attacked it from both sides at once -- the kernel unrolled by four into four INDEPENDENT
 * chains so the multiply latency has other work to hide behind, and the same kernel run on a
 * second buffer whose 1 MB MMU section is marked non-cacheable so the two rates differ in that
 * one attribute. Both of those are right and both are kept. The measurement around them was
 * wrong, and wrong in a way that could not have produced anything but gain = 1.
 *
 * Run 4 ran the two buffers ALTERNATELY in one loop, publishing a counter after each call:
 *
 *     for (;;) { lcg_run(bench1);   c  += S; sh[SH_WORK_C]  = c;
 *                lcg_run(bench_nc); nc += S; sh[SH_WORK_NC] = nc; }
 *
 * CPU0 samples both counters at one instant. Over a window containing P complete pairs, CPU1
 * advances EACH counter by P -- whether the two kernels took the same time or not. The only
 * freedom is +/-1 call, from where the sampling happens to land inside a pair. The ratio of two
 * counts that are forced within one of each other cannot be anything but 1, and the board said
 * exactly that: eight rounds identical to the last digit, two differing by exactly one call
 * (32768 elements). It was measuring the alternation, not the cache.
 *
 * Run 5 separates the arms in TIME instead. Each arm runs BENCH_CALLS calls back to back and is
 * timed on its own, by the core that did the work, off the shared global timer. Nothing is
 * published during either timed loop, so a non-cacheable store to the shared page cannot land
 * inside the measurement. CPU0 receives two tick counts for two equal amounts of work; their
 * ratio is the answer, and the slower arm cannot drag the faster one along with it.
 *
 * Both arrays live in .bss, i.e. DDR, which the BSP maps as normal write-back cacheable. CPU1
 * initialises them itself before timing, so nothing it reads was ever written by CPU0. */
#define BENCH_WORDS       1024u         /* 4 KB, fits the 32 KB L1 D-cache */
#define BENCH_PASSES      32u           /* array passes per lcg_run call   */
#define BENCH_STEP        (BENCH_PASSES * BENCH_WORDS)
#define BENCH_CALLS       16u           /* calls timed per arm             */

/* -- The criterion -----------------------------------------------------------------------
 * The ratio of the two tick counts, not an absolute throughput. Run 3 is the cautionary tale:
 * an absolute floor is a guess about code generation, and it was wrong twice. A ratio between
 * two timed runs of the same kernel on the same core differs only in the cacheability of one
 * buffer, so the only thing that can move it is the cache itself. It also cancels the clock
 * frequency outright -- both counts come from the same counter, so the 333.333 MHz figure and
 * the core clock the BSP reports never enter the verdict.
 *
 * 3x is chosen well under any plausible answer and well over any measurement noise. If it
 * fails, the two tick counts printed above it are the finding -- do not lower the ratio to make
 * it go green. */
#define MIN_CACHE_GAIN    3u

/* -- Global timer, used as the time base --------------------------------------------------
 * The shared Cortex-A9 global timer. Nothing in the BSP enables it (only XTime_SetTime does,
 * and nothing calls it), so main() turns it on before releasing CPU1. Both cores read the same
 * counter, which is what makes the interval below exact instead of a guessed busy-wait.
 * Base 0xF8F00200 (XPS_SCU_PERIPH_BASE + 0x200), control at +0x08, bit0 = enable.
 * Tick rate: the BSP's own definition, COUNTS_PER_SECOND = core clock / 2 = 333.333 MHz. */
#define GTIMER_BASE       0xF8F00200u
#define GTIMER_CTL_OFF    0x08u
#define GTIMER_LO_OFF     0x00u
#define GTIMER_HI_OFF     0x04u
#define TICKS_PER_SEC     333333343u
#define POLL_TICKS        (TICKS_PER_SEC / 10u)   /* exactly 100 ms */
#define POLL_STEP         (TICKS_PER_SEC / 40u)   /* exactly  25 ms */

/* The global timer is a single counter in the SCU, visible to both cores, so both use the same
 * accessor. Defined in the CPU0 section below; declared here because cpu1_main() times itself
 * with it. */
static uint32_t gtimer_now(void);

/* -- CPU1 side -------------------------------------------------------------------------- */

/* CPU1's own stack, in OCM. Deliberately NOT a .bss array:
 *   - OCM is non-cacheable here (see above), so nothing CPU1 pushes can ever be incoherent
 *     with CPU0, and it cannot end up sharing a 32-byte cache line with CPU0's heap the way a
 *     .bss array sitting next to __bss_end would;
 *   - it is SRAM, so the stack costs a couple of cycles instead of a DDR round trip.
 * 4 KB, growing down from the top. The shared page at 0xFFFF0000 is 32 KB below it. */
#define CPU1_STACK_TOP    0xFFFF8000u

void cpu1_main(void);   /* forward declaration */
void cpu1_prep(void);   /* forward declaration */

/* CPU1 comes out of reset in ARM state, MMU and caches off, sp undefined. It runs on the SAME
 * physical memory CPU0 does, so nothing needs relocating -- but this stub must not touch
 * memory before it has a stack, hence naked (no prologue pushing onto a garbage sp).
 * `b` is a tail call: cpu1_prep never returns.
 *
 * Why movw/movt and not `ldr sp, =0xFFFF8000` anywhere in this file's inline asm:
 *
 * `ldr Rd, =const` does not encode the constant. It asks the assembler to park it in the
 * implicit literal pool, which GAS only flushes at the end of a section or at the next .section
 * directive -- and the ARM encoding reaches 4095 bytes back, no further. The compiler's own
 * literals are unaffected (GCC emits them inline), so this only ever shows up in inline asm.
 * That is exactly what broke this build: at -O2 the whole .text is small enough for the
 * end-of-section pool to stay in range, but Vitis builds at -O0, where the pool landed past the
 * limit and the assembler stopped with "invalid literal constant: pool needs to be closer".
 * The old version of this file compiled at -O0 only by luck -- a few kilobytes less code and it
 * would have failed the same way. movw/movt pair carries the whole address in the instruction
 * stream, so there is no pool and the failure mode cannot come back. */
__attribute__((naked, noinline))
void cpu1_entry(void)
{
    __asm__ __volatile__(
        "movw sp, #0x8000     \n"
        "movt sp, #0xFFFF     \n"
        "b    cpu1_prep       \n"
    );
}

/* Bring CPU1 up to the same operating point CPU0 is at, then hand off to cpu1_main().
 *
 * Why this is not optional: on ARM, with the MMU disabled, the caches are not used at all --
 * every access is treated as strongly ordered. CPU1 is out of reset with the MMU off, so on
 * the first run it fetched every single instruction from DDR and measured ~23 MIPS. Measured
 * per-interval delta was 5.8e5, i.e. ~23 MIPS. Its own SCTLR was not read back on that run,
 * which is why cpu1_main() now publishes it -- see the note there.
 *
 * Three things are done here that a naive copy of the BSP boot sequence would get wrong:
 *   - Xil_DCacheInvalidate() is NOT used. It calls Xil_L2CacheInvalidate() underneath, and
 *     invalidating the L2 from CPU1 would throw away CPU0's live cache contents. Only the
 *     L1-only variants from xil_cache_l.h are used here.
 *   - the SCU is not touched. CPU0 already enabled it; re-enabling the SCU or running its
 *     "invalidate all" register from CPU1 would drop CPU0's duplicate tags.
 *   - the L2 is not initialised. The BSP says so itself: "For AMP, assume running on CPU1.
 *     Don't initialize L2 Cache".
 *
 * The translation table is the BSP's own, shared -- .mmu_tbl is a single 16 KB block in DDR
 * and both cores point TTBR0 at it. That is why the non-cacheable attribute CPU0 wrote for
 * the OCM section is inherited for free, and why the two cores cannot disagree about it.
 */
__attribute__((noreturn, noinline))
void cpu1_prep(void)
{
    /* Invalidate L1 I and D before enabling them -- the ARM ARM requires it, and the L1 line
     * state after a non-power-on reset is not defined. */
    Xil_L1DCacheInvalidate();
    Xil_L1ICacheInvalidate();

    __asm__ __volatile__(
        "mov  r0, #0                \n"
        "mcr  p15, 0, r0, c8, c7, 0 \n"   /* invalidate the TLBs            */
        "movw r0, #:lower16:_vector_table \n"
        "movt r0, #:upper16:_vector_table \n"
        "mcr  p15, 0, r0, c12, c0, 0\n"   /* VBAR: CPU1's own vector base   */
        "movw r0, #:lower16:MMUTable      \n"  /* the BSP's shared table   */
        "movt r0, #:upper16:MMUTable      \n"
        "orr  r0, r0, #0x5B         \n"   /* TTBR0 attributes, same as BSP  */
        "mcr  p15, 0, r0, c2, c0, 0 \n"
        "mvn  r0, #0                \n"
        "mcr  p15, 0, r0, c3, c0, 0 \n"   /* DACR: all domains manager      */
        "movw r0, #0x1005           \n"   /* SCTLR: MMU + D-cache + I-cache */
        "mcr  p15, 0, r0, c1, c0, 0 \n"
        "dsb                        \n"   /* let the MMU settle             */
        "isb                        \n"
        "mrc  p15, 0, r0, c1, c0, 1 \n"   /* ACTLR                          */
        "orr  r0, r0, #(1 << 6)     \n"   /* SMP: join SCU coherency        */
        "orr  r0, r0, #1            \n"   /* cache/TLB maintenance broadcast*/
        "mcr  p15, 0, r0, c1, c0, 1 \n"
        ::: "r0", "memory"
    );

    cpu1_main();
    __builtin_unreachable();
}

/* The benchmark kernel, run by both cores on their own private buffers.
 *
 * Unrolled by four with four INDEPENDENT chains. The elements were always independent of each
 * other in value; what was not independent was the issue stream. With one element per iteration
 * the whole `ldr -> mla -> mul -> add -> str` chain sits in program order with nothing between
 * its links, and an in-order core stalls at each link -- which is exactly the 18 cycles/element
 * run 3 measured. Four chains interleaved give the pipeline three other things to issue while
 * the first chain's multiplier settles.
 *
 * Deliberately NOT written twice with the same constants pasted in both places: CPU0 runs
 * this very function on its own buffer to produce the reference checksum, so the two cores
 * cannot disagree about what "the right answer" is.
 *
 * The optimize/noinline pair is not decoration. This project builds at -O0 (see the -O0 -g3 in
 * Debug/src/subdir.mk), and at -O0 the loop below is several times the instruction count it
 * needs to be -- address arithmetic recomputed every iteration, constants reloaded, no strength
 * reduction. Timing THAT would report the cost of the build flags rather than the cost of the
 * algorithm. Pinning this one function at -O2 makes the number mean the same thing in a Debug
 * and in a Release build. noinline is there so the attribute cannot be silently dropped by
 * inlining into an -O0 caller. */
#define BENCH_UNROLL      4u

__attribute__((noinline, optimize("O2")))
static void lcg_run(uint32_t *buf)
{
    for (uint32_t p = 0; p < BENCH_PASSES; p++) {
        for (uint32_t i = 0; i < BENCH_WORDS; i += BENCH_UNROLL) {
            uint32_t a = buf[i + 0u];
            uint32_t b = buf[i + 1u];
            uint32_t c = buf[i + 2u];
            uint32_t d = buf[i + 3u];

            a = a * 1664525u + 1013904223u;  a = a * 22695477u + 1u;
            b = b * 1664525u + 1013904223u;  b = b * 22695477u + 1u;
            c = c * 1664525u + 1013904223u;  c = c * 22695477u + 1u;
            d = d * 1664525u + 1013904223u;  d = d * 22695477u + 1u;

            buf[i + 0u] = a;
            buf[i + 1u] = b;
            buf[i + 2u] = c;
            buf[i + 3u] = d;
        }
    }
}

/* Same fold either way, so it is order-sensitive: a rotate before the XOR means permuting the
 * buffer changes the result, so a buffer that was never written cannot accidentally sum to the
 * right value. */
static uint32_t lcg_sum(const uint32_t *buf)
{
    uint32_t s = 0;
    for (uint32_t i = 0; i < BENCH_WORDS; i++) {
        s = (s << 1) | (s >> 31);
        s ^= buf[i];
    }
    return s;
}

static void lcg_fill(uint32_t *buf)
{
    for (uint32_t i = 0; i < BENCH_WORDS; i++) {
        buf[i] = i + 1u;
    }
}

/* CPU0's own replica of the benchmark, on its own cacheable buffer. Never touched by CPU1. */
static uint32_t bench0[BENCH_WORDS] __attribute__((aligned(64)));

/* CPU1's two buffers, differing in one thing only: the MMU attribute of the 1 MB section they
 * sit in. bench1 keeps the BSP's mapping (normal write-back cacheable); bench_nc's section is
 * rewritten to non-cacheable by main() before CPU1 is released. Both are ordinary DDR, so the
 * A/B isolates caching and nothing else.
 *
 * The 1 MB alignment is not cosmetic: the MMU table is a section table covering 1 MB per entry,
 * so the attribute can only be flipped on a 1 MB boundary. A 4 KB array inside a 1 MB-aligned
 * section is the smallest thing that can be flipped. Times NB: the array is 4 KB, and
 * Xil_SetTlbAttributes on its section also affects any other variable the linker happens to
 * place in those 1 MB -- hence this array is padded out to occupy the whole section by itself
 * (see BENCH_NC_PAD), so nothing else gets dragged along.
 *
 * ⚠ The alignment is spelled **for the target only**. scripts/check_ps_apps.py compiles these
 * sources with a native x86-64 GCC (mingw here), and PE/COFF caps object alignment at 8192 --
 * `aligned(1u << 20)` is not merely unsatisfiable there, it is rejected outright, which used to
 * abort that whole script before it reached any other app. It is a target requirement (an A9
 * section-table fact), so the host build simply does not restate it; every other line is shared.
 *
 * Because the attribute is now invisible to one of the two compilers, the invariant it encodes
 * is re-checked **at run time** instead of trusted (see "bench_nc sits on a 1 MB boundary" in
 * main()). That check is what makes this split safe: if the attribute ever stops taking effect
 * on the target, the board run FAILs instead of quietly timing a cacheable buffer. */
#if defined(__arm__) || defined(__ARM_ARCH) || defined(__aarch64__)
#define BENCH_NC_SECTION_ALIGN __attribute__((aligned(1u << 20)))
#else
#define BENCH_NC_SECTION_ALIGN /* host: see above */
#endif
#define BENCH_NC_PAD      ((1u << 20) / sizeof(uint32_t))
static uint32_t bench1[BENCH_WORDS]     __attribute__((aligned(64)));
static uint32_t bench_nc[BENCH_NC_PAD]  BENCH_NC_SECTION_ALIGN;

/* Everything below runs on CPU1, with the MMU and caches on.
 *
 * Publication order is load-bearing: SCTLR/ACTLR first, then the two checksums, then the work
 * counters, and MAGIC last. A reader that sees MAGIC therefore knows every earlier field is
 * already there, and a bring-up that failed halfway still leaves the evidence behind. */
void cpu1_main(void)
{
    volatile uint32_t *sh = (volatile uint32_t *)SHARED_BASE;
    uint32_t sctlr, actlr, t0, t1;

    /* Read back our own CP15 state. This, not the timing, is the direct proof that the
     * sequence in cpu1_prep() took effect: without it a timing number alone could not say
     * whether the MMU came on at all. On the board this reads 0x08c5107d -- low 12 bits
     * 0x107d, so M (bit 0), C (bit 2) and I (bit 12) are set. The bits above that are not
     * ours: only 0x1005 is ever written, and the surplus is exactly the Cortex-A9's own
     * read-as-one pattern, which is why the check tests 0x1005 as a mask rather than equality. */
    __asm__ __volatile__("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
    __asm__ __volatile__("mrc p15, 0, %0, c1, c0, 1" : "=r"(actlr));
    sh[SH_CPU1_SCTLR] = sctlr;
    sh[SH_CPU1_ACTLR] = actlr;

    /* Fill both buffers ourselves, so nothing CPU1 reads was ever written by CPU0. The
     * non-cacheable one gets the same treatment, which also proves its store path works. */
    lcg_fill(bench1);
    lcg_fill(bench_nc);

    lcg_run(bench1);
    sh[SH_CHECKSUM_C] = lcg_sum(bench1);

    lcg_run(bench_nc);
    sh[SH_CHECKSUM_NC] = lcg_sum(bench_nc);

    sh[SH_TICKS_C]  = 0u;
    sh[SH_TICKS_NC] = 0u;
    sh[SH_MAGIC]    = CPU1_MAGIC;

    /* Arm A: the cacheable buffer. One untimed call first, so the timed loop starts with the
     * array already resident in L1 and is not paying for the fill. bench1 is 4 KB against a
     * 32 KB L1 D-cache, so every call after that one is an L1 hit.
     *
     * The empty asm is a compiler barrier, not a no-op: it stops the compiler from moving the
     * calls that do the work across the two timer reads. The reads themselves are already
     * volatile (Xil_In32), which is what actually orders them. */
    lcg_run(bench1);
    sh[SH_STATE] = 1u;

    __asm__ __volatile__("" ::: "memory");
    t0 = gtimer_now();
    for (uint32_t k = 0; k < BENCH_CALLS; k++) {
        lcg_run(bench1);
    }
    t1 = gtimer_now();
    __asm__ __volatile__("" ::: "memory");

    sh[SH_TICKS_C] = t1 - t0;

    /* Arm B: the same kernel, the same call count, the same warm-up call, on a buffer that
     * differs in exactly one thing -- the MMU attribute of its 1 MB section. The warm-up is
     * kept even though it changes nothing here (a non-cacheable read does not allocate), so
     * that the two arms stay textually symmetric and there is no argument about whether one of
     * them got a head start. */
    lcg_run(bench_nc);
    sh[SH_STATE] = 2u;

    __asm__ __volatile__("" ::: "memory");
    t0 = gtimer_now();
    for (uint32_t k = 0; k < BENCH_CALLS; k++) {
        lcg_run(bench_nc);
    }
    t1 = gtimer_now();
    __asm__ __volatile__("" ::: "memory");

    sh[SH_TICKS_NC] = t1 - t0;

    /* Both tick counts are published above this store, and STATE is what CPU0 waits on, so a
     * CPU0 that sees 3 sees two complete measurements -- not one finished and one in flight. */
    sh[SH_STATE] = 3u;

    /* Done. Spin rather than return: there is nothing on this core to return to. */
    for (;;) {
        /* spin */
    }
}

/* -- CPU0 side -------------------------------------------------------------------------- */

/* The BSP's own translation table: one 32-bit section descriptor per 1 MB of address space,
 * defined in translation_table.S and shared by both cores. Readable from C, which is the point
 * -- an attribute change can be confirmed instead of assumed. */
extern uint32_t MMUTable;

static int failures = 0;

static uint32_t mpidr(void)
{
    uint32_t v;
    __asm__ __volatile__("mrc p15,0,%0,c0,c0,5" : "=r"(v));
    return v & 0xFu;
}

/* The section descriptor covering `addr`. */
static uint32_t tlb_entry(uint32_t addr)
{
    return Xil_In32((INTPTR)&MMUTable + ((addr >> 20) & 0xFFFu) * 4u);
}

/* The global timer's low word. Only the low word is used: at 333 MHz it wraps every 12.9 s,
 * and every interval here is 100 ms, so unsigned subtraction is exact across a wrap and the
 * high word would only be a second thing to get wrong. */
static uint32_t gtimer_now(void)
{
    return Xil_In32(GTIMER_BASE + GTIMER_LO_OFF);
}

/* Busy wait for an exact number of timer ticks. This replaces the previous cycle-counting
 * loop, which was calibrated by guesswork against an assumed 666 MHz and left a 1.7x
 * uncertainty in every rate derived from it. Both cores read the same counter, so a
 * throughput figure is now anchored to a number that was not invented here. */
static void wait_ticks(uint32_t ticks)
{
    uint32_t t0 = gtimer_now();
    while ((uint32_t)(gtimer_now() - t0) < ticks) {
        /* spin */
    }
}

/* Elements per second, from a tick count measured over BENCH_CALLS calls. The product is 48
 * bits, so it is formed in 64 and divided there; libgcc's unsigned division is linked into every
 * Xilinx standalone image and this is called twice per run, off any hot path. A zero tick count
 * is reported as zero rather than divided by. */
static uint32_t rate_of(uint32_t ticks)
{
    unsigned long long elems =
        (unsigned long long)BENCH_CALLS * (unsigned long long)BENCH_STEP;

    if (ticks == 0u) {
        return 0u;
    }
    return (uint32_t)((elems * (unsigned long long)TICKS_PER_SEC) /
                      (unsigned long long)ticks);
}

/* xil_printf does not support %08x / %-12s / %4d and prints garbage with them, so pad by hand. */
static void print_hex32(uint32_t v)
{
    static const char digits[] = "0123456789abcdef";
    char s[9];
    for (int i = 7; i >= 0; i--) {
        s[i] = digits[v & 0xFu];
        v >>= 4;
    }
    s[8] = '\0';
    xil_printf("%s", s);
}

static void check(int cond, const char *what)
{
    if (cond) {
        xil_printf("  [ok]   %s\r\n", what);
    } else {
        xil_printf("  [FAIL] %s\r\n", what);
        failures++;
    }
}

int main(void)
{
    volatile uint32_t *sh = (volatile uint32_t *)SHARED_BASE;
    uint32_t rst_before, rst_after, tctl;
    uint32_t ticks_c = 0u, ticks_nc = 0u, state = 0u, gain;
    uint32_t sctlr1, actlr1, sum1, sum_nc, sum0;
    uint32_t rate_c = 0u, rate_nc = 0u;
    int      seen = 0;

    xil_printf("\r\n===== A9 dual-core start + cache A/B test =====\r\n");
    xil_printf("running on core #%d\r\n\r\n", (int)mpidr());

    /* 0. Start the global timer. Nothing else in a bare-metal BSP does this -- XTime_SetTime is
     *    the only function that writes the control register and nothing calls it -- so without
     *    these two lines the counter stays frozen at 0 and every wait below would return
     *    immediately. Read-modify-write rather than a blind store, so the prescaler field is
     *    left exactly as the hardware came up with. */
    tctl = Xil_In32(GTIMER_BASE + GTIMER_CTL_OFF);
    Xil_Out32(GTIMER_BASE + GTIMER_CTL_OFF, tctl | 1u);
    xil_printf("[0] global timer ctl 0x");
    print_hex32(tctl);
    xil_printf(" -> 0x");
    print_hex32(Xil_In32(GTIMER_BASE + GTIMER_CTL_OFF));
    xil_printf(" (bit0 = enable, prescaler %u)\r\n", (tctl >> 8) & 0xFFu);

    /* 1. Memory attributes. Two sections get rewritten, both before CPU1 exists so neither can
     *    race with the other core's cache:
     *      - the shared page, to non-cacheable. Without this CPU0 serves its own stale copies
     *        out of the D-cache and never sees a single one of CPU1's stores.
     *      - bench_nc's 1 MB section, to non-cacheable, which is what makes the A/B in step 4
     *        an A/B. bench1, one line below it in the same .bss, keeps the BSP's write-back
     *        mapping, so the only difference between the two kernels is the cache.
     *    Both are then read back OUT of the translation table. Run 2 was wasted on an attribute
     *    that was assumed to have taken effect; this time the table entry itself is evidence. */
    xil_printf("[1] memory attributes\r\n");
    xil_printf("  shared page     0x");
    print_hex32(SHARED_BASE);
    xil_printf(" (OCM)  entry 0x");
    print_hex32(tlb_entry(SHARED_BASE));
    Xil_SetTlbAttributes((INTPTR)SHARED_BASE, NORM_NONCACHE);
    xil_printf(" -> 0x");
    print_hex32(tlb_entry(SHARED_BASE));
    xil_printf("\r\n");

    xil_printf("  bench_nc        0x");
    print_hex32((uint32_t)(uintptr_t)bench_nc);
    xil_printf(" (DDR)  entry 0x");
    print_hex32(tlb_entry((uint32_t)(uintptr_t)bench_nc));
    Xil_SetTlbAttributes((INTPTR)bench_nc, NORM_NONCACHE);
    xil_printf(" -> 0x");
    print_hex32(tlb_entry((uint32_t)(uintptr_t)bench_nc));
    xil_printf("\r\n");
    xil_printf("  bench1          0x");
    print_hex32((uint32_t)(uintptr_t)bench1);
    xil_printf(" (DDR)  entry 0x");
    print_hex32(tlb_entry((uint32_t)(uintptr_t)bench1));
    xil_printf("  (left cacheable)\r\n");

    sh[SH_MAGIC]   = 0xAAAAAAAAu;
    sh[SH_TICKS_C] = 0x55555555u;
    check(sh[SH_MAGIC] == 0xAAAAAAAAu && sh[SH_TICKS_C] == 0x55555555u,
          "CPU0 can write and read back the shared page");

    check(tlb_entry(SHARED_BASE) == ((SHARED_BASE & 0xFFF00000u) | NORM_NONCACHE),
          "the shared page's translation table entry is non-cacheable");
    /* The 1 MB alignment is spelled only for the target (BENCH_NC_SECTION_ALIGN), so the
     * invariant it encodes is asserted here rather than trusted. It has to be a separate check:
     * the next one compares the table entry against the section *derived from this same
     * address*, so it agrees no matter where the linker put the array -- a misaligned bench_nc
     * would leave that check green while the A/B silently timed two cacheable buffers. */
    check(((uint32_t)(uintptr_t)bench_nc & 0xFFFFFu) == 0u,
          "bench_nc sits on a 1 MB MMU section boundary");
    check(tlb_entry((uint32_t)(uintptr_t)bench_nc) ==
              (((uint32_t)(uintptr_t)bench_nc & 0xFFF00000u) | NORM_NONCACHE),
          "bench_nc's translation table entry is non-cacheable");
    check(tlb_entry((uint32_t)(uintptr_t)bench1) !=
              (((uint32_t)(uintptr_t)bench1 & 0xFFF00000u) | NORM_NONCACHE),
          "bench1's translation table entry is still cacheable (the A/B has two arms)");

    sh[SH_MAGIC]       = 0u;
    sh[SH_STATE]       = 0u;
    sh[SH_TICKS_C]     = 0u;
    sh[SH_TICKS_NC]    = 0u;
    sh[SH_CPU1_SCTLR]  = 0u;
    sh[SH_CPU1_ACTLR]  = 0u;
    sh[SH_CHECKSUM_C]  = 0u;
    sh[SH_CHECKSUM_NC] = 0u;

    /* 2. Point CPU1 at our entry and wake it.
     *    All three of these are done because we do not know which state CPU1 is in:
     *      - if it is held in reset, clearing A9_RST1/A9_CLKSTOP1 starts it at CPU1_BOOT_ADDR
     *      - if it is parked in the BootROM's wfe loop, the sev wakes it and CPU1_BOOT_ADDR is
     *        where it resumes. Measurement says this is the case that actually applies.
     *    Writing CPU1_BOOT_ADDR before releasing matters: CPU1 reads it the moment it leaves
     *    reset, so setting it afterwards would be too late. */
    xil_printf("\r\n[2] releasing CPU1, entry = cpu1_entry\r\n");

    rst_before = Xil_In32(A9_CPU_RST_CTRL);
    xil_printf("  A9_CPU_RST_CTRL before = 0x");
    print_hex32(rst_before);
    xil_printf("\r\n");

    Xil_Out32(SLCR_UNLOCK_REG, SLCR_UNLOCK_KEY);
    Xil_Out32(CPU1_BOOT_ADDR, (uint32_t)cpu1_entry);
    __asm__ __volatile__("dsb" ::: "memory");
    __asm__ __volatile__("sev");
    Xil_Out32(A9_CPU_RST_CTRL, rst_before & ~CPU1_RELEASE_MASK);
    Xil_Out32(SLCR_LOCK_REG, SLCR_LOCK_KEY);

    rst_after = Xil_In32(A9_CPU_RST_CTRL);
    xil_printf("  A9_CPU_RST_CTRL after  = 0x");
    print_hex32(rst_after);
    xil_printf("\r\n");
    check((rst_after & CPU1_RELEASE_MASK) == 0, "CPU1 reset and clock-stop bits are cleared");

    /* 3. Compute the reference checksum on CPU0's own copy, using the same kernel CPU1 runs.
     *    Done here and not after the polling loop so its cost cannot land inside a timed
     *    interval; ~33k elements is about a quarter of a millisecond either way. */
    xil_printf("\r\n[3] CPU0 reference checksum\r\n");
    for (uint32_t i = 0; i < BENCH_WORDS; i++) {
        bench0[i] = i + 1u;
    }
    lcg_run(bench0);
    sum0 = lcg_sum(bench0);
    xil_printf("  CPU0 checksum = 0x");
    print_hex32(sum0);
    xil_printf("   (MAGIC seen so far = 0x");
    print_hex32(sh[SH_MAGIC]);
    xil_printf(")\r\n");

    /* 4. Wait for CPU1 to finish both timed arms. This is a progress trace, not a measurement:
     *    the measurement is the two tick counts, which CPU1 took itself, on its own core, while
     *    CPU0 was doing nothing but this loop. That is the whole point of run 5 -- in run 4 the
     *    numbers were sampled across cores at instants chosen by CPU0, and the sampling itself
     *    was what the experiment ended up measuring.
     *
     *    The round cap matters. Run 4's loop was unbounded in spirit and this one could hang
     *    the same way if CPU1 never reached STATE 3; with the cap the run always ends and the
     *    checks below report what actually happened, which is worth more than a silent hang. */
    xil_printf("\r\n[4] waiting for CPU1 to time both arms, polled every %u ticks\r\n",
               POLL_STEP);
    xil_printf("  round, MAGIC, STATE, ticks_cached, ticks_noncache\r\n");

    for (int i = 0; i < 200; i++) {
        uint32_t m = sh[SH_MAGIC];

        if (m == CPU1_MAGIC) {
            seen = 1;
        }

        state = sh[SH_STATE];
        if (state >= 3u) {
            break;
        }

        xil_printf("  %d, 0x", i);
        print_hex32(m);
        xil_printf(", %u, %u, %u\r\n", state, sh[SH_TICKS_C], sh[SH_TICKS_NC]);

        wait_ticks(POLL_STEP);
    }

    ticks_c  = sh[SH_TICKS_C];
    ticks_nc = sh[SH_TICKS_NC];
    sctlr1   = sh[SH_CPU1_SCTLR];
    actlr1   = sh[SH_CPU1_ACTLR];
    sum1     = sh[SH_CHECKSUM_C];
    sum_nc   = sh[SH_CHECKSUM_NC];

    /* The verdict is the ratio of two tick counts for equal work, so the clock cancels --
     * only the cacheability of the buffer can move it, and the 333.333 MHz figure never
     * enters. A zero on either side means that arm did not finish; report 0 and let the check
     * fail on its own terms. Note that dividing rather than pre-multiplying means the ratio
     * carries no rounding bias of its own. */
    if (ticks_c != 0u && ticks_nc != 0u) {
        gain = ticks_nc / ticks_c;
    } else {
        gain = 0u;
    }
    rate_c  = rate_of(ticks_c);
    rate_nc = rate_of(ticks_nc);

    xil_printf("\r\n[5] results\r\n");
    xil_printf("  CPU1 SCTLR   = 0x");
    print_hex32(sctlr1);
    xil_printf("   (want bits 0x1005 = MMU | D$ | I$)\r\n");
    xil_printf("  CPU1 ACTLR   = 0x");
    print_hex32(actlr1);
    xil_printf("   (want bit 6 = SMP)\r\n");
    xil_printf("  checksum     = 0x");
    print_hex32(sum1);
    xil_printf(" vs CPU0 0x");
    print_hex32(sum0);
    xil_printf("\r\n");
    xil_printf("  checksum_nc  = 0x");
    print_hex32(sum_nc);
    xil_printf("\r\n");
    xil_printf("  STATE        = %u (3 = both arms done)\r\n", state);
    xil_printf("  work per arm = %u elements x %u calls = %u elements\r\n",
               BENCH_STEP, BENCH_CALLS, BENCH_CALLS * BENCH_STEP);
    xil_printf("  cached       = %u ticks -> %u elements/s\r\n", ticks_c, rate_c);
    xil_printf("  non-cacheable= %u ticks -> %u elements/s\r\n", ticks_nc, rate_nc);
    xil_printf("  => cache gain = %u x faster\r\n", gain);
    xil_printf("\r\n");

    check(seen,       "CPU1 wrote the magic value to the shared page");
    check(state >= 3u,
          "CPU1 finished both timed arms (STATE reached 3)");
    check(ticks_c != 0u && ticks_nc != 0u,
          "both arms produced a non-zero tick count");
    check(mpidr() == 0, "this core is CPU0 (MPIDR says so)");
    check((sctlr1 & 0x1005u) == 0x1005u,
          "CPU1 SCTLR says MMU, D-cache and I-cache are all enabled");
    check((actlr1 & (1u << 6)) != 0,
          "CPU1 ACTLR says SMP is set (joined the SCU)");
    check(sum1 == sum0,
          "CPU1's cacheable-buffer checksum equals CPU0's (memory and arithmetic intact)");
    check(sum_nc == sum0,
          "CPU1's non-cacheable-buffer checksum equals CPU0's (both arms did the same work)");
    check(gain >= MIN_CACHE_GAIN,
          "the same kernel runs at least MIN_CACHE_GAIN times faster out of the cache");

    xil_printf("\r\n===== %s (%d failures) =====\r\n",
               failures == 0 ? "PASS" : "FAIL", failures);
    return failures;
}
