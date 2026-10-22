"""VFFT 地址发生器的参照 —— 逐拍列出 9 级 2304 个蝶形该读哪些地址。

为什么地址发生器先做
--------------------
蝶形本身只是「读两条、复乘、加/减、写回两条」。真正难的是**地址**：
DIT 的 a 与 b 相差 half，half 从 1 变到 256；twiddle 下标按 step 跳。
地址错了不会报错，只会算出一个**看起来像频谱的东西**。

所以先把它单独拿出来，对着这份枚举逐拍比 —— 2304 个蝶形一个不差，
才有资格往下写数据通路。

结构（与 sw/fw/fw_fft.c 一字不差，这样硬件结果能直接对固件那份 golden）
--------------------------------------------------------------------
    for len = 2,4,...,512:                # 9 级，stage = log2(len)-1
        half = len/2
        for 组: 每 8 个蝶形一组（k = 组内线性序号 0..255）
            a = start + j,  b = a + half
            tw = j * (1024/len)

两种取数模式
------------
`len >= 16`（stage >= 3）：a 的 8 条是连续地址、b 的 8 条也是 —— 正好 8 个 bank
    各出 2 条（2 读口），**一拍 8 个蝶形**。
`len <= 8`（stage <= 2）：a 自身跨步（步长 half < 8），8 条 a 会落在同一批 bank 上。
    改成**一拍读 8 条连续、做 4 个蝶形**，一组用两拍 —— 只占 9 级里的 3 级。

    ⚠ 不做 lane↔bank 的交叉开关：那是一个 16×16 的 32 位网络，LUT 代价比
      多花 96 拍大得多。**固定接线 + 小 len 两拍**是这里的取舍。

输出（build/fft_addr_ref.hex，每拍一行）
    {n_bfly[2:0], pad, tw[3][9:0], b_lane[3][2:0], a_lane[3][2:0], rd[7:0]...}
    这里按**可读**的方式写：每拍 8 个读地址 + 最多 4 个蝶形的 (a_lane,b_lane,tw)。
"""
import os
import sys

import numpy as np

M = 512
NSTAGE = 9
LANES = 8

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "build")


def mode_of(stage):
    """stage >= 3 一拍 8 个蝶形；stage <= 2 一拍 4 个（两拍一组）。"""
    return 8 if stage >= 3 else 4


