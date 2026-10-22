"""生成 J4 的**完整**接线表：J4 针号 → 网络名 → 封装脚。

    python3 scripts/golden/j4_table.py <底板原理图.pdf>

── 数据从哪来 ────────────────────────────────────────────────────────────
1. **针号 → 网络名**：scripts/golden/extract_j4.py 抽的（那一步先拿 J3 上六行
   已知线序标定过"标签画在针号上方 2.8 点"这个偏移，6/6 对上才开始用）。
   结果硬编码在下面的 J4 字典里，改那个文件就要同步这里。
2. **网络名 → 封装脚**：底板原理图 02_IO 页上 **J1/J2 两个核心板连接器**
   把封装脚直接印在网络名旁边（`B34_L9_N  U17  J1_40`）。
   本脚本按「同行、x 相邻」自动配对。**不需要跑 Vivado。**

── 为什么值得再抽一遍 ────────────────────────────────────────────────────
这是一条**独立于 Vivado 器件数据**的来源。board_io.md §4 的老规矩是
「四条来源互相印证」，因为任何单一来源都可能错配（那条档案里记过一次
`B35_IO0` 被跨单元误配到 `U1F`）。
本脚本抽出后应当与 `board_io.md` 已有的 J3 值逐个对上 —— 对不上就是有错。

⚠ 已知的语义（不是错误，但排线的人必须知道）：J4 的 Bank34 那几根网络
   **同时挂在板上的摄像头接口上**（邻域里是 CMOS_D1..D4 / CMOS_SDA/SCL）。
   用它们接阵列就**不能同时插摄像头** —— 与"要 J3 就不能用板载 RGB LCD"
   是同一类取舍。
"""
import re
import sys

from pypdf import PdfReader

PAGE = 1        # 02_IO

# J4 针号 → 网络名（由 extract_j4.py 抽出并标定，见 docs/issues/052）
J4 = {
    1: "B13_L6_N", 2: "B34_L1_P",
    3: "B13_L19_N", 4: "B13_L19_P",
    5: "B13_L11_N", 6: "B13_L11_P",
    7: "B13_L15_N", 8: "B13_L15_P",
    9: "B13_L17_P", 10: "B13_L17_N",
    11: "B13_L12_N", 12: "B13_L12_P",
    13: "B13_L22_N", 14: "B13_L22_P",
    15: "B13_L13_P", 16: "B13_L13_N",
    17: "B13_L14_P", 18: "B13_L14_N",
    19: "B13_L16_P", 20: "B13_L16_N",
    21: "B13_L21_P", 22: "B13_L21_N",
    23: "B13_L20_N", 24: "B13_L20_P",
    25: "B13_L18_N", 26: "B13_L18_P",
    27: "B34_L3_N", 28: "B34_L3_P",
    29: "B34_L11_P", 30: "B34_L11_N",
    31: "B34_L4_P", 32: "B34_L4_N",
    33: "B34_L8_P", 34: "B34_L8_N",
    35: "B34_L10_P", 36: "B34_L10_N",
    37: "GND", 38: "+3.3V", 39: "GND", 40: "+5V",
}

# 用 board_io.md / 厂商表已经确认过的值做自检 —— 抽错了这几行一定先炸
KNOWN = {
    "B34_L7_P": "Y16", "B34_L7_N": "Y17",     # J3.31/.32
    "B34_L18_N": "W16", "B34_L18_P": "V16",   # J3.35/.36
    "B34_L21_N": "V18", "B34_L21_P": "V17",   # J3.27/.28
    "B34_L12_N": "U19",                        # J3.5
    "B13_L6_N": "V5", "B13_L20_N": "Y13", "B13_L20_P": "Y12",   # 核心板 Bank13 页
}


def net_to_pin(pdf):
    sp = []

    def v(t, cm, tm, fd, fs):
        s = t.strip()
        if s and len(s) < 30:
            sp.append((round(tm[4], 1), round(tm[5], 1), s))
    PdfReader(pdf).pages[PAGE].extract_text(visitor_text=v)

    net_re = re.compile(r"^B(\d+)_L(\d+)_?([PN])_?$")
    pkg_re = re.compile(r"^[A-Z]{1,2}\d{1,2}$")
    nets = [(x, y, t) for x, y, t in sp if net_re.match(t)]
    pkgs = [(x, y, t) for x, y, t in sp if pkg_re.match(t)]

    out, amb = {}, []
    for nx, ny, nt in nets:
        c = sorted((abs(px - nx), pt) for px, py, pt in pkgs
                   if abs(py - ny) < 3.0 and abs(px - nx) < 35.0)
        if not c:
            continue
        if len(c) > 1 and c[1][0] - c[0][0] < 4.0:
            amb.append((nt, [x[1] for x in c[:3]]))
            continue
        out.setdefault(nt, set()).add(c[0][1])
    return out, amb


def main():
    pdf = sys.argv[1]
    m, amb = net_to_pin(pdf)

    # ── 自检 1：与已知值对照 ──────────────────────────────────────────────
    print("## 自检：与 board_io.md / 厂商表已知值对照")
    ok = True
    for net, want in sorted(KNOWN.items()):
        got = m.get(net)
        got = sorted(got)[0] if got and len(got) == 1 else ("/".join(sorted(got)) if got else "**没抽到**")
        good = (got == want)
        ok = ok and good
        print("  %-14s 期望 %-5s 实得 %-5s %s" % (net, want, got, "OK" if good else "**不符**"))
    print()

    multi = sorted(n for n in m if len(m[n]) > 1)
    if multi:
        print("** %d 个网络配到多个封装脚: %s" % (len(multi), multi[:8]))
        ok = False
    if amb:
        print("# 有歧义没敢配的 %d 个（不影响 J4：%s）"
              % (len(amb), [a[0] for a in amb][:6]))
    if not ok:
        print("\n**自检不过 —— 这张表不可用**")
        return 1

    rows, bad = [], 0
    for pin in range(1, 41):
        net = J4[pin]
        if net in ("GND", "+3.3V", "+5V"):
            rows.append((pin, net, "—", "电源/地"))
            continue
        v = m.get(net)
        if not v or len(v) != 1:
            rows.append((pin, net, "**未抽到**", ""))
            bad += 1
            continue
        rows.append((pin, net, sorted(v)[0], ""))

    print("## J4 完整接线表（2x20）")
    print()
    print("| 针 | 网络名 | 封装脚 | 备注 |")
    print("|:--:|---|---|---|")
    for pin, net, pkg, note in rows:
        print("| %d | `%s` | **%s** | %s |" % (pin, net, pkg, note))
    print()
    if bad:
        print("**%d 针没配上**" % bad)
        return 1
    n13 = sum(1 for p, n, _, _ in rows if n.startswith("B13_"))
    n34 = sum(1 for p, n, _, _ in rows if n.startswith("B34_"))
    print("OK: 40 针全配上 —— Bank13 %d 根，Bank34 %d 根，电源/地 %d 根"
          % (n13, n34, 40 - n13 - n34))
    return 0


if __name__ == "__main__":
    sys.exit(main())
