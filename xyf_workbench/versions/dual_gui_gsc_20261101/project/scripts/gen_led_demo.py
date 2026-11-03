#!/usr/bin/env python3
"""Generate the LED-chaser demo firmware: core-side MMIO 0x5000 drives the on-board LEDs
(the Navigator board has 3 PL LEDs).

Same encoder family as scripts/gen_tb_program.py; the difference is that this firmware has
branches and a back edge, so labels are resolved in two passes. Hand-computing branch
offsets is exactly where mistakes happen -- this file got one wrong itself: the offset of
`jal x0, loop` (-40) was hand-encoded as -36. The delay constant went the same way: when
`lui`+`addi` build a 32-bit immediate, `addi`'s 12-bit field is **sign-extended**, so taking
0xB40 yields -1216 rather than +2880, an actual delay off by 4096 (4,995,904 vs 5,000,000).
Both are now computed by the script instead of filled in by hand.

Firmware behaviour: a single 1 shifts left inside the low 3 bits (1->2->4), wrapping back to
bit0 once it falls off; each step is delayed by N cycles; one TOHOST write per full round acts
as a heartbeat -- `TOHOST_CNT` advancing is harder evidence that "the core is running" than
the LEDs are.

Two artifacts, matching two paths:
  * `sw/led_demo.h`   -- C header, used when the PS downloads the firmware through the AXI
    auto-increment window (the Zynq PS-PL path).
  * `sw/led_demo.hex` -- `$readmemh` image, baked into `ITCM_FILE` by the bare-PL top level.
    It must be padded to 4096 words (see the note in write_hex).

Usage:
    python3 scripts/gen_led_demo.py                          # write C header, 5e6-cycle delay
    python3 scripts/gen_led_demo.py --hex sw/led_demo.hex    # also write the ITCM image
    python3 scripts/gen_led_demo.py --delay 8 --hex sw/led_demo_tb.hex --no-header
                                                            # short-delay image for the TB
    python3 scripts/gen_led_demo.py --check                  # self-check only, write nothing

Convention: anything printed to the console is ASCII only -- the Windows console decodes as
cp936 and mangles non-ASCII (comments are free to be whatever).
"""

import argparse
import os
import sys

