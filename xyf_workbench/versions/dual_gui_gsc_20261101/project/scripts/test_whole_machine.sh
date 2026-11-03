#!/usr/bin/env bash
# 整机加速比 —— 同一份固件源码、**同一个工作负载**，加速镜像 vs 全标量基线。
#
# 「整机」在这里的口径要说死
# --------------------------
# 跑的是**真的 PS 程序**（sw/ps_main.c）经**真的 AXI** 驱动**真的 PS+PL RTL**
# （rv32_ps_top：Cortex-A9 侧的 AXI-Lite 主机 + 自研 RV32 核 + 全部加速单元）。
# 计的是从放核到固件落完成标记之间的 RTL 拍数（acoustic_ps_sim.cpp 的 clocks）。
# 所以它含：固件整轮、PS 侧逐字下载与回读、AXI 往返、以及每一处 MMIO 等待。
#
# **它不含 Cortex-A9 自己的周期数** —— 那是 A9 内部的事，RTL 里看不见。
# 报数时必须连着这句一起说，否则"整机"会被读成"连 A9 一起算了"。
#
# 两份镜像差在哪
# --------------
#   加速镜像  FW_ACCEL=1：正/逆变换走核内 VFFT，FIR 第二趟走 SIMD-MAC 阵列
#   基线镜像  FW_ACCEL=0：以上全部换成标量 C，**一条自定义指令都不发**
# 工作负载一模一样（同一段 main、同样多次内核调用、同样的数据）。gen_acoustic_image.py
# 对基线镜像的判据是反的：四条自定义指令必须**一条都没有**。
#
# 用法：
#   bash scripts/test_whole_machine.sh            # 两边都跑
#   bash scripts/test_whole_machine.sh accel      # 只跑加速那一边（迭代时用）
#   bash scripts/test_whole_machine.sh base
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
mkdir -p build

which="${1:-both}"

# ── 1. 生成常量表与 golden（两份镜像共用，只跑一次）─────────────────────
for model in fw_fft_model fw_gcc_model fw_srp_model fw_das_model fw_fir_model gen_steer_vectors; do
    python3 "scripts/golden/${model}.py" > /dev/null
done
# 硬件逆变换 / 满幅正变换的向量（给 tb_fft_ifft 用，这里顺带保证它是最新的）
gcc -O2 -I sw/fw -o build/fw_ifft_host scripts/golden/fw_ifft_host.c sw/fw/fw_fft.c sw/fw/fw_tables.c
./build/fw_ifft_host > build/fw_ifft_host.log

# ── 2. verilator 的 RTL 文件表（只要 rtl/，不要 tb/）─────────────────────
python3 - <<'PY'
from pathlib import Path
lines = Path('scripts/filelist.f').read_text().splitlines()
Path('build/whole_machine.f').write_text('\n'.join(s for s in lines if s.startswith('rtl/')) + '\n')
PY

# $1 = accel|base   $2 = 1 基准轮 / 0 产品形态轮
# FW_BENCH_ROUND 只影响**工作负载**（去掉那些只为对照而跑的重复段），
# 不影响 FW_ACCEL 的语义 —— 两个轴正交，所以四种组合都要能量。
build_image() {   # $1 = accel|base
    if [ "$1" = base ]; then
        FW_ACCEL=0 FW_BENCH_ROUND=${2:-1} bash scripts/build_fw.sh
        ACOUSTIC_BASELINE=1 ACOUSTIC_IMAGE_OUT=sw/acoustic_image_base.h \
            python3 scripts/gen_acoustic_image.py
        # ⚠ 立刻把**加速那套**镜像放回 sw/fw/。仓库里这两个 hex 是上板流程
        #   （ps_main.c 的 download_to_tcm）实际会灌进去的东西 —— 一次对照实验
        #   把它们留成基线版，之后就没人看得出来"上板验的是哪一版"了。
        #   用"跑之前先存副本、跑完再放回"而不是"末尾重建一次"：中途失败
        #   （set -e）时末尾那一步不会执行，而这两行总是会。
        cp build/whole_accel_itcm.hex sw/fw/fw_itcm.hex
        cp build/whole_accel_dtcm.hex sw/fw/fw_dtcm.hex
    else
        FW_ACCEL=1 FW_BENCH_ROUND=${2:-1} bash scripts/build_fw.sh
        python3 scripts/gen_acoustic_image.py
        cp sw/fw/fw_itcm.hex build/whole_accel_itcm.hex
        cp sw/fw/fw_dtcm.hex build/whole_accel_dtcm.hex
    fi
}

# $1 = tag   $2 = 1 用加速镜像头 / 0 用基线镜像头   $3 = 1 计量模式（不判合格）
build_sim() {
    # ⚠ 必须分两行：`local a="$1" b="...$a"` 里 b 看不到同一行刚声明的 a，
    #   在 `set -u` 下直接报 "a: unbound variable"。实测踩过。
    local tag="$1" want="$2" measure="$3"
    local obj="/tmp/pdm_whole_$tag" defs=""
    [ "$want" = 0 ]    && defs="$defs -DACOUSTIC_BASELINE_IMAGE"
    [ "$measure" = 1 ] && defs="$defs -DACOUSTIC_MEASURE_ONLY"
    verilator --cc --exe --build -Wno-fatal --unroll-count 512 --unroll-stmts 100000 \
        --top-module rv32_ps_top -GDAS_ACTIVE_CHANNELS=8 -Irtl -f build/whole_machine.f --Mdir "$obj" -j 4 \
        -CFLAGS "-O2 -I$root/scripts/sim_bsp $defs" \
        "$root/scripts/acoustic_ps_sim.cpp" > "build/whole_${tag}_build.log" 2>&1
}

