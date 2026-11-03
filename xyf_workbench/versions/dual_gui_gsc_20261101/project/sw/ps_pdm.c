/*
 * PS-side consumer for the PDM capture window (AXI 0x300-0x3FF).
 *
 * This is the software half of docs/pdm_array_spec.md P-11. Until now the window was
 * exercised only by scripts/test_pdm_onboard.tcl over JTAG; P-11 says "settled, software
 * writes to this" and that software did not exist. It does now.
 *
 * Usage is exactly the monitor window's (0x100) and the spec's five steps:
 *   1. CTRL = 3            enable EN + CAPTURE (this restarts the capture epoch)
 *   2. poll STATUS.READY   which bank is complete
 *   3. SELECT that bank
 *   4. INDEX = 0 .. LEN*(N_CH/2)-1, reading DATA for each
 *   5. ACK_SEQ = that bank's SEQ, then RELEASE = 1 to hand it back
 *
 * ---------------------------------------------------------------------------------------
 * `DATA` IS A REGISTER, NOT AN ARRAY. Step 4 means **write INDEX, then read DATA** --
 * do not walk the window with increasing addresses (0x320/0x324/0x328/...). Those are
 * other registers (ACKSEQ/RELEASE/FRAME/FROZEN/META) and they change on their own, so
 * a reader that walks addresses sees "varying data" and concludes it is working. That
 * exact mistake was made in test_pdm_onboard.tcl and cost a whole wrong diagnosis
 * (docs/issues/059): META happens to read 512 = LEN, which looked like the DC-blocking
 * residual bound -- which also happens to be 512. Two unrelated sources, same number,
 * each "confirming" the other.
 *
 * Cross-check: scripts/check_ps_apps.py parses the register offsets below and compares
 * them against rv32_pdm_capture.v's decode.
 *
 * ---------------------------------------------------------------------------------------
 * Why the first bank is full-scale and that is CORRECT
 *   With no microphone the data lines sit at 0 (the xdc enables PULLDOWN), so the CIC
 *   output sits at -full-scale and chan_align's DC blocker has to converge from there;
 *   that takes about 6000 samples (~150 ms). The bank captured at enable time therefore
 *   legitimately holds 0x8000. Run this program and let it take a *later* bank: it
 *   starts at a bank boundary, and by the time it has released one the next is fresh.
 */

#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"

#define RV32_BASE  0x43C00000u

/* -- PDM capture window: register n lives at 0x300 + 4n (rv32_pdm_capture.v) -------------- */
#define PDM(n)         (0x300u + 4u * (n))

#define R_CTRL         PDM(0)    /* [0]=EN, [1]=CAPTURE; a write here restarts the epoch  */
#define R_STATUS       PDM(1)    /* [1:0]=ready, [2]=write busy, [31:16]=frozen           */
#define R_LEN          PDM(2)    /* samples per bank; writable only while !CAPTURE        */
#define R_SELECT       PDM(3)    /* which bank DATA/SEQ/FIRST/META refer to               */
#define R_SEQ          PDM(4)    /* sequence of the selected bank                         */
#define R_FIRST        PDM(5)    /* frame_cnt at the bank's first sample                  */
#define R_DROP         PDM(6)    /* samples dropped (not banks)                           */
#define R_INDEX        PDM(7)    /* read pointer, in words                                */
#define R_DATA         PDM(8)    /* the word at INDEX                                     */
#define R_ACKSEQ       PDM(9)    /* write the SEQ you are done with                       */
#define R_RELEASE      PDM(10)   /* write 1; refused unless ACKSEQ matches                */
#define R_FRAME        PDM(11)   /* live frame counter (one per sample)                   */
#define R_FROZEN       PDM(12)   /* PCM constant warning; not reliable wire-break detection */
#define R_META         PDM(13)   /* LEN snapshot of the selected bank                     */
#define R_GAIN0        PDM(16)   /* +4k: two channels' Q2.14 gains per word               */

#define CTL_EN         (1u << 0)
#define CTL_CAPTURE    (1u << 1)

/* -- Board numbers ---------------------------------------------------------------------- */
#ifndef FCLK_HZ
#define FCLK_HZ        40000000u
#endif
#define SAMPLE_DIV     1024u                       /* PDM fs = FCLK / 1024 = 39.0625 kHz  */
#define N_CH           8u                        /* Four shared DATA lines, two microphones each. */
#define WORDS_PER_SAMP (N_CH / 2u)                 /* 2 channels per 32-bit word          */

