"""FFT 蝶形的访存模式分析 —— 写 RTL 之前必须先做的一步。

为什么先做这个
--------------
标量 FFT 的蝶形是「读两个点、算、写回两个点」。做成 8 lane 一条指令之后，
**一拍要同时取到 8 个 a 和 8 个 b**（共 16 条复数）。这 16 条落在哪些 bank 上，
决定了「一拍能不能取完」—— 取不完就要多拍，多拍就把加速比吃掉。

而蝶形的地址是**跨步**的（a 与 b 相差 half，twiddle 按 step 跳），
跨步与 bank 划分一撞就是冲突。**这一条量不清楚，RTL 写出来也是白写。**

本脚本枚举 9 级里全部 2304 个蝶形，按候选 bank 方案统计每拍的最大访问数，
给出「哪些级冲突、冲突多少」。

FFT 结构（与 sw/fw/fw_fft.c 一字不差）
--------------------------------------
    z[0..511] 复数（实数 FFT 打包后的 N/2 点复序列）
    for len = 2,4,...,512:            # 9 级
        half = len/2
        for start = 0, len, 2len, ...: # M/len 组
            for j = 0 .. half-1:
                a = z[start+j]
                b = z[start+half+j]
                w = TW[j * (M/len) * 2]
                z[start+j]        = (a + w·b) >> 1
                z[start+half+j]   = (a - w·b) >> 1
每级 256 个蝶形。
"""
import os
import sys

import numpy as np

M = 512          # 复数点数
NSTAGE = 9
LANES = 8


