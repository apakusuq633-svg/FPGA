"""从底板原理图 02_IO 页抽「网络名 → 封装脚」，作为 Vivado 器件数据之外的第二来源。

    python3 scripts/golden/net_to_pin.py <底板原理图.pdf>

底板那张图上，J1/J2 两个核心板连接器**把封装脚直接印在网络名旁边**：

    B34_L9_N   U17   J1_40
    B34_L7_N   Y17   J1_39
    B35_L14_P  J18   J2_25

所以不必等 Vivado 也能拿到映射 —— 而且**两条独立来源**能互相对照
（`board_io.md` §4 的老规矩：四来源互相印证）。

判据：网络名 `B<bank>_L<n>_<P|N>` 与一个 `^[A-Z]{1,2}\d{1,2}$` 的封装脚令牌
**在同一行（y 差 < 3）且 x 差 < 30**。两点都卡上才算一对，否则宁可漏也不猜。
"""
import re
import sys

from pypdf import PdfReader

PAGE = 1        # 02_IO


def main():
    pdf = sys.argv[1]
    sp = []

    def v(t, cm, tm, fd, fs):
        s = t.strip()
        if s and len(s) < 30:
            sp.append((round(tm[4], 1), round(tm[5], 1), s))
    PdfReader(pdf).pages[PAGE].extract_text(visitor_text=v)

    net_re = re.compile(r"^B(\d+)_L(\d+)_?([PN])_?$")
    pkg_re = re.compile(r"^[A-Z]{1,2}\d{1,2}$")

    nets = [(x, y, net_re.match(t)) for x, y, t in sp if net_re.match(t)]
    pkgs = [(x, y, t) for x, y, t in sp if pkg_re.match(t)]

    found = {}
    ambiguous = []
    for nx, ny, m in nets:
        cands = [(abs(px - nx), pt) for px, py, pt in pkgs
                 if abs(py - ny) < 3.0 and abs(px - nx) < 30.0]
        if not cands:
            continue
        cands.sort()
        name = m.group(0)
        best = cands[0][1]
        # 次近的也明显合理 ⇒ 这一行有歧义，不猜
        if len(cands) > 1 and cands[1][0] - cands[0][0] < 4.0:
            ambiguous.append((name, [c[1] for c in cands[:3]]))
            continue
        found.setdefault(name, set()).add(best)

    print("## 底板原理图：网络名 → 封装脚（%d 个网络）" % len(found))
    print()
    print("| 网络名 | 封装脚 |")
    print("|---|---|")
    for n in sorted(found, key=lambda s: (s.split("_")[0], int(s.split("_")[1][1:]), s)):
        vals = sorted(found[n])
        mark = "" if len(vals) == 1 else " ⚠"
        print("| `%s` | **%s**%s |" % (n, " / ".join(vals), mark))
    print()
    if ambiguous:
        print("## 有歧义、没敢配的（%d 个）" % len(ambiguous))
        for n, c in sorted(ambiguous):
            print("  %-12s 候选 %s" % (n, c))
        print()
    multi = [n for n in found if len(found[n]) > 1]
    if multi:
        print("** %d 个网络配到了多个封装脚（表上有 ⚠）—— 说明配对规则在这几行不成立" % len(multi))
        return 1
    print("OK: %d 个网络各配到唯一封装脚" % len(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