def cycle_list():
    """返回每一拍的取数与蝶形表。

    两种模式（见模块头）：
      mode 8（stage >= 3）：读**两个** 8 字窗口 —— A 窗放 a、B 窗放 b，
          窗 B = 窗 A + half。两窗都 8 对齐，所以 lane l ↔ bank l 直接成立。
      mode 4（stage <= 2）：只读**一个** 8 字窗口，a 与 b 都在里面，
          一拍做 4 个蝶形（一组两拍）。

    返回 [(stage, grp, ph, wa, wb, [(a_lane, b_lane, tw), ...])]
      wb = -1 表示 mode 4（没有第二个窗口）。
    """
    out = []
    for stage in range(NSTAGE):
        length = 1 << (stage + 1)
        half = length >> 1
        step = (M // length) * 2
        nbf = mode_of(stage)
        ngrp = (M // 2) // 8        # 组永远是 8 个蝶形：mode 4 只是把它拆成两拍
        nph = 1 if nbf == 8 else 2
        for grp in range(ngrp):
            for ph in range(nph):
                k0 = grp * 8 + ph * 4
                bfs = []
                if nbf == 8:
                    j0 = k0 % half
                    wa = (k0 // half) * length + j0
                    wb = wa + half
                    for l in range(8):
                        bfs.append((l, l, (j0 + l) * step))
                else:
                    base = ((k0 * 2) // length) * length
                    wa, wb = base, -1
                    for pp in range(4):
                        k = k0 + pp
                        start = (k // half) * length
                        j = k % half
                        a = start + j
                        b = a + half
                        bfs.append((a - base, b - base, j * step))
                out.append((stage, grp, ph, wa, wb, bfs))
    return out


def main():
    cycles = cycle_list()
    print("=" * 74)
    print("VFFT 地址发生器参照（M=%d，9 级，%d 拍）" % (M, len(cycles)))
    print("=" * 74)

    n_bf = sum(len(c[5]) for c in cycles)
    print("  总拍数 %d，其中蝶形 %d 个（应为 %d）" % (len(cycles), n_bf, 9 * 256))
    assert n_bf == 9 * 256, "蝶形总数不对"

    print("\n  各级拍数：")
    for stage in range(NSTAGE):
        cs = [c for c in cycles if c[0] == stage]
        print("     len=%-4d 模式 %d 蝶形/拍  %d 拍"
              % (1 << (stage + 1), mode_of(stage), len(cs)))

    # 每一拍：lane↔bank 固定接线要求每个 lane 的下标都落在自己那个 bank 上。
    # bank = 下标 mod 8，lane l 读 bank l ⇒ 窗口必须 8 对齐。
    bad = 0
    for (stage, grp, ph, wa, wb, bfs) in cycles:
        if wa % 8 != 0:
            bad += 1
        if wb >= 0 and wb % 8 != 0:
            bad += 1
        if wb >= 0 and wb != wa + (1 << stage):
            bad += 1
        for (al, bl, tw) in bfs:
            if not (0 <= al < 8 and 0 <= bl < 8):
                bad += 1
            if not (0 <= tw <= 511):
                bad += 1
    print("\n  窗口对齐 / lane 范围检查：%s"
          % ("全部通过 ✓" if bad == 0 else "%d 处异常 ✗" % bad))
    assert bad == 0, "lane↔bank 固定接线的前提不成立"

    # 覆盖性：9 级里每个蝶形恰好被处理一次
    seen = np.zeros((NSTAGE, 256), dtype=int)
    for (stage, grp, ph, wa, wb, bfs) in cycles:
        for pp in range(len(bfs)):
            seen[stage, grp * 8 + ph * 4 + pp] += 1
    assert (seen == 1).all(), "有蝶形被漏掉或重复"
    print("  覆盖性检查：9 级 × 256 个蝶形，每个恰好一次 ✓")

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "fft_addr_ref.hex")
    with open(path, "w") as f:
        for (stage, grp, ph, wa, wb, bfs) in cycles:
            f.write("%08x\n" % ((stage << 28) | (grp << 22) | (ph << 20)
                                 | (max(wb, 0) << 9) | wa))
            for pp in range(8):                 # 每拍恒 8 行，未用的补 0
                if pp < len(bfs):
                    al, bl, tw = bfs[pp]
                    f.write("%08x\n" % ((al << 13) | (bl << 10) | tw))
                else:
                    f.write("%08x\n" % 0)
    print("\n  参照 -> %s（每拍 9 行：1 行头 + 8 行蝶形）" % path)

    # ── 旋转因子 ROM：硬件与固件必须用**同一份**表，否则逐位比无从谈起 ──
    from fw_fft_model import twiddle_q14
    re_t, im_t = twiddle_q14()
    tw_path = os.path.join(OUT, "fft_tw.hex")
    with open(tw_path, "w") as f:
        for k in range(512):          # 蝶形只用到偶数下标（j*step*2 ≤ 510）
            w = ((int(im_t[k]) & 0xFFFF) << 16) | (int(re_t[k]) & 0xFFFF)
            f.write("%08x\n" % w)
    print("  旋转因子 ROM -> %s（512 条 Q14，与 sw/fw/fw_tables.c 同源）" % tw_path)

    # ── 输入帧：与固件 make_frame() 一字不差的三角波 + LCG 噪声 ────────
    # 三方（固件 / Python 模型 / TB）共用，硬件也用同一份。
    LCG_A, LCG_C, LCG_SEED = 1103515245, 12345, 0x12345678
    s = LCG_SEED
    frame = []
    for i in range(M * 2):
        s = (s * LCG_A + LCG_C) & 0xFFFFFFFF
        noise = (s >> 16) & 0x3FFF
        ph = i % 64
        tri = ph * 1024 - 16384 if ph < 32 else 49152 - ph * 1024
        frame.append((tri + (noise - 8192)) & 0xFFFF)
    fr_path = os.path.join(OUT, "fft_frame.hex")
    with open(fr_path, "w") as f:
        for i in range(M):            # 打包好的 512 条复数，每条一个 32 位字
            f.write("%08x\n" % ((frame[2 * i + 1] << 16) | frame[2 * i]))
    print("  输入帧 -> %s（512 条复数，{im, re} 打包）" % fr_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
