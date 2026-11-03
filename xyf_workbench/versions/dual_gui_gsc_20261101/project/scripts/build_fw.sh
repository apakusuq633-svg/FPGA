#!/usr/bin/env bash
# PL 侧固件构建 —— 在 WSL 里跑。
#
#   bash scripts/build_fw.sh
#
# 产物：
#   sw/fw/fw.elf       带符号，调试用
#   sw/fw/fw_itcm.hex  ITCM 预装：只有 .text
#   sw/fw/fw_dtcm.hex  DTCM 预装：.data + .rodata（**从字号 0 起**，见 link.ld）
#   sw/fw/fw.map       链接映射，用来核 .text 有没有越过 0x2000
#
# ⚠ 两份镜像都要装。只装 ITCM 的话，代码照跑，但所有常量/初值读出来是 X 或 0，
#   不报任何错 —— 见 sw/fw/link.ld 头部。本脚本构建完会**自己检查**
#   「.text 结束 < 0x2000」和「.data 结束 < 0x3000（结果块）」两条。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FW="$ROOT/sw/fw"
: "${FW_MODE:=acceptance}"
if [ "$FW_MODE" = live ]; then
    MAIN_SRC=fw_live.c
    IMAGE_STEM=fw_live
    OUT="$FW/build/live"
elif [ "$FW_MODE" = acceptance ]; then
    MAIN_SRC=fw_main.c
    IMAGE_STEM=fw
    OUT="$FW/build"
else
    echo "FAIL: unknown FW_MODE=$FW_MODE"
    exit 1
fi
mkdir -p "$OUT"

# 工具链前缀 / ISA 串都可从环境覆盖。默认值保持原样（另一台机器上就是这套），
# 覆盖是为了本机能用 —— 本机的 xPack GCC 15.2 里：
#   · 前缀是 riscv-none-elf-，不是 riscv64-unknown-elf-
#   · `csrr` 需要 zicsr（GCC 12 起按 ISA spec 20191213 把 zicsr 拆出去了），
#     所以只写 -march=rv32im 会报 "unrecognized opcode csrr, extension zicsr required"
# 本机调用：
#   FW_CC=riscv-none-elf-gcc FW_OC=riscv-none-elf-objcopy FW_OD=riscv-none-elf-objdump \
#   FW_ARCH=rv32im_zicsr bash scripts/build_fw.sh
: "${FW_CC:=riscv64-unknown-elf-gcc}"
: "${FW_OC:=riscv64-unknown-elf-objcopy}"
: "${FW_OD:=riscv64-unknown-elf-objdump}"
: "${FW_ARCH:=rv32im}"
# 加速开关（fw_fft.h）。默认 1 = 走核内硬件单元。
#   FW_ACCEL=0 bash scripts/build_fw.sh    → 全标量基线镜像，**一条自定义指令都不发**
# 整机加速比就是两份镜像在同一个工作负载上的拍数之比 ——
# 见 scripts/test_whole_machine.sh。**这个开关只换实现，不换工作负载。**
: "${FW_ACCEL:=1}"
# 工作负载口径（fw_plat.h）。1 = 基准轮（含对照指纹那一趟），0 = 产品形态轮。
# 整机对照两种口径都量，见 scripts/test_whole_machine.sh 与 measurements §13。
: "${FW_BENCH_ROUND:=1}"
# 逐帧抖动：0 = 不加这一段（默认）。>0 = 把一帧的链连跑 n 次记 min/max/sum。
: "${FW_JITTER_N:=0}"

CC=$FW_CC
OC=$FW_OC
OD=$FW_OD

CFLAGS="-march=$FW_ARCH -mabi=ilp32 -O2 -ffreestanding -fno-builtin -nostdlib
        -Wall -Wextra -Wno-unused-parameter -fno-strict-aliasing
        -DFW_ACCEL=$FW_ACCEL -DFW_BENCH_ROUND=$FW_BENCH_ROUND -DFW_JITTER_N=$FW_JITTER_N
        -fstack-usage"   # Generate .su for the reserved-stack budget check below.

# main 只执行一次 ⇒ 按尺寸优化。实测省 488 B（main 2112 → 1568），**零拍数代价**。
# ⚠ 只给 fw_main.c 用。别的文件都有热路径（fw_scene 的插值每样点调 24 次、
#   fw_gsc 的内核占整轮 67.5%），压它们就是拿拍数换字节 —— 那是亏的。
CFLAGS_MAIN="${CFLAGS/-O2/-Os}"

# ── 生成的常量表必须比生成器新，否则用了过期的表还以为改了生效 ──────
if [ ! -f "$FW/fw_tables.h" ] || \
   [ "$FW/fw_tables.h" -ot "$ROOT/scripts/golden/fw_fft_model.py" ]; then
    echo "!! sw/fw/fw_tables.h 缺失或比生成器旧。先跑："
    echo "     python3 scripts/golden/fw_fft_model.py"
    exit 1
fi

