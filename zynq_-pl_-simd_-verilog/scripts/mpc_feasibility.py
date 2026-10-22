#!/usr/bin/env python3
"""LTV-MPC 规模可行性扫描 —— 分析脚本，不参与构建与验证。

回答一个问题：多大的 LTV-MPC 才真的需要 lane 阵列（标量核撑不住）？
纯计算量模型，不做数值仿真。所有假设集中在「假设」一节，改常量重跑即可。

跑法（WSL）：
    wsl -e python3 scripts/mpc_feasibility.py
"""

import math

# ----------------------------------------------------------------------------
# 假设
# ----------------------------------------------------------------------------

# 硬件（来自 README 实测）
FCLK = 40e6              # Hz，FCLK_CLK0，WNS +1.749 ns @ 25 ns
LANES = 32               # lane 数（16-bit MAC）
DSP_TOTAL = 80           # Zynq-7010 的 DSP48E1 总数
DSP_PER_LANE_16 = 1      # 16-bit 乘占 1 个 DSP48E1
DSP_PER_LANE_32 = 4      # 32-bit 乘要 4 个（DSP48E1 是 25x18）

# 核（乐观值：紧循环展开后的每 MAC 拍数）
CORE_CYC_PER_OP = 4

# 阵列（小矩阵下填充/排空开销大，取保守的有效利用率）
ARRAY_UTIL = 0.5

# 算法
N_IT = 15                # QP 迭代次数（内点法典型值；热启动 active-set 可到 5-10）


# ----------------------------------------------------------------------------
# 代价模型
# ----------------------------------------------------------------------------
# 各阶段用哪种形式（condensed QP）：min 1/2 U'HU + f'U  s.t. AU <= b
#   U in R^(Nc*nu) 是决策变量；nx 状态，nu 输入，ny 输出

SERIAL = 'serial'        # 串行链 / 非线性 / 分支 —— 阵列帮不上
PARALLEL = 'parallel'    # 高并行度、无数据相关分支 —— 阵列能吃


def breakdown(nx, nu, Np, Nc, ny=None):
    """返回 [(阶段名, 代价, 形式)]，代价单位是 MAC（QP 是 flop）。"""
    ny = ny or nu
    n_u = Nc * nu

    stages = [
        # 在线线性化：LTV 的根源。有限差分要 (nx+nu+1) 次 f 求值，每次 ~nx^2。
        # 串行 + 非线性，只能在核上跑。
        ('在线线性化', Np * (nx + nu + 1) * nx**2, SERIAL),
        # 累积转移矩阵 T_k = A_{k-1}...A_0。步间串行，步内是 nx^3 稠密矩阵乘。
        ('转移矩阵链', Np * nx**3, PARALLEL),
        # Gamma 构造（脉冲仿真）：Nc*nu 列彼此独立，列内前向 Np 步。
        ('Gamma 构造', Nc * nu * Np * (nx**2 + nx * nu), PARALLEL),
        # H = Gamma' Q Gamma，对称取半。纯归约、零依赖 —— 阵列主场。
        ('H = G\'QG', 0.5 * n_u**2 * Np * ny, PARALLEL),
        # f = Gamma' Q (Phi x - r)。纯归约。
        ('f = G\'Q(..)', n_u * Np * ny, PARALLEL),
        # 自由响应 Phi x。小且串行。
        ('自由响应', Np * (nx**2 + ny * nx), SERIAL),
    ]
    return stages, n_u


def qp_cost(n_u, dense_refactor=True):
    """稠密（condensed）QP 求解。分支 + 迭代，只能在核上跑。

    dense_refactor=True : 每次迭代重新 Cholesky 分解 -> O(n^3/3)
    dense_refactor=False: 只在首次分解，之后 O(n^2) downdate（热启动）
    """
    if dense_refactor:
        return N_IT * (n_u**3 / 3 + n_u**2)
    return n_u**3 / 3 + N_IT * n_u**2


def totals_sparse(nx, nu, Np, Nc, ny=None):
    """稀疏（non-condensed）形式：不构造 H/Gamma，直接对带状 KKT 做 Riccati 回代。

    这是长预测窗下的主流做法（HPIPM / qpOASES 那一类）。
    代价是 O(Np*nx^3)，与 Nc 无关；但**没有任何一步是阵列形状**。
    """
    ny = ny or nu
    lin = Np * (nx + nu + 1) * nx**2
    riccati = N_IT * Np * 5 * nx**3          # 每步约 5 个 nx^3 量级的矩阵运算
    fwd = Np * (nx**2 + nx * nu + ny * nx)
    total = lin + riccati + fwd
    return dict(array=0.0, serial=lin + fwd, qp=riccati, total=total,
                n_u=Nc * nu)