# -- encoders -----------------------------------------------------------------
def R(f7, rs2, rs1, f3, rd, op): return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def I(imm, rs1, f3, rd, op):     return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def S(imm, rs2, rs1, f3, op):
    i = imm & 0xFFF
    return ((i >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((i & 0x1F) << 7) | op
def B(imm, rs2, rs1, f3, op):
    i = imm & 0x1FFF
    return (((i >> 12) & 1) << 31) | (((i >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((i >> 1) & 0xF) << 8) | (((i >> 11) & 1) << 7) | op
def J(imm, rd, op):
    i = imm & 0x1FFFFF
    return (((i >> 20) & 1) << 31) | (((i >> 1) & 0x3FF) << 21) | (((i >> 11) & 1) << 20) | \
           (((i >> 12) & 0xFF) << 12) | (rd << 7) | op

LUI  = lambda rd, i:    (i << 12) | (rd << 7) | 0x37
ADDI = lambda rd, rs1, i: I(i, rs1, 0, rd, 0x13)
SLLI = lambda rd, rs1, s: I(s, rs1, 1, rd, 0x13)
ANDI = lambda rd, rs1, i: I(i, rs1, 7, rd, 0x13)
SW   = lambda rs2, off, rs1: S(off, rs2, rs1, 2, 0x23)
BNE  = lambda a, b, imm: B(imm, b, a, 1, 0x63)
JAL  = lambda rd, imm: J(imm, rd, 0x6F)

LED_BASE     = 0x5000
TOHOST_BASE  = 0x4000
LED_MASK     = 0x7          # 3 PL LEDs on the Navigator board, so 3 bits not 4
ITCM_WORDS   = 4096         # matches the rv32_itcm WORDS default


def split_imm32(value):
    """Split 0..0xFFFFFFFF into (lui's 20 bits, addi's signed 12-bit field).

    addi's immediate is sign-extended, so once the low 12 bits reach >= 0x800 a 1 has to be
    borrowed from the high half, otherwise the addition turns into a subtraction. This is the
    easiest step to get wrong, hence a function of its own.
    """
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError("value out of 32-bit range: %d" % value)
    hi = (value >> 12) & 0xFFFFF
    lo = value & 0xFFF
    if lo >= 0x800:          # sign-extends to a negative; borrow one from hi
        lo -= 0x1000
        hi = (hi + 1) & 0xFFFFF
    return hi, lo


def build(delay):
    """Return [(word, asm-text)]. First pass fixes labels, second back-fills the offsets."""
    d_hi, d_lo = split_imm32(delay)

    prog = [
        (None,    "lui   x10, 0x%X" % (LED_BASE >> 12),   lambda L: LUI(10, LED_BASE >> 12)),
        (None,    "lui   x5, 0x%X" % (TOHOST_BASE >> 12), lambda L: LUI(5, TOHOST_BASE >> 12)),
        (None,    "addi  x6, x0, 1",                      lambda L: ADDI(6, 0, 1)),
        (None,    "addi  x8, x0, 1",                      lambda L: ADDI(8, 0, 1)),
        ("loop",  "sw    x6, 0(x10)",                     lambda L: SW(6, 0, 10)),
        (None,    "lui   x7, 0x%X" % d_hi,                lambda L: LUI(7, d_hi)),
        (None,    "addi  x7, x7, %d" % d_lo,              lambda L: ADDI(7, 7, d_lo)),
        ("delay", "addi  x7, x7, -1",                     lambda L: ADDI(7, 7, -1)),
        (None,    "bne   x7, x0, delay",                  lambda L: BNE(7, 0, (L["delay"] - 8) * 4)),
        (None,    "slli  x6, x6, 1",                      lambda L: SLLI(6, 6, 1)),
        (None,    "andi  x6, x6, 0x%X" % LED_MASK,        lambda L: ANDI(6, 6, LED_MASK)),
        (None,    "bne   x6, x0, loop",                   lambda L: BNE(6, 0, (L["loop"] - 11) * 4)),
        (None,    "addi  x6, x0, 1",                      lambda L: ADDI(6, 0, 1)),
        (None,    "sw    x8, 0(x5)",                      lambda L: SW(8, 0, 5)),
        (None,    "jal   x0, loop",                       lambda L: JAL(0, (L["loop"] - 14) * 4)),
    ]

    labels = {}
    for idx, (lab, _, _) in enumerate(prog):
        if lab:
            labels[lab] = idx
    return [(fn(labels) & 0xFFFFFFFF, asm) for _, asm, fn in prog]


# -- self-check ---------------------------------------------------------------
def check_delay_constant(delay):
    """Verify that the lui/addi pair really rebuilds `delay`.

    Not verified by running the interpreter: a 5e6-cycle delay loop would take 5e6 steps to
    produce anything, and computing it directly is both faster and exact.
    """
    hi, lo = split_imm32(delay)
    got = ((hi << 12) + lo) & 0xFFFFFFFF
    if got != delay:
        return "delay constant does not rebuild: lui 0x%X + addi %d = %d, want %d" % (hi, lo, got, delay)
    return None


def check_flow(delay=8, steps=20000):
    """Run the machine code under a tiny delay and verify control flow, bit rotation, heartbeat.

    This firmware is the only part not covered by a testbench (the real delay is far too long
    to fit inside the simulation's 20000-cycle window), and a wrong bit-rotation or branch
    offset is extremely hard to chase down on the board -- so these few dozen lines earn their
    keep. Control flow does not depend on the delay constant, so the short-delay build is
    enough.
    """
    words = [w for w, _ in build(delay)]
    regs = [0] * 32
    pc = 0
    led_seq, heartbeats = [], 0

    def wreg(r, v):
        # x0 is hard-wired to zero and must not be written. Not fussiness: the firmware jumps
        # with `jal x0, loop`, and if the return address landed in x0 then the later
        # `bne x7, x0` could never compare against zero and the delay loop would run away
        # (the first version of this file fell into exactly that; --check exists for it).
        if r != 0:
            regs[r] = v & 0xFFFFFFFF

    for _ in range(steps):
        if pc % 4 or pc // 4 >= len(words):
            return "PC ran outside the program: 0x%X" % pc
        w = words[pc // 4]
        op = w & 0x7F
        rd = (w >> 7) & 0x1F
        f3 = (w >> 12) & 7
        rs1 = (w >> 15) & 0x1F
        rs2 = (w >> 20) & 0x1F
        nxt = pc + 4
        if op == 0x37:                                   # lui
            wreg(rd, w & 0xFFFFF000)
        elif op == 0x13 and f3 == 0:                     # addi
            imm = (w >> 20) & 0xFFF
            wreg(rd, regs[rs1] + (imm - 0x1000 if imm >= 0x800 else imm))
        elif op == 0x13 and f3 == 1:                     # slli
            wreg(rd, regs[rs1] << ((w >> 20) & 0x1F))
        elif op == 0x13 and f3 == 7:                     # andi
            imm = (w >> 20) & 0xFFF
            wreg(rd, regs[rs1] & (imm - 0x1000 if imm >= 0x800 else imm))
        elif op == 0x23 and f3 == 2:                     # sw
            imm = (((w >> 25) << 5) | ((w >> 7) & 0x1F))
            imm = imm - 0x1000 if imm >= 0x800 else imm
            addr = (regs[rs1] + imm) & 0xFFFFFFFF
            if addr == LED_BASE:
                led_seq.append(regs[rs2] & LED_MASK)
            elif addr == TOHOST_BASE:
                heartbeats += 1
        elif op == 0x63 and f3 == 1:                     # bne
            # B-type immediate reassembly: imm[12]=bit31, imm[10:5]=bits30:25,
            # imm[4:1]=bits11:8, imm[11]=bit7. That last one shifts left by 11; drop it and
            # the offset comes out as nonsense like 0x17FD (the first version dropped it).
            i = (((w >> 31) & 1) << 12) | (((w >> 25) & 0x3F) << 5) | \
                (((w >> 8) & 0xF) << 1) | (((w >> 7) & 1) << 11)
            i = i - 0x2000 if i >= 0x1000 else i
            if regs[rs1] != regs[rs2]:
                nxt = (pc + i) & 0xFFFFFFFF
        elif op == 0x6F:                                 # jal
            i = (((w >> 31) & 1) << 20) | (((w >> 21) & 0x3FF) << 1) | \
                (((w >> 20) & 1) << 11) | (((w >> 12) & 0xFF) << 12)
            i = i - 0x200000 if i >= 0x100000 else i
            wreg(rd, nxt)
            nxt = (pc + i) & 0xFFFFFFFF
        else:
            return "unknown instruction 0x%08X @ +%d" % (w, pc)
        pc = nxt
        if len(led_seq) >= 12 and heartbeats >= 2:
            break

    want = [1, 2, 4, 1, 2, 4, 1, 2, 4, 1]
    if led_seq[:len(want)] != want:
        return "LED sequence mismatch: want %s, got %s" % (want, led_seq[:len(want)])
    if heartbeats < 2:
        return "heartbeat written only %d time(s), want >= 2" % heartbeats
    return None


def write_hex(path, words):
    """Write the $readmemh image, padded out to the full ITCM size.

    Padding is a hard requirement, not cosmetics: rv32_itcm is a 4096-word array, and feeding
    it only a dozen-odd lines leaves every other word as X, which synthesis treats as
    don't-care -- equivalent to not preloading at all, and the core gets optimised away
    (measured: 98 flip-flops against 4330). So fill the rest with NOPs.
    """
    if len(words) > ITCM_WORDS:
        raise ValueError("firmware is %d words, over ITCM's %d words" % (len(words), ITCM_WORDS))
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fp:
        for w in words:
            fp.write("%08X\n" % w)
        for _ in range(ITCM_WORDS - len(words)):
            fp.write("00000013\n")          # NOP padding
    return ITCM_WORDS


def main():
    ap = argparse.ArgumentParser(description="generate the LED-chaser demo firmware")
    ap.add_argument("--delay", type=int, default=5000000, help="cycles per step, default 5e6 (about 0.2 s at 50MHz)")
    ap.add_argument("--check", action="store_true", help="run the self-check only, write no files")
    ap.add_argument("--out", default=os.path.join("sw", "led_demo.h"), help="output header path")
    ap.add_argument("--hex", default=None, help="also write the $readmemh image (padded to 4096 words)")
    ap.add_argument("--no-header", action="store_true", help="skip the C header (hex-only runs)")
    args = ap.parse_args()

    words = build(args.delay)

    print("# LED-chaser firmware: %d instructions, %d cycles per step" % (len(words), args.delay))
    for i, (w, asm) in enumerate(words):
        print("    [%2d] %08X  %s" % (i, w, asm))

    problem = check_delay_constant(args.delay) or check_flow()
    if problem:
        print("\nself-check FAILED: %s" % problem)
        return 1
    print("\nself-check PASSED: delay constant rebuilds exactly; control flow reaches the "
          "1->2->4 LED sequence and the heartbeat advances once per round")

    if args.check:
        return 0

    if args.hex:
        n = write_hex(args.hex, [w for w, _ in words])
        print("wrote %s (%d instructions, NOP-padded to %d words)" % (args.hex, len(words), n))

    if args.no_header:
        return 0

    out = args.out
    if os.path.dirname(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fp:
        fp.write("/* Generated by scripts/gen_led_demo.py -- do not hand-edit.\n")
        fp.write(" * LED-chaser firmware: core-side MMIO 0x5000 drives the on-board LEDs,\n")
        fp.write(" * %d cycles of delay per step, one TOHOST write per round as a heartbeat.\n" % args.delay)
        fp.write(" * To change the delay, re-run the generator; do not edit this file.\n")
        fp.write(" * PS-side usage: soft reset -> push led_demo[] into ITCM through the\n")
        fp.write(" * MEM_ADDR/MEM_WDATA auto-increment window -> write CTRL to clear HALT.\n")
        fp.write(" * See README, section \"MMIO (core-side address space)\".\n */\n\n")
        fp.write("#ifndef LED_DEMO_H\n#define LED_DEMO_H\n\n")
        fp.write("#include <stdint.h>\n\n")
        fp.write("#define LED_DEMO_WORDS %d\n\n" % len(words))
        fp.write("static const uint32_t led_demo[LED_DEMO_WORDS] = {\n")
        for w, asm in words:
            fp.write("    0x%08X,  /* %s */\n" % (w, asm))
        fp.write("};\n\n#endif /* LED_DEMO_H */\n")
    print("wrote %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