# DAS 的延迟表同理：它由真几何算出来的，手改会与几何漂开
if [ ! -f "$FW/fw_das_scene.h" ] || \
   [ "$FW/fw_das_scene.h" -ot "$ROOT/scripts/golden/fw_das_model.py" ]; then
    echo "!! sw/fw/fw_das_scene.h 缺失或比生成器旧。先跑："
    echo "     python3 scripts/golden/fw_das_model.py"
    exit 1
fi

echo "== 编译 =="
$CC $CFLAGS -c "$FW/start.S" -o "$OUT/start.o"
# ⚠ fw_main.c 单独用 -Os：`main` 只跑一次（装场景、调各内核、报结果），
#   优化它跑多快**没有任何意义**，而 -O2 把一堆静态辅助函数内联进去，
#   实测 main 一个人就占 2,112 B。换 -Os 后 main → 1,568 B，全文件 -488 B。
#   而**内核一个都没碰**，所以 CLAUDE.md §6 那条"-Os 让 DAS 慢 2.9×"不适用 ——
#   那条说的是把 -Os 用在整个固件上（连 fw_scene 的插值热路径一起压了）。
#   ⇒ 尺寸要按"这段代码会被执行几次"来分配优化级别。
$CC $CFLAGS_MAIN -c "$FW/$MAIN_SRC" -o "$OUT/fw_main.o"
$CC $CFLAGS -c "$FW/fw_tables.c" -o "$OUT/fw_tables.o"
$CC $CFLAGS -c "$FW/fw_fft.c" -o "$OUT/fw_fft.o"
$CC $CFLAGS -c "$FW/fw_gcc.c" -o "$OUT/fw_gcc.o"
$CC $CFLAGS -c "$FW/fw_srp.c" -o "$OUT/fw_srp.o"
# 转向块（rv32_steer_regs）的固件驱动。**-O2**：这段只跑一次，
# 但实测 -O2/-Os 编出来一样大（196 B），压不出字节，就别拿级别去骗自己。
objects=(start fw_main fw_tables fw_fft fw_gcc fw_srp)
if [ "$FW_MODE" = acceptance ]; then
    for src in fw_scene fw_das fw_fir fw_steer; do
        $CC $CFLAGS -c "$FW/$src.c" -o "$OUT/$src.o"
        objects+=("$src")
    done
fi
link_objects=()
su_files=()
for obj in "${objects[@]}"; do
    link_objects+=("$OUT/$obj.o")
    [ ! -f "$OUT/$obj.su" ] || su_files+=("$OUT/$obj.su")
done

echo "== 链接 =="
$CC -march=rv32im -mabi=ilp32 -nostdlib -T "$FW/link.ld" \
    -Wl,-Map="$OUT/fw.map" \
    "${link_objects[@]}" \
    -o "$FW/$IMAGE_STEM.elf"