def butterflies():
    """按 (级, 线性序号) 枚举全部蝶形，返回每级的 (a 下标, b 下标, tw 下标)。"""
    stages = []
    length = 2
    while length <= M:
        half = length >> 1
        step = (M // length) * 2          # twiddle 下标步长（表是 W_1024^k）
        a_idx, b_idx, tw_idx = [], [], []
        for start in range(0, M, length):
            for j in range(half):
                a_idx.append(start + j)
                b_idx.append(start + half + j)
                tw_idx.append(j * step)
        stages.append((length, half, np.array(a_idx), np.array(b_idx),
                       np.array(tw_idx)))
        length <<= 1
    return stages


def cycles_per_stage(a_idx, b_idx, nbank, ports):
    """一条指令处理 LANES 个蝶形时，每级需要几拍。

    ⚠ 「每 bank 一次读两条」和「每 bank 两个读口」在硬件上**完全不同**：
      前者要求那两条在 bank 自己的地址空间里**相邻**（a 与 b 相差 half，
      不相邻，做不到）；后者才允许同拍取任意两个地址。
      所以这里按**端口数**建模，不按字宽。

    一次蝶形要读 2 条（a、b）写 2 条。读写各自统计每个 bank 的访问次数，
    再按端口数取拍数，取读写中较大的那个。
    """
    n = len(a_idx)
    worst = 0
    for s in range(0, n, LANES):
        rd = np.zeros(nbank, dtype=int)
        wr = np.zeros(nbank, dtype=int)
        for arr in (a_idx[s:s + LANES], b_idx[s:s + LANES]):
            for i in arr:
                rd[int(i) % nbank] += 1
                wr[int(i) % nbank] += 1        # 写回同一批地址
        worst = max(worst, int(np.ceil(rd.max() / ports)),
                    int(np.ceil(wr.max() / ports)))
    return worst


def main():
    stages = butterflies()

    print("=" * 78)
    print("FFT 蝶形访存模式分析（M=%d 复数，%d 级，每级 %d 个蝶形）"
          % (M, NSTAGE, M // 2))
    print("=" * 78)

    # ── ① 每级的地址跨度 ────────────────────────────────────────────
    print("\n① 每级的访存特征")
    print("  %-6s %-6s %-8s %-28s %s" % ("len", "half", "tw步长", "a 的步长", "a/b 是否连续"))
    for (length, half, a, b, tw) in stages:
        da = np.diff(a)
        cont = ("连续" if (da == 1).all() else
                "跨 %d" % da[0] if (da == da[0]).all() else "混")
        print("  %-6d %-6d %-8d %-28s %s"
              % (length, half, (M // length) * 2, str(sorted(set(da.tolist()))), cont))

    # ── ② 候选 bank 方案的冲突统计 ──────────────────────────────────
    print("\n② 候选 bank 方案：每级需要几拍（%d lane 一条指令，一次蝶形读写各 2 条）"
          % LANES)
    cands = [("8 bank × 1 读口 1 写口", 8, 1),
             ("16 bank × 1 读口 1 写口", 16, 1),
             ("8 bank × 2 读口 2 写口", 8, 2)]
    hdr = "  %-30s" % "方案"
    for (length, *_rest) in stages:
        hdr += " %5d" % length
    print(hdr)
    for (name, nb, w) in cands:
        row = "  %-30s" % name
        tot = 0
        for (length, half, a, b, tw) in stages:
            c = cycles_per_stage(a, b, nb, w)
            tot += c * (M // 2 // LANES)
            row += " %5d" % c
        print(row + "   (整轮取数 %d 拍)" % tot)

    # ── ③ 为什么大 half 会撞 ────────────────────────────────────────
    print("\n③ 冲突的来处：a 与 b 的 bank 集合是否重叠")
    print("  %-6s %-8s %s" % ("len", "half", "a 的 bank 集合 vs b 的 bank 集合"))
    NB = 8
    for (length, half, a, b, tw) in stages:
        # 取第一条指令那一组
        sa = set((int(x) % NB) for x in a[:LANES])
        sb = set((int(x) % NB) for x in b[:LANES])
        ov = sa & sb
        print("  %-6d %-8d %s vs %s  %s"
              % (length, half, sorted(sa), sorted(sb),
                 "无重叠 ✓" if not ov else "重叠 %s ✗" % sorted(ov)))

    print("""
读法
----
· `len ≥ 16`（half ≥ 8）时 a 与 b 都是 8 条**连续**地址，bank 集合互补 ——
  但**两次读之间不冲突**只说明「8 条 a 内部不冲突」，还需要 a 与 b
  能**同拍**取到，也就是每 bank 要有两个读口。
· `len = 2/4/8` 时 a 本身就不连续（步长 2/2/4），8 条 a 会撞在同一批 bank 上。

结论与方案见文末的打印。
""")

    # ── ④ 结论：需要什么 ────────────────────────────────────────────
    print("=" * 78)
    print("结论")
    print("=" * 78)
    for (name, nb, ports) in cands:
        worst = max(cycles_per_stage(a, b, nb, ports) for (_, _, a, b, _) in stages)
        tot = sum(cycles_per_stage(a, b, nb, ports) * (M // 2 // LANES)
                  for (_, _, a, b, _) in stages)
        print("  %-28s 最坏 %d 拍/组，9 级合计 %d 拍" % (name, worst, tot))
    print("""
  ⇒ 只有「8 bank × 每 bank 2 读口 2 写口」能全级 1 拍/组。两条路：

  A. **8 bank，每 bank 2 读口 2 写口** —— 9 级全部 1 拍/组（上表已验证）。
     注意不是「每 bank 存两条」：那要求两条在 bank 自己的地址空间里相邻，
     而 a 与 b 相差 half、**不相邻**，做不到。必须是真·两个独立读口。

  B. **换架构：不做随机访问的蝶形指令，做流水线 FFT**（R2SDF 那一类）——
     每级自带一条 FIFO，顺序读写，**天然无冲突、连地址发生器都不需要**。
     代价：它是固定功能通路（就是前面说的"退路"），核不再参与运算。

  **下一步该做的是 A 的 RTL**，但先把这张表跑出来 —— 它决定了 bank 的宽度
  和读口数，是后面所有事的前提。""")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
