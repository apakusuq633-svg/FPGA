#!/usr/bin/env bash
# 把 A9 的 app 重链到 **OCM** 上跑（绕开坏掉的 DDR）。
#
#   bash scripts/build_a9_ocm.sh
#   产物：build/a9_ocm/rv32_app_ocm.elf
#
# 为什么需要这个（详见 scripts/probe_a9_run_from_ocm.tcl 头部）：
#   核心板 DDR3 是 NT5CC256M16（4Gb），ps7_config.tcl 里配的是 MT41K128M16（2Gb）。
#   行地址位数和整套时序都不一样 => DDR **写**约 9% 丢掉（OCM 对照是 0 错）。
#   app 链在 DDR 0x100000 时，A9 取到坏指令 -> 执行到野生地址 -> PS 互连+DAP 锁死。
#   修 DDR 参数要重跑 Vivado 的 PS7 配置，在那之前先用 OCM 把功能跑通。
#
# 为什么不用 Vitis 的 makefile：
#   Debug/makefile 里把链接脚本写死成 ../src/lscript.ld（DDR 版），而且 D:\Vitis
#   是**两个项目共用**的（见 CLAUDE.md / 记忆里那条），不要动它。
#   这里直接调 arm-none-eabi-gcc，只换 -T 的链接脚本，源码仍取 sw/ps_main.c
#   —— sw/ 才是版本库里的唯一真源（install_ps_app.ps1 的约定）。
#
# 依赖（都是本机已有的，全部用绝对路径）：
#   D:/Vivado/Vitis/2020.2/gnu/aarch32/nt/gcc-arm-none-eabi/bin
#   D:/Vitis/PS-PL/.../bspinclude/include  和 bsplib/lib   ← PS-PL 平台的 BSP
#   D:/Vitis/rv32_app/src/Xilinx.spec       ← Zynq 启动文件的 spec

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

# 用法：bash scripts/build_a9_ocm.sh [app名]     默认 rv32_app
# 产出：build/a9_ocm/<app名>_ocm.elf（run_board.tcl 按这个名字找）
app="${1:-rv32_app}"
case "$app" in
    rv32_app)     src="$root/sw/ps_main.c" ;;
    pdm_app)      src="$root/sw/ps_pdm.c" ;;
    dualcore_app) src="$root/sw/ps_dualcore.c" ;;
    fft_app)      src="$root/sw/ps_fft_test.c" ;;
    # ui_app 在这条路上**一定链接失败**，留在这里是为了让失败原因明确而不是莫名其妙：
    # 它的 .bss 实测 3,201,088 B（3.05 MB，取自 Vitis 那次构建的 arm-none-eabi-size），
    # 而 A9 侧的 OCM 一共 256 KB。其中 lwIP 自己的内存池就占约 0.6 MB
    # （pbuf 池 458,815 B + 堆 131,263 B + TCP_SEG 16,447 B，大小由 BSP 的 lwipopts.h 决定），
    # 余下是流水线的缓冲（bd_space 1 MB、站 11 的工作缓冲 320,000 B、fea_* 5×65,536 B）。
    # 这个脚本是 DDR 参数配错那阵子的绕法（见 run_board.tcl 头注，DDR 已于 2026-10-04 修好），
    # ui_app 只走 Vitis 的 DDR 版。
    ui_app)       src="$root/sw/ps_ui.c" ;;
    *) echo "不认识的 app：$app（要在 run_board.tcl 的名单里，且这里要有映射）" >&2; exit 1 ;;
esac
# 共享头文件都放在 sw/，靠 -I 找到，不往 Vitis 里拷（D:\Vitis 是两个项目共用的）

TOOLBIN="/d/Vivado/Vitis/2020.2/gnu/aarch32/nt/gcc-arm-none-eabi/bin"
BSPINC="D:/Vitis/PS-PL/export/PS-PL/sw/PS-PL/standalone_domain/bspinclude/include"
BSPLIB="D:/Vitis/PS-PL/export/PS-PL/sw/PS-PL/standalone_domain/bsplib/lib"
SPEC="D:/Vitis/rv32_app/src/Xilinx.spec"

for p in "$TOOLBIN/arm-none-eabi-gcc.exe" "$BSPINC/xil_io.h" "$BSPLIB/libxil.a" "$SPEC" \
         "$src" "$root/sw/lscript_ocm.ld"; do
    if [ ! -e "$p" ]; then echo "缺少：$p" >&2; exit 1; fi
done

export PATH="$TOOLBIN:$PATH"
out="$root/build/a9_ocm"
mkdir -p "$out"
cd "$out"
elf="${app}_ocm.elf"

echo "==> 编译 $src"
arm-none-eabi-gcc -Wall -O0 -g3 -c \
    -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard \
    -I"$BSPINC" -I"$root/sw" -o "$app.o" "$src"

echo "==> 链接（-T sw/lscript_ocm.ld，落在 OCM 0x00020000）"
arm-none-eabi-gcc -mcpu=cortex-a9 -mfpu=vfpv3 -mfloat-abi=hard -Wl,-build-id=none \
    -specs="$SPEC" -Wl,-T -Wl,"$root/sw/lscript_ocm.ld" -L"$BSPLIB" \
    -o "$elf" "$app.o" \
    -Wl,--start-group -lxil -lgcc -lc -Wl,--end-group

echo "==> 产物"
arm-none-eabi-size "$elf"
# 立刻自检：入口和 main 必须落在 OCM 区间内，否则后面上板会白跑一趟
entry="$(arm-none-eabi-readelf -h "$elf" | sed -n 's/.*Entry point address:[[:space:]]*//p')"
main_a="$(arm-none-eabi-nm -n "$elf" | awk '$3=="main"{print $1}')"
echo "    entry=$entry  main=0x$main_a"
# readelf 印的是 "0x20000"，bash 的 16# 要的是不带 0x 的裸十六进制
entry_hex="${entry#0x}"; entry_hex="${entry_hex#0X}"
if [ "$((16#${entry_hex:-0}))" -ne $((0x00020000)) ]; then
    echo "入口不在 OCM（0x00020000）—— 链接脚本没生效？" >&2
    exit 1
fi
echo "OK: $out/$elf"
echo "    main 入口 = 0x$main_a"
if [ "$app" = "rv32_app" ]; then
    echo "    （probe_a9_run_from_ocm.tcl 里的 MAIN_ADDR 要跟这个一致）"
fi