# ── 越界检查：.text 段**末**必须 < TEXT_LIMIT ──────────────────────
# ⚠ objdump -h 的列是「Idx Name Size VMA LMA ...」，$3=Size、$4=VMA。
#   第一版拿 $4 当"结束地址"，其实那是**起始**地址，等于恒查 0x0 ——
#   这个守卫永远不会报警。段末 = VMA + Size。
#
# ⚠ 上限 2026-10-06 从 0x2000 放宽到 0x2400（转向块的固件驱动要用）。
#   为什么 0x2000 不是硬限制：
#     · ITCM 是 16 KB = 4096 字（rv32_soc 的 ITCM_WORDS / ITCM_ADDR_WIDTH），
#       0x2400 只用到 2304 字；
#     · 仿真的加载方是 tb 的 `$readmemh(..., u_itcm.memory)`，按字号顺序填，
#       没有 0x2000 这条线；
#     · 上板的加载方是 sw/ps_main.c 的 download_to_tcm(..., MEM_SEL_ITCM)，
#       也是个**字数**窗口，同样没有这条线。
#   link.ld 那段注释担心的"越过 0x2000 的字写进 ITCM 高半区" —— 高半区就是
#   有效的 ITCM，本来就能装。0x2000 是早期设计（.data 的 LMA 排在 .text 之后）
#   留下的守卫，那个约束在 link.ld 改成 DTCM 预装之后就不成立了。
#   **仍然保留一条线**：越界要报错，只是线挪到 0x2400 —— 别让它无界地长。
# ⚠ 反过来，DTCM 那两条闸门（.data < 0x3000、.bss ≤ 0x2800）**没有**放宽，
#   也放不宽：那是真的物理边界。转向块的驱动把 .bss 顶到了 0x27F0，
#   .bss 只剩 16 B 余量 —— 再加静态数组先看那两条。
TEXT_LIMIT=$((0x2400))
read -r T_SIZE T_VMA < <($OD -h "$FW/$IMAGE_STEM.elf" | awk '$2==".text"{print $3, $4}')
if [ -z "${T_SIZE:-}" ]; then echo "!! 找不到 .text 段"; exit 1; fi
TEXT_END_DEC=$(( 16#$T_VMA + 16#$T_SIZE ))
echo "   .text 0x$T_VMA + 0x$T_SIZE -> 结束于 0x$(printf '%x' $TEXT_END_DEC)  (上限 0x$(printf '%x' $TEXT_LIMIT))"
if [ "$TEXT_END_DEC" -ge "$TEXT_LIMIT" ]; then
    echo "!! .text 越过了 0x$(printf '%x' $TEXT_LIMIT)。缩内核，或再确认一次加载方装得下。"
    exit 1
fi

# ── 数据段检查：.data（含 .rodata）必须整体落在结果块 0x3000 以下 ──────
read -r D_SIZE D_VMA < <($OD -h "$FW/$IMAGE_STEM.elf" | awk '$2==".data"{print $3, $4}')
D_SIZE=${D_SIZE:-00000000}
DATA_END_DEC=$(( 16#${D_VMA:-0} + 16#$D_SIZE ))
echo "   .data 0x${D_VMA:-0} + 0x$D_SIZE -> 结束于 0x$(printf '%x' $DATA_END_DEC)"
if [ "$DATA_END_DEC" -ge $((0x3000)) ]; then
    echo "!! .data 撞上结果块 0x3000。缩常量表，或把 .fwres 往后挪。"
    exit 1
fi

# ── 缓冲区检查：.bss 末尾必须 ≤ 0x2800（批量输出区起点）──────────────
# Check stack frames against the FIR/steering memory-map reservation in link.ld.
# -fstack-usage 给每个函数一个 .su 文件（"file:line:func<TAB>bytes<TAB>static"）。
# 这里取**单个函数的最大栈帧**做保守判据：真需求还包含调用链累加，但本固件是
# 平铺的（main 里顺序调内核，没有深递归），单帧最大值已经是最紧的那条下界。
su_max=0; su_where=""
while read -r f; do
    while IFS=$'\t' read -r loc bytes rest; do
        case "$bytes" in ''|*[!0-9]*) continue;; esac
        if [ "$bytes" -gt "$su_max" ]; then su_max=$bytes; su_where="$loc"; fi
    done < "$f"
done < <(printf '%s\n' "${su_files[@]}")
STACK_AVAIL=$(( 0x3FF0 - 0x38C0 - 0x3C0 ))
echo "   栈：最大单帧 $su_max B（$su_where），可用 $STACK_AVAIL B"
if [ "$su_max" -ge $((STACK_AVAIL / 2)) ]; then
    echo "!! Maximum stack frame $su_max B exceeds half of the reserved $STACK_AVAIL B stack"
    exit 1
fi

read -r B_SIZE B_VMA < <($OD -h "$FW/$IMAGE_STEM.elf" | awk '$2==".bss"{print $3, $4}')
B_SIZE=${B_SIZE:-00000000}
BSS_END_DEC=$(( 16#${B_VMA:-0} + 16#$B_SIZE ))
echo "   .bss  0x${B_VMA:-0} + 0x$B_SIZE -> 结束于 0x$(printf '%x' $BSS_END_DEC)"
if [ "$BSS_END_DEC" -gt $((0x2800)) ]; then
    echo "!! .bss 撞上批量输出区 0x2800。缩缓冲区，或挪 .fwout。"
    exit 1
fi

echo "== 导出 ITCM 镜像（只有 .text）=="
$OC -O binary --only-section=.text "$FW/$IMAGE_STEM.elf" "$OUT/fw.bin"

echo "== 导出 DTCM 镜像（.data + .rodata，字号 0 起）=="
$OC -O binary --only-section=.data "$FW/$IMAGE_STEM.elf" "$OUT/fw_data.bin"

# binary → 每行一个 32 位字的 hex（$readmemh 用）
python3 - "$OUT/fw.bin" "$FW/${IMAGE_STEM}_itcm.hex" "$OUT/fw_data.bin" "$FW/${IMAGE_STEM}_dtcm.hex" <<'PY'
import sys, struct

def emit(src, dst, label):
    b = open(src, 'rb').read()
    b += b'\x00' * ((4 - len(b) % 4) % 4)
    with open(dst, 'w') as f:
        for i in range(0, len(b), 4):
            f.write("%08x\n" % struct.unpack_from('<I', b, i)[0])
    print("   %s %d 字 (%.1f KB) -> %s" % (label, len(b)//4, len(b)/1024, dst))

emit(sys.argv[1], sys.argv[2], "ITCM")
emit(sys.argv[3], sys.argv[4], "DTCM")
PY

# 反汇编留档，出问题时对着看
$OD -d "$FW/$IMAGE_STEM.elf" > "$OUT/fw.dis" 2>/dev/null || true

echo "== 完成 =="
echo "   ITCM 镜像: sw/fw/fw_itcm.hex   （TB 的 ITCM_FILE）"
echo "   DTCM 镜像: sw/fw/fw_dtcm.hex   （TB 的 DTCM_FILE / PS 的 MEM_SEL_DTCM）"
