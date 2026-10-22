"""从底板原理图 02_IO 页抽 J4（2x20，BANK13）与 J3 的逐针线序，并互相标定。

    python3 scripts/golden/extract_j4.py <底板原理图.pdf>

── 为什么不能按阅读顺序抽 ────────────────────────────────────────────────
`page.extract_text()` 按**书写顺序**吐字。原理图里针号和网络名是分两处画的，
书写顺序完全对不上，拼出来是一堆没有对应关系的词。必须先拿 (x, y)，再配。

── 为什么不能只按 y 就近配 ───────────────────────────────────────────────
网络名标签画在导线**上方**，不在针号同一水平线上。偏移量是本脚本**标定**出来的：
用 J3 上两行**已知**的线序（board_io.md，四来源确认过）反推偏移，
再用同一个偏移去配 J4。没有这一步，J4 整张表会整体错一行 —— 而这种错
**抽出来的表看起来完全正常**，只是排线全接错。

标定结果：标签 y ≈ 针号 y + 2.8（实测 J3.31/32 与 J3.33/34 两行都是 2.8）

── 抽出来的是什么、还欠什么 ──────────────────────────────────────────────
本脚本只给 **J4 针号 ↔ 网络名（B13_Lxx_P/N）**。
网络名 → IO 站点 → 封装脚 要靠核心板原理图的书签树，最后用
`scripts/check_pins.tcl` 拿 Vivado 器件数据收口。三条来源都要过。
"""
import sys

from pypdf import PdfReader

# 02_IO 页上这一段的 x 分列（实测）
COL_ODD_NET = (555.0, 580.0)
COL_EVEN_NET = (625.0, 645.0)
COL_ODD_PIN = (595.0, 605.0)
COL_EVEN_PIN = (605.0, 616.0)
COL_PWR_L = (515.0, 525.0)       # 电源针的网络名（GND）画得更靠左
COL_PWR_R = (670.0, 680.0)       # +3.3V / +5V 更靠右

# 两个连接器块的纵向范围（实测，见本文件头部的推导）
J4_Y = (100.0, 226.0)
J3_Y = (295.0, 322.0)

# 网络名标签相对针号行的偏移（标定值，别改 —— 改了整张表会错一行）
LBL_DY = 2.8
LBL_TOL = 1.6


def spans_of(page):
    out = []

    def v(t, cm, tm, fd, fs):
        s = t.strip()
        if s and len(s) < 40:
            out.append((round(tm[4], 1), round(tm[5], 1), s))
    page.extract_text(visitor_text=v)
    return out


def pick(sp, xr, y):
    return sorted([(yy, t) for x, yy, t in sp
                   if xr[0] <= x <= xr[1] and abs(yy - y) <= LBL_TOL])


def pin_rows(sp, yr):
    """找出所有「针号行」：同一 y 上同时有奇数针号和偶数针号。"""
    ys = {}
    for x, y, t in sp:
        if yr[0] <= y <= yr[1] and t.isdigit():
            for xr, side in ((COL_ODD_PIN, "o"), (COL_EVEN_PIN, "e")):
                if xr[0] <= x <= xr[1] and 1 <= int(t) <= 40:
                    ys.setdefault(round(y, 1), {})[side] = int(t)
    return [(y, d) for y, d in sorted(ys.items(), reverse=True)
            if "o" in d and "e" in d]


def net_at(sp, y):
    """针号行 y 对应的网络名：标签画在上方 LBL_DY 处。"""
    ly = y + LBL_DY
    o = pick(sp, COL_ODD_NET, ly)
    e = pick(sp, COL_EVEN_NET, ly)
    if not o and not e:                       # 电源针，标签与针号同高、更靠外
        o = pick(sp, COL_PWR_L, y)
        e = pick(sp, COL_PWR_R, y)
    return (o[0][1] if o else None, e[0][1] if e else None)


def build(sp, yr, name):
    rows = pin_rows(sp, yr)
    print("## %s（%d 个针号行）" % (name, len(rows)))
    print()
    print("| 针 | 网络名 | 针 | 网络名 |")
    print("|:--:|---|---|:--|")
    table = {}
    for y, d in rows:
        on, en = net_at(sp, y)
        table[d["o"]] = on
        table[d["e"]] = en
    for p in range(1, 41, 2):
        a = table.get(p, "**缺**")
        b = table.get(p + 1, "**缺**")
        print("| %d | `%s` | %d | `%s` |" % (p, a, p + 1, b))
    print()
    return table


def main():
    pdf = sys.argv[1]
    sp = spans_of(PdfReader(pdf).pages[1])       # 02_IO 是第 2 页

    j4 = build(sp, J4_Y, "J4（BANK13，2x20）")
    j3 = build(sp, J3_Y, "J3 下半截（用来标定）")

    # 标定自检：J3 这两行是四来源确认过的，对上才说明偏移量没错
    print("## 标定自检（J3 已知行）")
    ok = True
    for pin, want in ((31, "B34_L7_P"), (32, "B34_L7_N"),
                      (33, "B34_L5_N"), (34, "B34_L5_P"),
                      (35, "B34_L18_N"), (36, "B34_L18_P")):
        got = j3.get(pin)
        good = (got == want)
        ok = ok and good
        print("  J3.%-3d 期望 %-12s 实得 %-12s %s"
              % (pin, want, got, "OK" if good else "**不符**"))
    print()

    print("## J4 自检")
    prob = 0
    for p in range(1, 41):
        v = j4.get(p)
        if v is None:
            print("  针 %d 没抽到网络名" % p); prob += 1
    nets = [j4[p] for p in range(1, 41) if j4.get(p)]
    # 只查**信号**网络名的重复。电源针重复是正常的（37/39 都是 GND）——
    # 第一版把 GND 也算了进去，于是报了个假失败。
    sig = [n for n in nets if n.startswith(("B13_", "B34_"))]
    dup = sorted({n for n in sig if sig.count(n) > 1})
    if dup:
        print("  重复信号网络名: %s" % dup); prob += 1
    else:
        print("  信号网络名无重复 ✓")
    b13 = sorted(n for n in nets if n.startswith("B13_"))
    b34 = sorted(n for n in nets if n.startswith("B34_"))
    print("  Bank13 信号 %d 个 / Bank34 信号 %d 个 / 电源 %d 个"
          % (len(b13), len(b34), len([n for n in nets if not n.startswith(("B13_", "B34_"))])))
    print()
    if not ok:
        print("**标定不过 —— 偏移量不对，J4 那张表不可用，别拿去排线**")
        return 1
    if prob:
        print("**J4 自检不过（%d 项），别拿去排线**" % prob)
        return 1
    print("OK: 标定通过 + J4 40 针齐全无重复")
    return 0


if __name__ == "__main__":
    sys.exit(main())
