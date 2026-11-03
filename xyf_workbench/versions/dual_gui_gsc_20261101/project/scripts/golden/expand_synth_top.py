"""把 scripts/gen_synth_top.tcl 两个 proc 里的 `puts $fp` 展开成 Verilog，供编译校验。

**为什么要这个**：那两个 proc 生成的 `rv32_synth_top.v` / `rv32_board_top.v` 才是
真正进综合的文件，但它们只存在于 Vivado 跑完 `gen_synth_top.tcl` 之后。本机没有
tclsh（Vivado 里那个要起整个 Vivado），所以那两行 `puts` 一旦写错（端口名拼错、
位宽少写、漏一个逗号），在 `verify.ps1` 第 1 项里是**看不出来**的 ——
那一项只比对端口**名字集合**，不比语法。

本脚本把 `puts` 的字面量原样取出来拼成文件，让 iverilog 去挑语法错。
它**不替代** Vivado 那一跑，只是把「语法错误」和「端口不匹配」分开。

用法：
  python3 scripts/golden/expand_synth_top.py            # 写到 build/gen_*.v
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TCL = os.path.join(ROOT, "scripts", "gen_synth_top.tcl")
OUT = os.path.join(ROOT, "build")


def expand(seg):
    out = []
    for line in seg.splitlines():
        m = re.match(r'\s*puts \$fp "(.*)"\s*$', line)
        if not m:
            continue
        s = m.group(1)
        # Tcl 里的转义还原成 Verilog 源码
        s = s.replace('\\"', '"').replace("\\[", "[").replace("\\]", "]")
        # Tcl 变量：只用到 $hex（ITCM 镜像路径），换成占位符即可
        s = re.sub(r"\$hex", "sw/led_demo.hex", s)
        out.append(s)
    return "\n".join(out) + "\n"


def main():
    src = io.open(TCL, encoding="utf-8").read()
    i_synth = src.index("proc gen_synth_top")
    i_board = src.index("proc gen_board_top")
    segs = {"synth": src[i_synth:i_board], "board": src[i_board:]}

    if not os.path.isdir(OUT):
        os.makedirs(OUT)

    bad = 0
    for name, seg in segs.items():
        txt = expand(seg)
        path = os.path.join(OUT, "gen_%s.v" % name)
        io.open(path, "w", encoding="utf-8").write(txt)
        n = txt.count("\n")
        mod = re.search(r"module\s+(\w+)", txt)
        print("%-6s %3d 行  module %s  -> %s"
              % (name, n, mod.group(1) if mod else "**缺 module**",
                 os.path.relpath(path, ROOT)))
        if not mod:
            bad += 1
        # ⚠ 用 \b 计数：直接 txt.count("module") 会把 "endmodule" 里的也数进去，
        #   于是永远「不配对」。而且**不能**拿顶层的端口去和被例化的 rv32_soc 的
        #   端口比 —— 它们本来就不一样多（裸 PL 顶层故意把 ps_*/led_o 接死或不引）。
        #   那一条由 verify.ps1 第 1 项按 rv32_soc 的三份列表查，不归这里管。
        if len(re.findall(r"^\s*module\b", txt, re.M)) != \
           len(re.findall(r"^\s*endmodule\b", txt, re.M)):
            print("  **module/endmodule 不配对**")
            bad += 1

    if bad:
        print("FAIL: 展开出来的顶层有问题（%d 项）" % bad)
        sys.exit(1)
    print("OK: 两个顶层都展开成功且自洽（语法留给 iverilog 判）")


if __name__ == "__main__":
    main()
