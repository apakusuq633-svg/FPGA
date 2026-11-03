#!/usr/bin/env python3
"""PS-only 基线**算的是不是同一件事** —— 与 PL 侧固件的指纹逐位比。

为什么这条检查是必须的
----------------------
README §34 要的是 "PS-only vs PS+PL"。这个比较只要两边**跑的不是同一件事**，
得到的倍数就毫无意义 —— 而"两边跑的不是同一件事"恰恰是最容易发生、又最不容易
看出来的：A9 那边少跑一个内核、或者共用内核被拷了一份改了定标的副本，都会让
PS-only 那一侧的拍数**更好看**。

所以本脚本不看时间，只看**结果**：把 sw/ps_only.c（它 `#define main` 之后把
sw/fw/fw_main.c **原样**编进来）在 host 上跑出来的结果块，与 PL 固件的 golden
逐位比。逐位相等 ⇒ 两边做的是同一件事 ⇒ 拍数可比。

仅比较算法结果，不比较周期槽。FIR 标量结果位于 0x38C0/0x38C4；
硬件副本位于 0x38C8/0x38CC，PS-only 不执行 SIMD，因此不要求硬件副本相等。

用法：
    gcc -O2 -w -DPSONLY_HOST -DFW_MEM_RELOCATE -DFW_RDCYCLE_OVERRIDE -DFW_ACCEL=0 \
        -I sw -I sw/fw -o build/ps_only_host sw/ps_only.c sw/fw/fw_fft.c \
        sw/fw/fw_gcc.c sw/fw/fw_srp.c sw/fw/fw_das.c sw/fw/fw_gsc.c \
        sw/fw/fw_scene.c sw/fw/fw_tables.c
    ./build/ps_only_host | python3 scripts/check_ps_only_results.py
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

RES_BASE = 0x2800
GSC_EXTRA = 0x38C0 + 0x380


def words(path, count=None):
    lines = (ROOT / path).read_text().splitlines()
    vals = [int(s, 16) for s in lines if s.strip()]
    if count is not None and len(vals) != count:
        raise SystemExit(f"{path}: 期望 {count} 个字，读到 {len(vals)}")
    return vals


def run_ps_only():
    exe = ROOT / "build" / "ps_only_host"
    if not exe.is_file():
        raise SystemExit("找不到 build/ps_only_host —— 先按本文件头部的命令编译")
    out = subprocess.run([str(exe)], capture_output=True, text=True, check=True).stdout
    m = re.search(r"^PS_ONLY_RES((?: [0-9a-f]{8})+)$", out, re.M)
    if not m:
        raise SystemExit("PS-only 的输出里没有 PS_ONLY_RES 行")
    res = [int(v, 16) for v in m.group(1).split()]
    m = re.search(r"^PS_ONLY_EXTRA((?: [0-9a-f]{8})+)$", out, re.M)
    extra = [int(v, 16) for v in m.group(1).split()] if m else []
    cyc = re.search(r"^PS_ONLY_CYCLES (\d+)$", out, re.M)
    return res, extra, (int(cyc.group(1)) if cyc else None)


def main():
    res, extra, _ = run_ps_only()
    das = words("build/fw_das_fp.hex", 6)
    fir = words("build/fw_fir_fp.hex", 2)

    # (名字, 结果块下标, 期望值, 出处)
    expect = [
        ("点积 Σx·h",            0,  8519680,          "fw_main §1"),
        ("FIR",                  2,  260,              "fw_main §2"),
        ("能量 Σx²",             4,  89440,            "fw_main §3"),
        ("FFT 峰值 bin",        14,  16,               "fw_main §4"),
        ("GCC-PHAT 峰值滞后",   13,  7,                "fw_main §6"),
        ("完成标记",            15,  0xC0DE0001,       "fw_main §7"),
    ]
    for i, v in enumerate(das):
        expect.append((f"DAS 指纹[{i}]", 22 + i, v, "fw_das_model.py"))
    for i, v in enumerate(fir):
        expect.append((f"FIR fingerprint[{i}]", ("extra", i), v, "fw_fir_model.py"))

    bad = 0
    for name, idx, want, src in expect:
        got = extra[idx[1]] if isinstance(idx, tuple) else res[idx]
        tag = f"RES[{idx[1]}]" if isinstance(idx, tuple) else f"RES[{idx}]"
        if got != want:
            bad += 1
            print(f"  FAIL {name:28s} {tag:9s} 实测 0x{got:08x} 期望 0x{want:08x}  ({src})")
    print(f"PS-only 结果比对：{len(expect) - bad}/{len(expect)} 项一致")
    if bad:
        print("!! PS-only 与 PL 固件算的不是同一件事 —— 加速比不可比。")
        return 1
    print("PS_ONLY_MATCH: 同一份源码、同一份 golden，两侧逐位一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
