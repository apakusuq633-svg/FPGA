"""SRP 空间扫描固件内核的定点模型 —— `sw/fw/fw_srp.c` 的逐位等价版本。

链路（每个网格点、每对麦克风）
------------------------------
    τ(g; i,j) = (d_i − d_j) / c · fs        单位**样点**，Q16
    P[g] += interp( R_ij, τ )               线性插值，与 RTL 同一条算术

两个"放不下"，决定了这份基线的形状
----------------------------------
1. **延迟 LUT 放不下**：规格里是 1024 格 × 28 对 × 2 B = 57 KB。所以固件只能
   按对**现算**延迟 —— 每个格点每对 2 次开方，28 对就是 56 次（若能把 8 个
   麦克风的距离缓存下来只要 8 次，但那要 16 KB，还是放不下）。
2. **P 也放不下**：32×32 的 int32 累加器是 4 KB，DTCM 腾不出连续空间。
   基线取 **16×16 = 256 点**（1 KB）。

对比的**关键量是 cycles / (格点 × 对)**，与网格大小无关 —— 所以基线照样能
折算 32×32 要多少拍。**这一点必须写进汇报口径，不能拿 16×16 的总拍数当结论。**

定点约定（与 `fw_srp.c` 一字不差）
----------------------------------
    位置单位 2^-14 m：半径 0.05 m → 819，半宽 0.2 m → 3277，平面 z 0.3 m → 4915
    d² ≤ 5.8e7（int32 安全）
    τ_q16 = (d_i − d_j) · 456
    idx = τ_q16 >> 16（算术）    frac4 = (τ_q16 >> 12) & 0xF
    i0 = idx & 1023（**不是 % —— C 的 % 对负数给负余数，Python 的给非负**）
    interp = v0 + ((v1 − v0) · frac4 >> 4)

生成物
------
    build/fw_srp_tau.hex   前 N_DUMP 个格点的 τ 打包值 (idx<<4)|frac4
    build/fw_srp_p.hex     给定 R 时前 N_PAIR_TEST 对的累加结果 P（int32）
    build/fw_srp_meta.txt  峰值格号等，便于人工核对
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fw_fft_model import twiddle_q14
from mic_geometry import (C, FS, N_MIC, delay_lut, pair_list, scan_grid,
                          uca_positions)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_TAU = os.path.join(ROOT, "build", "fw_srp_tau.hex")
OUT_P = os.path.join(ROOT, "build", "fw_srp_p.hex")
OUT_META = os.path.join(ROOT, "build", "fw_srp_meta.txt")
GCC_REF = os.path.join(ROOT, "build", "fw_gcc_ref.hex")
XCORR_REF = os.path.join(ROOT, "build", "fw_xcorr_ref.hex")

POS_SH    = 14
MIC_R_U   = 819        # 0.05 m
GRID_HALF_U = 3277     # 0.2 m
PLANE_Z_U = 4915       # 0.3 m
TAU_K     = 456

GRID_W   = 16          # 固件基线的网格（见模块头：32×32 的 P 放不下）
GRID_N   = GRID_W * GRID_W
R_LEN    = 1024
N_PAIR_TEST = 4        # 基线扫几对


def _grid_axis():
    return np.array([-GRID_HALF_U + (j * 2 * GRID_HALF_U) // (GRID_W - 1)
                     for j in range(GRID_W)], dtype=np.int64)


def mic_xy_u(i):
    """麦克风 i 的位置（2^-14 m），与 C 一样**从旋转因子表取**。"""
    re_t, im_t = twiddle_q14()
    cx = int(re_t[128 * i])
    sy = -int(im_t[128 * i])
    return (cx * MIC_R_U) >> POS_SH, (sy * MIC_R_U) >> POS_SH


def isqrt32(v):
    res = 0
    bit = 1 << 30
    while bit > v:
        bit >>= 2
    while bit != 0:
        if v >= res + bit:
            v -= res + bit
            res = (res >> 1) + bit
        else:
            res >>= 1
        bit >>= 2
    return res


def tau_q16(x_u, y_u, mi, mj):
    mxi, myi = mic_xy_u(mi)
    mxj, myj = mic_xy_u(mj)
    di = isqrt32((x_u - mxi) ** 2 + (y_u - myi) ** 2 + PLANE_Z_U ** 2)
    dj = isqrt32((x_u - mxj) ** 2 + (y_u - myj) ** 2 + PLANE_Z_U ** 2)
    return (di - dj) * TAU_K


def tau_pack(tq):
    """τ_q16 → (idx<<4)|frac4，与 C 的 srp_dump_tau 一致（16 位回绕）。"""
    return (((tq >> 16) << 4) | ((tq >> 12) & 0xF)) & 0xFFFF


def srp_scan(r_seq, mi, mj, p_acc):
    """与 C 的 srp_acc_pair 逐位等价。"""
    ax = _grid_axis()
    for gy in range(GRID_W):
        for gx in range(GRID_W):
            tq = tau_q16(int(ax[gx]), int(ax[gy]), mi, mj)
            idx = tq >> 16
            frac = (tq >> 12) & 0xF
            i0 = idx & (R_LEN - 1)
            i1 = (i0 + 1) & (R_LEN - 1)
            v0 = int(r_seq[i0]); v1 = int(r_seq[i1])
            p_acc[gy * GRID_W + gx] += v0 + (((v1 - v0) * frac) >> 4)


def load_ref(path, n):
    """读 16 位参照并**符号扩展**。

    ⚠ 固件那边 R 是 `int16_t *`，读到的就是有符号值。模型若按无符号读，
       每个负数会差 65536 —— P 还是"看着挺合理"的数，只是全错。
    """
    with open(path) as f:
        raw = [int(x, 16) for x in f.read().split()[:n]]
    return np.array([(v - 65536 if v >= 32768 else v) for v in raw],
                    dtype=np.int64)


def main():
    print("=" * 72)
    print("SRP 扫描定点模型自检（网格 %d×%d = %d 点，%d 对）"
          % (GRID_W, GRID_W, GRID_N, N_PAIR_TEST))
    print("=" * 72)

    pairs = pair_list(N_MIC)[:N_PAIR_TEST]
    ax = _grid_axis()

    # ── ① 定点 τ 对 float 金标准的误差（**定义性检查**）──────────────
    # 用规格里的 32×32 网格建金标准，再取与固件网格重合的那些点比。
    pts32, xs32, ys32 = scan_grid()
    mics = uca_positions()
    tau_f = delay_lut(pts32, mics, pair_list(N_MIC))     # (1024, 28) 样点
    idx32 = {round(float(v), 9): k for k, v in enumerate(xs32)}

    worst = 0.0
    for k, (mi, mj) in enumerate(pairs):
        for gy in range(GRID_W):
            for gx in range(GRID_W):
                # 固件网格点换算成 32×32 网格的下标（步长 31/15，非整数 —— 只在
                # 精确重合时比，其余点按 float 几何另算）
                x_u, y_u = int(ax[gx]), int(ax[gy])
                tq = tau_q16(x_u, y_u, mi, mj)
                xm, ym = x_u / (1 << POS_SH), y_u / (1 << POS_SH)
                d = np.linalg.norm(np.array([xm, ym, 0.3])[None, :] - mics, axis=1)
                tau_ref = (d[mi] - d[mj]) / C * FS
                worst = max(worst, abs(tq / 65536.0 - tau_ref))
    print("  ① τ 定点 vs float 几何: 最大误差 %.5f 样点（1 样点 = %.2f mm 声程）"
          % (worst, C / FS * 1000))
    assert worst < 0.05, "定点 τ 与 float 几何差太多，标度或几何写错了"

    # ── ② 用 GCC-PHAT 的实际输出当 R，累加 4 对 ────────────────────
    if not os.path.exists(GCC_REF):
        print("  ⚠ 找不到 %s，先跑 fw_gcc_model.py --ref" % GCC_REF)
        return 1
    r_seq = load_ref(GCC_REF, R_LEN)
    print("  ② R 取自 %s：范围 [%d, %d]" % (os.path.basename(GCC_REF),
                                            r_seq.min(), r_seq.max()))
    p_acc = np.zeros(GRID_N, dtype=np.int64)
    for mi, mj in pairs:
        srp_scan(r_seq, mi, mj, p_acc)
    argmax = int(np.argmax(p_acc))
    print("     P 范围 [%d, %d]，峰值格号 %d (x=%.1f mm, y=%.1f mm)"
          % (p_acc.min(), p_acc.max(), argmax,
             ax[argmax % GRID_W] / (1 << POS_SH) * 1000,
             ax[argmax // GRID_W] / (1 << POS_SH) * 1000))
    assert np.abs(p_acc).max() < 2**31, "P 溢出 int32"

    # ── ②b 波束形成（DAS）：同一条扫描，换一份**不白化**的互相关 ────
    das_arg, das_sum = -1, 0
    if os.path.exists(XCORR_REF):
        r_raw = load_ref(XCORR_REF, R_LEN)
        p_das = np.zeros(GRID_N, dtype=np.int64)
        for mi, mj in pairs:
            srp_scan(r_raw, mi, mj, p_das)
        das_arg = int(np.argmax(p_das))
        das_sum = int(np.sum(p_das) & 0xFFFFFFFF)
        print("     DAS: 互相关范围 [%d, %d]，P 范围 [%d, %d]，峰值格号 %d"
              % (r_raw.min(), r_raw.max(), p_das.min(), p_das.max(), das_arg))
    else:
        print("     ⚠ 找不到 %s，跳过 DAS 参照" % XCORR_REF)

    # ── ③ 出参照 ────────────────────────────────────────────────────
    os.makedirs(os.path.dirname(OUT_TAU), exist_ok=True)
    with open(OUT_TAU, "w") as f:
        for gy in range(GRID_W):
            for gx in range(GRID_W):
                tq = tau_q16(int(ax[gx]), int(ax[gy]), pairs[0][0], pairs[0][1])
                f.write("%04x\n" % tau_pack(tq))
    with open(OUT_P, "w") as f:
        for v in p_acc:
            f.write("%08x\n" % (int(v) & 0xFFFFFFFF))
    with open(OUT_META, "w", encoding="utf-8") as f:
        f.write("grid_w=%d\npairs=%s\nargmax=%d\n" % (GRID_W, pairs, argmax))
        f.write("P range=[%d,%d]\n" % (p_acc.min(), p_acc.max()))
        f.write("das_argmax=%d\ndas_sum=%d\n" % (das_arg, das_sum))
    print("  ③ 参照 -> fw_srp_tau.hex (%d 条) + fw_srp_p.hex (%d 条)"
          % (GRID_N, GRID_N))

    print("\n  自检通过：定点几何与 float 一致，累加用 GCC-PHAT 的真实输出。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
