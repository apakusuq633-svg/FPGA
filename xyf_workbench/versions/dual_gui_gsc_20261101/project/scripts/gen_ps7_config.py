#!/usr/bin/env python3
"""从厂商例程的 block design 里导出 PS7 配置，生成 scripts/ps7_config.tcl。

背景：领航者没有可用的 Vivado 板卡文件（create_zynq_project.tcl 探测的是 Digilent 的
Zybo，永远匹配不上），所以 PS7 会退化成默认配置 —— DDR 型号/时序、MIO 分配全不对。
这些值必须从厂商能跑的工程里抄，不能猜：DDR 那几十条里有板子布线相关的长度/延迟，
填错了现象是随机的读写错误，极难查。

用法：
    python3 scripts/gen_ps7_config.py <system.bd 路径>
    python3 scripts/gen_ps7_config.py --dump <system.bd>   # 只打印，不写文件

.bd 是 JSON。PS7 单元的 parameters 里，键名是 PCW_*（**不带 CONFIG. 前缀**，
和 Tcl 里的写法不同，这里踩过一次）。PCW_ACT_* 是 Vivado 算出来的实际值、只读，
写回去没意义还占篇幅，一并滤掉。

约定：print 出来的字符串一律写 ASCII —— Windows 控制台按 cp936 解码，中文会乱码（注释用中文无妨）。
"""

import argparse
import json
import os
import sys

SKIP_PREFIX = "PCW_ACT_"

HEADER = """# 正点原子领航者 ZYNQ 的 PS7 配置，由 scripts/gen_ps7_config.py 从厂商例程导出。
# 勿手改：要改请改生成器或换源工程，然后重新生成。
#
# ⚠ 板子已从 7010 换成 7020。Zynq-7000 全系 **PS 相同**，MIO/外设那些照用；
#   但** DDR 依赖核心板** —— 换板后必须拿 7020 的厂商例程重跑本生成器。
#   详见生成出来的 ps7_config.tcl 头部那段（这里不重复，免得两处口径漂开）。
#
# 来源：{src}
#       里的 {cell} 单元。
#       那是厂商验证过、能在这块板上跑的配置（DDR 型号/时序、MIO 分配、时钟全都在内）。
#
# 已滤掉派生只读的 PCW_ACT_* 项，其余原样照抄，不做任何"整理" —— 这些值的含义只有厂商
# 和 Vivado 清楚，改动任何一条的风险都远大于收益。
#
# 本文件只管 PS 自己。PL 相关的那几项（USE_M_AXI_GP0 / USE_FABRIC_INTERRUPT /
# IRQ_F2P_INTR / FPGA0 频率）在厂商的纯 PS 例程里都是 0，由 create_zynq_project.tcl
# 在本文件之后覆盖 —— **不要在下面改它们**。
"""


def extract(bd_path):
    with open(bd_path, encoding="utf-8") as fp:
        bd = json.load(fp)
    comps = bd["design"]["components"]
    for name, comp in comps.items():
        if "processing_system7" not in comp.get("vlnv", ""):
            continue
        params = comp.get("parameters", {})
        cfg = {
            k: v["value"]
            for k, v in params.items()
            if k.startswith("PCW_") and not k.startswith(SKIP_PREFIX)
        }
        return name, cfg
    raise SystemExit("no processing_system7 cell in this .bd: %s" % bd_path)


def render(cell, cfg, src):
    lines = []
    keys = sorted(cfg)
    for i, k in enumerate(keys):
        tail = " \\" if i < len(keys) - 1 else ""
        lines.append("        CONFIG.%s {%s}%s" % (k, cfg[k], tail))
    return (
        HEADER.format(src=src, cell=cell)
        + "\nproc apply_ps7_config {cell} {\n"
        + "    set_property -dict [list \\\n"
        + "\n".join(lines)
        + "\n    ] [get_bd_cells $cell]\n}\n"
    )


def main():
    ap = argparse.ArgumentParser(description="export the PS7 config out of a vendor .bd")
    ap.add_argument("bd", help="path to system.bd")
    ap.add_argument("--out", default=os.path.join("scripts", "ps7_config.tcl"))
    ap.add_argument("--dump", action="store_true", help="print only, write nothing")
    args = ap.parse_args()

    cell, cfg = extract(args.bd)
    text = render(cell, cfg, args.bd)

    print("# cell %s: %d PCW_* entries (PCW_ACT_* filtered out)" % (cell, len(cfg)))
    if args.dump:
        print(text)
        return 0

    d = os.path.dirname(args.out)
    if d:
        os.makedirs(d, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fp:
        fp.write(text)
    print("wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
