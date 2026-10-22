#!/usr/bin/env python3
# Cortex-A9 单核标量整数吞吐模型 —— PS 侧建模，板子不在线，全部是"算"不是"测"。
#
# 每条数字标来源：  [M] 本仓库文件/前序实测   [D] ARM/厂商文档规格   [E] 估算
#
# 稳态每 tap 拍数 = 四条约束取最大：issue 宽度、L/S 通路、MAC 通路占用、累加器链延迟。
F_CPU = 666.666666e6      # [M] scripts/ps7_config.tcl:18  PCW_APU_PERIPHERAL_FREQMHZ
F_PL = 40e6               # [M] README「时序与 FCLK 频率」：FCLK_CLK0 = 40 MHz
PL_TAP = 21.22            # [M] 前序工作流实测：PL 的 NLMS 一个样本两趟 = 21.22 拍/tap
PL_SCALAR_MAC_PER_CYCLE = 0.094   # [M] 同上：PL 标量核每拍 MAC 数

# 指令代价全部来自 Cortex-A9 TRM（ARM 100511_0401_10_en）附录 B
MLA_OCC, MLA_LAT = 2, 4        # [D] Table B-5：MUL/MLA 占 MAC 通路 2 拍、结果延迟 4 拍
SMLAxy_OCC, SMLAxy_LAT = 1, 3  # [D] Table B-5：SMULxy/SMLAxy 占 1 拍、延迟 3 拍
SMLAD_OCC, SMLAD_LAT = 1, 3    # [D] Table B-5：SMUAD/SMLAD 等 1 拍、延迟 3 拍
LDR_OCC, LDR_LAT = 1, 2        # [D] Table B-2：LDR [reg] 占 1 拍，快前递延迟 2 拍
ISSUE = 2                      # [D] TRM 1.4：superscalar，dispatch 2 条/拍
LSU = 1                        # [D] Table B-2：单拍访存一条，只有一条 L/S 通路

F_CPU_2X = F_CPU / 3           # [D] UG585 Table 25-1：6:2:1 下 CPU_2x = CPU/3，OCM 在这个域