def totals(nx, nu, Np, Nc, ny=None, dense_refactor=True):
    stages, n_u = breakdown(nx, nu, Np, Nc, ny)
    arr = sum(c for _, c, f in stages if f == PARALLEL)
    ser = sum(c for _, c, f in stages if f == SERIAL)
    qp = qp_cost(n_u, dense_refactor)
    return dict(stages=stages, array=arr, serial=ser, qp=qp,
                total=arr + ser + qp, n_u=n_u)


def cycles_scalar(t):
    return (t['total']) * CORE_CYC_PER_OP


def cycles_with_array(t):
    return (t['array'] / (LANES * ARRAY_UTIL)
            + (t['serial'] + t['qp']) * CORE_CYC_PER_OP)


def max_freq(t):
    """这套规模能支撑的最高控制频率 (Hz)。"""
    return FCLK / cycles_scalar(t), FCLK / cycles_with_array(t)


# ----------------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------------

def hdr(s):
    print()
    print('=' * 78)
    print(s)
    print('=' * 78)


def human(n):
    if n >= 1e9:
        return f'{n/1e9:8.2f} G'
    if n >= 1e6:
        return f'{n/1e6:8.2f} M'
    if n >= 1e3:
        return f'{n/1e3:8.2f} K'
    return f'{n:8.1f} '


def section_breakdown():
    hdr('[1] 参考算例分解   nx=12 nu=2 ny=2 Np=60 Nc=30')
    t = totals(12, 2, 60, 30)
    print(f"{'阶段':<16}{'代价':>10}   形式")
    print('-' * 78)
    for name, c, form in t['stages']:
        tag = '阵列可用' if form == PARALLEL else '只能核上'
        print(f'{name:<16}{human(c):>10}   {tag}')
    print(f"{'QP 求解':<16}{human(t['qp']):>10}   只能核上（分支）")
    print('-' * 78)
    print(f"{'合计':<16}{human(t['total']):>10}")
    print(f"  其中阵列可用 {t['array']/t['total']*100:.1f}%"
          f"  串行 {t['serial']/t['total']*100:.1f}%"
          f"  QP {t['qp']/t['total']*100:.1f}%")
    print(f"  决策变量 n_u = Nc*nu = {t['n_u']}")


def section_amdahl():
    hdr('[2] Amdahl 上限 —— 阵列最多能加速到多少倍')
    print(f"{'规模 (nx,Np,Nc)':<20}{'阵列占比':>10}{'理论上限':>12}{'实测加速比':>14}")
    print('-' * 78)
    for nx, Np, Nc in [(4, 20, 5), (8, 40, 10), (12, 60, 20),
                       (12, 60, 30), (20, 60, 30), (20, 100, 40)]:
        t = totals(nx, 2, Np, Nc)
        frac = t['array'] / t['total']
        amdahl = 1 / (1 - frac) if frac < 1 else float('inf')
        cs, ca = cycles_scalar(t), cycles_with_array(t)
        print(f'nx={nx:<3}Np={Np:<4}Nc={Nc:<4}   {frac*100:9.1f}%{amdahl:11.2f}x'
              f'{cs/ca:13.2f}x')


def section_frontier():
    hdr('[3] 规模前沿 —— 阵列在哪些规模上是"必需"而不是"锦上添花"')
    print('对每个规模，算出纯核 / 阵列+核 能支撑的最高控制频率。')
    print('落在 "纯核不够、阵列够" 区间的，就是阵列真正必要的规模。\n')
    print(f"{'规模':<22}{'纯核':>12}{'阵列+核':>12}{'倍数':>8}   判定")
    print('-' * 78)
    targets = [100, 1e3, 1e4]
    for nx, Np, Nc in [(4, 20, 5), (6, 20, 10), (8, 40, 10), (8, 40, 20),
                       (12, 40, 20), (12, 60, 30), (16, 60, 30),
                       (20, 60, 30), (20, 100, 40), (30, 100, 40)]:
        t = totals(nx, 2, Np, Nc)
        fs, fa = max_freq(t)
        verdict = []
        for tg in targets:
            if fs < tg <= fa:
                verdict.append(f'{tg:g}Hz 必需')
        if not verdict:
            verdict = ['都不必需' if fs >= 1e4 else '都撑不住']
        print(f'nx={nx:<3}Np={Np:<4}Nc={Nc:<4}   {fs:11.0f}{fa:12.0f}'
              f'{fa/fs:7.2f}x   {" ".join(verdict)}')


def section_reverse():
    hdr('[4] 必需窗口 —— 阵列在哪些规模上是"纯核不够、它才够"')
    print('假设 nu=2、Np=4*Nc。三种判定：')
    print('  够   = 纯核自己能撑住 -> 阵列不必要')
    print('  必需 = 纯核不够、阵列够 -> 阵列有存在理由')
    print('  --   = 两个都不够       -> 这套硬件做不了这个规模\n')
    NCS = [5, 10, 15, 20, 30, 40]
    NXS = [4, 8, 12, 16, 20]
    for fc in [100, 500, 1e3, 5e3, 1e4]:
        budget = FCLK / fc
        print(f'--- {fc:g} Hz（周期 {budget:.0f} 拍）---')
        print('        ' + ''.join(f'nx={x:<6}' for x in NXS))
        for Nc in NCS:
            row = f'Nc={Nc:<4}  '
            for nx in NXS:
                t = totals(nx, 2, 4 * Nc, Nc)
                ok_s = cycles_scalar(t) <= budget
                ok_a = cycles_with_array(t) <= budget
                cell = '够' if ok_s else ('必需' if ok_a else '--')
                row += f'{cell:<9}'
            print(row)
        print()
    print('ROP: "必需" 的格子就是阵列唯一有存在理由的规模区间。')
    print('     如果整张表没有"必需"，说明该频率下阵列是多余的或没用的。')


