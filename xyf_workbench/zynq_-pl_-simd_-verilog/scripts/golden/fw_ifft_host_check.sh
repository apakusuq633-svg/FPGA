#!/usr/bin/env bash
# VFFT-inv / 满幅正变换的向量生成 —— tb_fft_ifft 的 golden 从这里来。
#
# 四层验证里最快的那一层：把 **sw/fw/fw_fft.c 原样**编到 x86 上跑，
# 用它的输出当硬件的判据。所以"硬件 == golden"就是"硬件 == 标量固件"。
#
# 为什么需要这一份（而不是复用 fw_fft_host.c）：
#   · 逆变换（ifft512_real）以前没有单元级 golden，它只被整条 GCC-PHAT 的
#     golden 间接覆盖 —— 那种覆盖定位不到"是反向拆分错还是蝶形错"；
#   · 满幅帧是**唯一**能顶出拆分那一段 16 位溢出（issues/087）的向量。
#     中等幅度的帧两路操作数不会同时越过 16384，那个错就一直藏着。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ ! -f build/fw_fft_ref.hex ]; then
    echo "!! 找不到 build/fw_fft_ref.hex，先跑： python3 scripts/golden/fw_fft_model.py --ref"
    exit 1
fi

mkdir -p build
gcc -O2 -Wall -I sw/fw -o build/fw_ifft_host \
    scripts/golden/fw_ifft_host.c sw/fw/fw_fft.c sw/fw/fw_tables.c
exec ./build/fw_ifft_host