def bound(instr, mem_ops, mac_ops, mac_occ, chain, issue=ISSUE, lsu=LSU):
    """稳态每 tap 拍数下界；instr/mem_ops/mac_ops 都是"每 tap"的计数。"""
    cand = [(-(-instr // issue), "issue"), (mem_ops, "LSU"),
            (mac_ops * mac_occ, "MAC"), (chain, "dep")]
    n, why = max(cand)
    return n, why


# 每 tap 的计数：instr 指令数、mem 访存数（load+store）、mac MAC 条数、chain 摊到的链延迟
# chain：单累加器=延迟全摊；展开 N 路=N 路摊薄（每 N tap 才轮到一次）
TIERS = [
    # 名字                            滤波趟 instr/mem/mac/chain    权更新趟
    ("T1 手写 16bit 打包+SMLAD 展开4", (3, 2, 0.5, SMLAD_LAT / 4), (4, 3, 0.5, SMLAD_LAT / 4), SMLAD_OCC),
    ("T2 手写 32bit MLA 展开2/2累加器", (4, 2, 1.0, MLA_LAT / 2), (4, 3, 1.0, MLA_LAT / 2), MLA_OCC),
    ("T3 GCC -O2 直译（单累加器）", (5, 2, 1.0, MLA_LAT), (5, 3, 1.0, MLA_LAT), MLA_OCC),
]


def main():
    print("Cortex-A9 单核标量整数吞吐模型   F_CPU = %.3f MHz   [M] ps7_config.tcl:18"
          % (F_CPU / 1e6))
    print("PL 侧同一循环 %.2f 拍/tap @ %.0f MHz   [M] 前序实测" % (PL_TAP, F_PL / 1e6))
    print()
    print("%-32s %7s %7s %7s %8s %9s" %
          ("代码形态", "滤波趟", "权更新", "合计", "MAC/拍", "MMAC/s"))

    totals = {}
    for name, f, u, occ in TIERS:
        fc, wf = bound(f[0], f[1], f[2], occ, f[3])
        uc, wu = bound(u[0], u[1], u[2], occ, u[3])
        tot = fc + uc
        totals[name] = tot
        mpc = 2.0 / tot           # 每 tap 2 个 MAC：滤波 1 + 权更新 1
        print("%-32s %7d %7d %7d %8.3f %9.1f" %
              (name, fc, uc, tot, mpc, mpc * F_CPU / 1e6))
        print("%-32s %7s %7s" % ("", "卡 " + wf, "卡 " + wu))
    print()

    print("纯 MAC 上限（只有滤波趟，每 tap 一次 16x16 乘加）:")
    for name, occ, mpt in [("32-bit MLA（占 MAC 通路 2 拍）", 2, 1),
                           ("16-bit SMLAxy（占 1 拍）", 1, 1),
                           ("16-bit SMLAD（一条 = 2 个 MAC，占 1 拍）", 1, 2)]:
        peak = mpt / occ
        print("  %-40s %5.2f MAC/拍  %7.1f MMAC/s/核  %7.1f 双核" %
              (name, peak, peak * F_CPU / 1e6, 2 * peak * F_CPU / 1e6))
    print("  注：SMLAD 每次要 2 笔 load（x 对 + w 对）→ 被 1 条/拍访存卡到 1 MAC/拍；")
    print("      只有操作数复用（系数广播/SMLAL）才能到 2 MAC/拍。")
    print()

    lo = min(totals.values())
    hi = max(totals.values())
    mid = 6.0                     # [E] 手写 5 与 -O2 8 之间取整
    print("NLMS 两趟（滤波趟+权更新趟）每 tap 拍数：手写最优 %d、合理手写 %d、-O2 直译 %d"
          % (lo, totals["T2 手写 32bit MLA 展开2/2累加器"], hi))
    print("  中值取 %.0f 拍/tap，区间 %d-%d（上界含寄存器溢出/未展开的 1.5x 惩罚）"
          % (mid, lo, int(hi * 1.5)))
    mpc = 2.0 / mid
    print("  → 单核 %.0f MMAC/s（16-bit MAC 计）  双核 %.0f MMAC/s"
          % (mpc * F_CPU / 1e6, 2 * mpc * F_CPU / 1e6))
    print("  → 每 tap 时间 PS %.1f ns vs PL %.0f ns  →  PS 单核快 %.0f 倍"
          % (mid / F_CPU * 1e9, PL_TAP / F_PL * 1e9,
             (PL_TAP / F_PL) / (mid / F_CPU)))
    print("  → PL 标量核 %.2f MMAC/s，PS 单核是它 %.0f 倍"
          % (PL_SCALAR_MAC_PER_CYCLE * F_PL / 1e6,
             mpc * F_CPU / (PL_SCALAR_MAC_PER_CYCLE * F_PL)))
    print("  → PL 计划 32 lane @40MHz：峰值 %.0f MMAC/s，估 50%% 利用率 %.0f MMAC/s"
          % (32 * F_PL / 1e6, 0.5 * 32 * F_PL / 1e6))
    print()

    # 关 cache：每 tap 2 笔访存。L1 命中 1 拍/笔（吞吐），OCM 读延迟 ~20-31 拍（第三方实测）
    print("关 D-cache、数据留 OCM（每 tap 2 笔访存）:")
    for lat in (20, 25, 31):
        print("  OCM 读延迟 %2d 拍 → 滤波趟 %.0f 拍/tap（访存不重叠的保守算法）"
              % (lat, 2 * lat))
    print("  对 L1 命中时的 2 拍/tap 是 %.0fx 的掉速；若允许 4 笔未完成重叠，约 %.0fx"
          % (2 * 25 / 2.0, 2 * 25 / 4.0 / 2.0))
    print("  参考延迟（第三方实测/文档，800 MHz 下）：L1 ~4、L2 ~20-31、OCM ~20-31、DDR ~88 拍")

    # 自检：模型要真的取到最大值，换算要对得上
    assert bound(5, 2, 1, MLA_OCC, MLA_LAT)[0] == 4          # 单累加器卡 MLA 延迟
    assert bound(4, 2, 1, MLA_OCC, MLA_LAT / 2)[0] == 2      # 展开2 后三项都到 2
    assert bound(4, 3, 1, SMLAD_OCC, SMLAD_LAT / 4)[0] == 3  # 权更新趟卡 LSU
    assert abs(PL_TAP / F_PL * 1e9 - 530.5) < 0.1
    assert abs(1.0 / MLA_OCC * F_CPU / 1e6 - 333.3) < 0.1    # 32-bit MLA 峰值 MMAC/s
    print("\nself-check OK")


if __name__ == "__main__":
    main()