def section_width():
    hdr('[5] 位宽与 DSP 预算')
    for bits, per in [(16, DSP_PER_LANE_16), (32, DSP_PER_LANE_32)]:
        need = LANES * per
        print(f'{bits}-bit lane: {LANES} lane x {per} DSP = {need} DSP '
              f'(+4 个 M 扩展) = {need+4}/{DSP_TOTAL}  '
              f'{"够" if need+4 <= DSP_TOTAL else "★ 不够"}')
    print()
    print('ROP: MPC 的 H 矩阵条件数通常 1e3~1e6，定点求解要 4~5 位十进制有效位。')
    print('     16-bit 只给 ~4.5 位，且 QP 迭代会累积误差 —— 16-bit 大概率不够。')


def section_formulation():
    hdr('[6] 公式选择 —— 阵列唯一能吃的那部分，只在 condensed 形式里存在')
    print('condensed: 显式构造 H = Gamma\'QGamma，稠密 QP。大 Nc 时 QP 按 n_u^3 爆炸。')
    print('sparse   : 不构造 H，Riccati 回代，O(Np*nx^3)，但与阵列形状完全不符。\n')
    print(f"{'规模':<24}{'condensed 总代价':>17}{'阵列占比':>10}"
          f"{'sparse 总代价':>16}{'阵列占比':>10}")
    print('-' * 78)
    for nx, Np, Nc in [(4, 20, 5), (8, 40, 10), (12, 40, 20),
                       (12, 60, 30), (20, 60, 30), (20, 100, 40)]:
        c = totals(nx, 2, Np, Nc)
        s = totals_sparse(nx, 2, Np, Nc)
        print(f'nx={nx:<3}Np={Np:<4}Nc={Nc:<5}   {human(c["total"]):>15}'
              f'{c["array"]/c["total"]*100:9.1f}%{human(s["total"]):>16}'
              f'{0.0:9.1f}%')


def section_qp_solver():
    hdr('[7] QP 求解器选择 —— 最大的单一杠杆')
    print(f'固定 nx=8 nu=2 ny=2 Np=40，只改 QP 算法。\n')
    print(f"{'Nc':>5}{'n_u':>6}{'每次重分解':>14}{'热启动+downdate':>18}"
          f"{'稀疏 Riccati':>16}")
    print('-' * 78)
    for Nc in [5, 10, 20, 30, 40]:
        n_u = Nc * 2
        a = qp_cost(n_u, True)
        b = qp_cost(n_u, False)
        c = N_IT * 40 * 5 * 8**3
        print(f'{Nc:>5}{n_u:>6}{human(a):>14}{human(b):>18}{human(c):>16}')
    print()
    print('ROP: 热启动 + downdate 能把 QP 降一个量级，但它要求相邻周期的 active set')
    print('     基本不变 —— 这正是闭环控制成立的前提，所以是合理假设。')


def section_sensitivity():
    hdr('[8] 敏感度 —— 两个最不确定的假设')
    print('规模固定 nx=8 nu=2 ny=2 Np=40 Nc=10，扫描两个旋钮。\n')
    print(f"{'核 拍/MAC':>10}{'阵列利用率':>12}{'纯核最高频率':>14}"
          f"{'阵列+核':>12}{'倍数':>8}")
    print('-' * 78)
    base_cyc = CORE_CYC_PER_OP
    base_util = ARRAY_UTIL
    globals()['CORE_CYC_PER_OP'] = 0
    try:
        for cyc in [3, 4, 6, 8]:
            for util in [0.3, 0.5, 0.8]:
                globals()['CORE_CYC_PER_OP'] = cyc
                globals()['ARRAY_UTIL'] = util
                t = totals(8, 2, 40, 10)
                fs, fa = max_freq(t)
                print(f'{cyc:>10}{util:>12.1f}{fs:>14.0f}{fa:>12.0f}'
                      f'{fa/fs:>7.2f}x')
    finally:
        globals()['CORE_CYC_PER_OP'] = base_cyc
        globals()['ARRAY_UTIL'] = base_util


def main():
    section_breakdown()
    section_amdahl()
    section_frontier()
    section_reverse()
    section_width()
    section_formulation()
    section_qp_solver()
    section_sensitivity()
    print()


if __name__ == '__main__':
    main()