run_sim() {       # $1 = tag   $2 = accel|base（要不要额外查应用级 PASS）
    local tag="$1" want="$2"
    /tmp/pdm_whole_$tag/Vrv32_ps_top > "build/whole_${tag}.log" 2>&1 || true
    grep -E '^ACOUSTIC_(RETIRED|RTL_|RESULT_|MEASURE_DONE)' "build/whole_${tag}.log" | tail -4
    # 这一边到底跑成了没有 —— 汇总之前先判，别让缺的那一边用旧数顶上。
    if ! grep -q '^ACOUSTIC_RTL_PASS$' "build/whole_${tag}.log" && \
       ! grep -q '^ACOUSTIC_RTL_MEASURED$' "build/whole_${tag}.log"; then
        echo "!! ${tag} 这一边没有跑成（没有 ACOUSTIC_RTL_PASS/MEASURED）—— 汇总作废"
        exit 1
    fi
    if [ "$want" = "accel" ] && ! grep -q '^ACOUSTIC_RESULT_PASS' "build/whole_${tag}.log"; then
        echo "!! 加速镜像没通过声学验收（ACOUSTIC_RESULT_PASS 不在）—— 汇总作废"
        exit 1
    fi
}

echo "===== 整机加速比：$(date) ====="

# ⚠⚠ 先删掉上一次的日志。**这一步不是清理，是判据的一部分**：
#   下面读的是 build/whole_*.log，而它们在失败时**不会**被覆盖 —— 于是脚本
#   报错退出、汇总却照着上一轮的旧数打出一张漂亮的表。实测踩过：改完
#   fw_gsc.c 少 include 一个头，加速镜像整个没编出来（`.text` 里一条自定义
#   指令都没有），而汇总照打 1.4584×。**旧日志比没有日志更危险**，
#   它看起来像结论（同 CLAUDE.md §1 那句话）。
rm -f build/whole_accel.log build/whole_base.log \
      build/whole_prod_accel.log build/whole_prod_base.log

# 四种组合 = {加速, 基线} × {基准轮, 产品形态轮}。
#   基准轮那一对里，加速镜像跑**完整声学验收**（要 PASS）—— 它是"这套东西是对的"
#   的证据；其余三次是计量轮，判据放开（产品轮故意少跑一段，本来就不该 PASS）。
#
# ⚠ 顺序有讲究：`build_image accel 1` 会把**规范镜像**存进 build/whole_accel_*.hex，
#   后面每次 base 构建都从它恢复。所以基准轮那对必须先跑。
if [ "$which" = both ] || [ "$which" = accel ]; then
    echo "── [1/4] 基准轮 · 加速镜像（FW_ACCEL=1 FW_BENCH_ROUND=1）──"
    build_image accel 1
    build_sim   accel 1 0
    run_sim     accel accel
fi

if [ "$which" = both ] || [ "$which" = base ]; then
    echo "── [2/4] 基准轮 · 基线镜像（FW_ACCEL=0，全标量）──"
    build_image base 1
    build_sim   base 0 1
    run_sim     base base
fi

if [ "$which" = both ]; then
    echo "── [3/4] 产品形态轮 · 加速镜像（FW_BENCH_ROUND=0）──"
    build_image accel 0
    build_sim   prod_accel 1 1
    # 产品轮是**计量轮**（少跑了一段，本来就不该 PASS）⇒ 只查"跑成了"，
    # 不查应用级 PASS。传 measure 而不是 accel。
    run_sim     prod_accel measure

    echo "── [4/4] 产品形态轮 · 基线镜像（FW_BENCH_ROUND=0）──"
    build_image base 0
    build_sim   prod_base 0 1
    run_sim     prod_base measure

    echo "── 恢复仓库的规范镜像（加速、基准轮）──"
    build_image accel 1
fi

if [ "$which" = both ]; then
    python3 - <<'PY'
import re, pathlib
def clocks(tag):
    t = pathlib.Path(f'build/whole_{tag}.log').read_text(errors='replace')
    m = re.search(r'clocks=(\d+)', t)
    return int(m.group(1)) if m else None
a,  b  = clocks('accel'),  clocks('base')
pa, pb = clocks('prod_accel'), clocks('prod_base')
print()
print('=' * 68)
print('整机拍数（真 PS 程序 + 真 AXI + 真 PS/PL RTL，非上板）')
print('=' * 68)
def row(name, x, y, note=''):
    if not x or not y:
        print(f'  {name:<22}：没跑到 clocks'); return
    print(f'  {name:<22} {y:>12,} → {x:>12,} 拍   {y/x:>7.4f} ×{note}')
print(f'  {"":<22} {"基线(标量)":>12}   {"加速":>12}')
row('基准轮（含对照趟）', a, b)
row('产品形态轮（FIR 一趟）', pa, pb)
print()
print('  基准轮口径：整轮含「每个内核单独量一次 + 对照指纹那一趟」。')
print('  产品形态轮：去掉只为对照而跑的重复段（FIR 少一趟），更接近产品。')
print('  两者都对，回答的不是同一个问题 —— 报数时必须写明是哪一个。')
print()
print('  共同口径：含固件整轮 + PS 下载/回读 + AXI 往返 + MMIO 等待；')
print('            **不含 Cortex-A9 自身的周期数**（RTL 看不见 A9）。')
PY
fi
