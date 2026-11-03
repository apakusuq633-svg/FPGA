"""按**文本坐标**抽原理图 PDF 的文字 —— 用来重建连接器线序表。

    python3 scripts/golden/pdftext.py <pdf> --find J4
    python3 scripts/golden/pdftext.py <pdf> --page 2 --box 0,0,400,300
    python3 scripts/golden/pdftext.py <pdf> --outline

为什么不能用 `page.extract_text()`：那玩意儿按**书写顺序**吐字。
原理图里连接器的针号标注和网络名是分两处画的，书写顺序完全对不上，
拼出来是一堆没有对应关系的词。必须先拿到每段文字的 (x, y)，
再按「同一行 y 接近、同一点的针号与网络名 x 接近」去配。

这是 `board_io.md` §2 说的「按文本坐标重建表格」那一步 —— 原来那个
`build/pdfsheet.py` 在 gitignored 的 build/ 下，早就没了，所以重写一份入库。

⚠ 坐标是 PDF 用户空间的点（1/72 inch），**y 轴向上**。同一个器件在图纸上
   可能整体旋转，所以配对应当时以 x 为主、或先看数据形状再决定。
"""
import argparse
import sys
from collections import defaultdict

from pypdf import PdfReader


def pages_with(reader, needle):
    hits = []
    for i, page in enumerate(reader.pages):
        try:
            t = page.extract_text() or ""
        except Exception:
            continue
        if needle in t:
            hits.append(i)
    return hits


def dump_outline(reader):
    def walk(items, depth=0):
        for it in items:
            if isinstance(it, list):
                walk(it, depth + 1)
            else:
                try:
                    pg = reader.get_destination_page_number(it)
                except Exception:
                    pg = "?"
                print("%s%-58s p%s" % ("  " * depth, str(it.title)[:58], pg))
    try:
        walk(reader.outline)
    except Exception as e:
        print("读不到书签树: %s" % e)


def dump_page(reader, pageno, box=None):
    """吐出这一页每段文字的 (x, y, 文本)，按 y 降序（图纸从上到下）。"""
    page = reader.pages[pageno]
    spans = []

    def visitor(text, cm, tm, font_dict, font_size):
        t = text.strip()
        if not t:
            return
        # tm 是文本矩阵，第 5/6 个是平移量，就是这段文字的原点
        x = tm[4]
        y = tm[5]
        # 有 CTM 时（图纸上很常见）要复合进去
        if cm is not None and (cm[0], cm[1], cm[2], cm[3]) != (1, 0, 0, 1):
            x = cm[0] * tm[4] + cm[2] * tm[5] + cm[4]
            y = cm[1] * tm[4] + cm[3] * tm[5] + cm[5]
        spans.append((round(x, 1), round(y, 1), t))

    page.extract_text(visitor_text=visitor)

    if box:
        x0, y0, x1, y1 = box
        spans = [s for s in spans if x0 <= s[0] <= x1 and y0 <= s[1] <= y1]

    # 同一行的认定：y 差在 tol 之内。图纸上字高通常 6–10 pt。
    tol = 1.2
    rows = defaultdict(list)
    for x, y, t in spans:
        key = None
        for k in rows:
            if abs(k - y) <= tol:
                key = k
                break
        if key is None:
            key = y
        rows[key].append((x, t))

    print("=== page %d: %d 段文字 ===" % (pageno, len(spans)))
    for y in sorted(rows, reverse=True):
        cells = sorted(rows[y])
        line = "   ".join("%s%s" % (" " * 0, t) for _, t in cells)
        print("y=%8.1f | %s" % (y, line))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--find", help="找出含这个字符串的页，只列页号")
    ap.add_argument("--page", type=int, help="按坐标dump这一页（从0起）")
    ap.add_argument("--box", help="限定区域 x0,y0,x1,y1")
    ap.add_argument("--outline", action="store_true", help="打印书签树")
    ap.add_argument("--pages", type=int, default=0, help="只列前 N 页的文本摘要")
    a = ap.parse_args()

    reader = PdfReader(a.pdf)
    print("# %s : %d 页" % (a.pdf, len(reader.pages)))

    if a.outline:
        dump_outline(reader)
    if a.find:
        hits = pages_with(reader, a.find)
        print("# 含 %r 的页: %s" % (a.find, hits))
    if a.pages:
        for i in range(min(a.pages, len(reader.pages))):
            t = (reader.pages[i].extract_text() or "").replace("\n", " ")
            print("p%-3d %s" % (i, t[:150]))
    if a.page is not None:
        box = tuple(float(v) for v in a.box.split(",")) if a.box else None
        dump_page(reader, a.page, box)


if __name__ == "__main__":
    sys.exit(main())
