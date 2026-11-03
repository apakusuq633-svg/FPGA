#!/usr/bin/env bash
# FFT 内核的 host 侧自检 —— 四层验证里最快的两层之间那一步。
#
#   1. python3 scripts/golden/fw_fft_model.py --ref   定点模型 + 出参照
#   2. 本脚本                                         C 内核（x86 上跑）对参照
#   3. tb/tb_fw_fft.v                                同一个 C 在真核上跑
#
# 为什么要第 2 层：仿真一次 74 万拍、几分钟；同一个错在 host 上秒级就暴露。
# 更值钱的是**它能定性**：这里过、仿真不过 ⇒ 问题在内存/SoC，不在算法。
# 这一步就是抓出「FW_OUT_BASE 与 link.ld 的 .fwout 不一致」那个 bug 的手段。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

REF="${1:-build/fw_fft_ref.hex}"
if [ ! -f "$REF" ]; then
    echo "!! 找不到参照 $REF，先跑： python3 scripts/golden/fw_fft_model.py --ref"
    exit 1
fi

mkdir -p build
# ⚠ 必须一起链 fw_tables.c（g_tw_re / g_tw_im 在那里）。少了它只有链接错，
#   但这份脚本自 2026-10-06 起一直是坏的（CRLF + 缺表），**没人跑过** ——
#   所以"链接错"和"从来没跑"在这里是分不出来的。
gcc -O2 -Wall -I sw/fw -o build/fw_fft_host \
    scripts/golden/fw_fft_host.c sw/fw/fw_fft.c sw/fw/fw_tables.c
exec ./build/fw_fft_host "$REF"