#define BANKS_TO_READ  3u
#define POLL_LIMIT     20000000u                   /* bounded wait; never spin forever    */

/* -- Small helpers ---------------------------------------------------------------------- */
static void put_hex32(uint32_t v)
{
    /* xil_printf has no width modifiers; see the note in ps_main.c. */
    static const char d[] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i--) {
        xil_printf("%c", d[(v >> (i * 4)) & 0xF]);
    }
}

static void put_dec(uint32_t v)
{
    char b[12];
    int n = 0;
    if (v == 0) { xil_printf("0"); return; }
    while (v && n < (int)sizeof(b)) { b[n++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (n--) { xil_printf("%c", b[n]); }
}

/* One 32-bit word holds two 16-bit channels: low half = even channel, high = odd. */
static int16_t lo16(uint32_t w) { return (int16_t)(w & 0xFFFFu); }
static int16_t hi16(uint32_t w) { return (int16_t)(w >> 16); }

typedef struct {
    int32_t  min;
    int32_t  max;
    int64_t  sum;
    uint32_t n;
} chstat;

static void chstat_reset(chstat *c)
{
    c->min = 0x7FFFFFFF;
    c->max = -0x7FFFFFFF;
    c->sum = 0;
    c->n   = 0;
}

static void chstat_add(chstat *c, int16_t v)
{
    if (v < c->min) c->min = v;
    if (v > c->max) c->max = v;
    c->sum += v;
    c->n++;
}

/* -- The five-step read of one bank ----------------------------------------------------- */
static int read_bank(uint32_t bank, chstat ch[N_CH], uint32_t *seq_out,
                     uint32_t *first_out, uint32_t *len_out)
{
    uint32_t len, seq, i, w;
    uint32_t c;

    Xil_Out32(RV32_BASE + R_SELECT, bank);
    seq   = Xil_In32(RV32_BASE + R_SEQ);
    *len_out = len = Xil_In32(RV32_BASE + R_META);
    *first_out = Xil_In32(RV32_BASE + R_FIRST);
    *seq_out   = seq;

    if (len == 0 || len > 512u) {
        xil_printf("  bank %d: META says len=", (int)bank);
        put_dec(len);
        xil_printf(", refusing\r\n");
        return -1;
    }

    for (c = 0; c < N_CH; c++) chstat_reset(&ch[c]);

    /* Step 4: INDEX then DATA, one word at a time. */
    for (i = 0; i < len * WORDS_PER_SAMP; i++) {
        uint32_t word;
        Xil_Out32(RV32_BASE + R_INDEX, i);
        word = Xil_In32(RV32_BASE + R_DATA);
        w = i % WORDS_PER_SAMP;
        chstat_add(&ch[2u * w],      lo16(word));
        chstat_add(&ch[2u * w + 1u], hi16(word));
    }

    /* Do not acknowledge a bank whose ownership changed during the read. */
    if (Xil_In32(RV32_BASE + R_SEQ) != seq) {
        xil_printf("[FAIL] capture epoch/sequence changed during bank read\r\n");
        return -1;
    }
    /* Step 5: acknowledge the sequence, then hand the bank back. */
    Xil_Out32(RV32_BASE + R_ACKSEQ, seq);
    Xil_Out32(RV32_BASE + R_RELEASE, 1u);
    /* A refilled bank may already be ready again, but must have a new sequence. */
    if ((Xil_In32(RV32_BASE + R_STATUS) & (1u << bank)) &&
        Xil_In32(RV32_BASE + R_SEQ) == seq) {
        xil_printf("[FAIL] bank release was refused\r\n");
        return -1;
    }
    return 0;
}

int main(void)
{
    uint32_t i, c, bank, started;
    uint32_t f1, f2;
    uint32_t ready, frozen, drop;

    xil_printf("\r\n=== PDM capture window reader (AXI 0x300) ===\r\n");

    /* -- 1. enable ---------------------------------------------------------------------- */
    Xil_Out32(RV32_BASE + R_CTRL, CTL_EN | CTL_CAPTURE);
    started = Xil_In32(RV32_BASE + R_FRAME);

    xil_printf("CTRL readback = 0x");
    put_hex32(Xil_In32(RV32_BASE + R_CTRL));
    xil_printf("\r\n");
    xil_printf("GAIN[0..1]    = 0x");
    put_hex32(Xil_In32(RV32_BASE + R_GAIN0));
    xil_printf("   (0x4000 = Q2.14 unity; 0 would mute the chain)\r\n");

    /* -- 2. sample rate, measured rather than assumed ----------------------------------- */
    /* The default receiver suppresses PCM for 50ms plus CIC settling. */
    for (i = 0; i < POLL_LIMIT; i++) {
        if (Xil_In32(RV32_BASE + R_FRAME) != started) break;
    }
    if (i == POLL_LIMIT) {
        xil_printf("[FAIL] PDM startup produced no PCM group\r\n");
        return 1;
    }
    f1 = Xil_In32(RV32_BASE + R_FRAME);
    for (i = 0; i < 4000000u; i++) { __asm__ volatile ("nop"); }   /* crude ~10 ms */
    f2 = Xil_In32(RV32_BASE + R_FRAME);

    xil_printf("FRAME_CNT advanced by ");
    put_dec(f2 - f1);
    xil_printf(" over a short window (expect ~39.0625 kHz = FCLK/1024)\r\n");

    /* -- 3..5. read a few banks -------------------------------------------------------- */
    for (bank = 0; bank < BANKS_TO_READ; bank++) {
        chstat ch[N_CH];
        uint32_t seq = 0, first = 0, len = 0;
        uint32_t slot;

        /* Wait for a bank to become ready. Bound the wait so a dead chain reports
         * instead of hanging -- on JTAG a hang looks like the tool crashed. */
        ready = 0;
        for (i = 0; i < POLL_LIMIT; i++) {
            ready = Xil_In32(RV32_BASE + R_STATUS) & 0x3u;
            if (ready) break;
        }
        if (!ready) {
            xil_printf("[FAIL] no bank became ready (STATUS=0x");
            put_hex32(Xil_In32(RV32_BASE + R_STATUS));
            xil_printf(")\r\n");
            return 1;
        }

        slot = (ready & 1u) ? 0u : 1u;
        xil_printf("\r\n-- reading bank %d (ready=0x%x) --\r\n", (int)slot, (unsigned)ready);
        if (read_bank(slot, ch, &seq, &first, &len) != 0) return 1;

        xil_printf("  SEQ = ");
        put_dec(seq);
        xil_printf("   FIRST = ");
        put_dec(first);
        xil_printf("   LEN = ");
        put_dec(len);
        xil_printf("\r\n");

        for (c = 0; c < N_CH; c++) {
            xil_printf("  ch");
            put_dec(c);
            xil_printf(": min ");
            put_dec((uint32_t)(int32_t)ch[c].min);
            xil_printf("  max ");
            put_dec((uint32_t)(int32_t)ch[c].max);
            xil_printf("  mean ");
            put_dec((uint32_t)(int32_t)(ch[c].sum / (int32_t)ch[c].n));
            xil_printf("\r\n");
        }
    }

    frozen = Xil_In32(RV32_BASE + R_FROZEN) & ((1u << N_CH) - 1u);
    drop   = Xil_In32(RV32_BASE + R_DROP);

    xil_printf("\r\nFROZEN = 0x");
    put_hex32(frozen);
    xil_printf("\r\n");
    if (frozen == ((1u << N_CH) - 1u)) {
        xil_printf("  all 8 channels constant -- expected with no mics wired\r\n");
        xil_printf("  (the xdc pulldowns hold the lines at 0).\r\n");
    }
    /* One bit per CHANNEL, not per line: bit 2k = line k phase A (LR=GND),
     * bit 2k+1 = line k phase B (LR=VDD). This bitmap does not identify missing mics.
     * ⚠ FROZEN means "this channel's data is not changing", NOT "this mic is
     *   absent". Two known ways to get a false positive: (1) the IM73D122 outputs
     *   an alternating idle tone as its digital zero, which the CIC decimates to a
     *   constant; (2) on a shared line, an absent mic leaves its half-period
     *   floating, and the 100k pulldown is far too slow (RC ~5us vs a 200ns half
     *   period) to pull it to 0 -- so it may read the other mic's level and not
     *   freeze at all. Both are open measurements; see docs/pdm_array_spec.md P-12. */
    xil_printf("DROP   = ");
    put_dec(drop);
    xil_printf(" samples\r\n");

    /* How far the chain moved while we were reading. If DROP grows by roughly this much, the
     * capture is running but nobody is draining it fast enough -- which is the expected state
     * here, since this program reads a bank every few milliseconds and the chain makes one
     * sample every 25.6 us. */
    xil_printf("chain advanced ");
    put_dec(Xil_In32(RV32_BASE + R_FRAME) - started);
    xil_printf(" samples since enable\r\n");

    xil_printf("\r\nPDM_PS_DONE\r\n");
    return 0;
}
