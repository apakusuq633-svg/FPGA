"""从核心板原理图抽某个 BANK 页的「网络名 → IO 站点 → 封装脚」。

    python3 scripts/golden/extract_bank_pins.py <核心板原理图.pdf> <bank>

bank: 13 或 34/35（页面见下表）
    02_FPGA Bank0        p1
    03_FPGA Bank34,Bank35 p2
    06_Bank_13           p5

── 两个坑（在 06_Bank_13 上实测的，Bank34/35 页同型）──────────────────────
1. 网络名与 IO 站点名都是**竖排**（整列 y 相同）⇒ 只能用 x 配对。
2. **IO 站点名与封装脚在 PDF 里是两段**：`IO_L20N_T3_13` + `Y13`。
   `extract_text()` 会粘成 `IO_L20N_T3_13Y13`，带 visitor 的抽取不粘。
3. **封装脚不能用最近邻配**：它相对站点名有个固定 x 偏移（Bank13 页实测 −4.5），
   而相邻站点间距只有 7.2 —— 最近邻会把每格都挑到隔壁，整表错一位且**看着正常**。
   正确做法：两组按 x 排序后逐一对齐，再用"偏移是否恒定"自检。
"""
import re
import sys

from pypdf import PdfReader

PAGES = {"13": 5, "34": 2, "35": 2}


def spans_of(pdf, page):
    out = []

    def v(t, cm, tm, fd, fs):
        s = t.strip()
        if s:
            out.append((round(tm[4], 1), round(tm[5], 1), s))
    PdfReader(pdf).pages[page].extract_text(visitor_text=v)
    return out


def main():
    pdf, bank = sys.argv[1], sys.argv[2]
    page = PAGES[bank]
    sp = spans_of(pdf, page)

    net_re = re.compile(r"^B%s_(L\d+)_?([PN])_?$" % bank)
    site_re = re.compile(r"^IO_(L\d+[PN])_[A-Z0-9_]*_%s$" % bank)
    pkg_re = re.compile(r"^([A-Z]{1,2}\d{1,2})$")

    nets, sites, pkgs = [], [], []
    for x, y, t in sp:
        if net_re.match(t):
            nets.append((x, y, t))
        elif site_re.match(t):
            sites.append((x, y, t, site_re.match(t).group(1)))
        elif pkg_re.match(t):
            pkgs.append((x, y, t))

    if not nets or not sites:
        print("FAIL: bank %s 网络名 %d / 站点 %d —— 没抽到" % (bank, len(nets), len(sites)))
        return 1

    # 封装脚只留站点名下面那一行的（否则页码/图框字母会被 ^[A-Z]{1,2}\\d{1,2}$ 抓进来）
    ysite = max(s[1] for s in sites)
    x0 = min(s[0] for s in sites) - 20
    x1 = max(s[0] for s in sites) + 20
    pkgs = [(x, y, t) for x, y, t in pkgs if ysite - 25 <= y <= ysite and x0 <= x <= x1]

    nets.sort(); sites.sort(); pkgs.sort()
    net_by_x = {round(x, 1): t for x, y, t in nets}

    rows = []
    for sx, sy, st, io in sites:
        nt = net_by_x.get(round(sx, 1))
        if nt is None:
            print("  ** 站点 %s (x=%.1f) 没有同 x 的网络名" % (st, sx))
            continue
        rows.append([nt, io, None, sx])

    if len(pkgs) != len(rows):
        print("  ** 封装脚 %d 个 vs 行 %d 个，数量对不上，不能按序配" % (len(pkgs), len(rows)))
        return 1
    offs = []
    for r, (px, py, pt) in zip(rows, pkgs):
        r[2] = pt
        offs.append(round(px - r[3], 1))
    if len(set(offs)) > 2:
        print("  ** 站点/封装脚 x 偏移不恒定 %s ⇒ 表不可用" % sorted(set(offs)))
        return 1

    print("# bank %s：站点↔封装脚 x 偏移 %s（恒定 ⇒ 按序配对成立）"
          % (bank, sorted(set(offs))))
    print()
    print("| 网络名 | IO 站点 | 封装脚 |")
    print("|---|---|---|")
    for nt, io, pkg, _ in sorted(rows):
        print("| `%s` | `%s` | **%s** |" % (nt, io, pkg))
    print()
    print("OK: %d 条（封装脚还要用 scripts/check_pins.tcl 拿器件数据收口）" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
