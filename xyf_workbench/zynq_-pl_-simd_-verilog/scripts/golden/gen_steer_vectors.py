"""为 rv32_steer（定位 → 波束指向）生成 LUT 与**逐位精确**的参照。

这根箭头要解决的事
------------------
SRP 报出"声源在第 g 格"，波束形成必须朝那一格转。朝 (x,y) 转的补偿是

    comp_m = τmax − τ_m          τ_m = 格点到第 m 个麦的传播延迟（样点）

── 关键：comp 能从 SRP 现成的 7 对延迟直接推出来，不必重算几何 ────────────
`fw_srp.c` 的约定是 τ_ij = τ_i − τ_j（同一格点的两个距离相减）。于是

    comp_m − comp_0 = τ_0 − τ_m = τ_{0m}          （第 (0,m) 对的 SRP 延迟）
    comp_0          = −min_j τ_{0j}                （因为 min_m comp_m ≡ 0）
    ⇒  comp_m = τ_{0m} − min_j τ_{0j}              m = 0..7，只用 7 对 (0,1)..(0,7)

所以转向块**不需要 isqrt、不需要除法**，只查 7 次表 + 一次求最小。
本脚本第 ① 段把这个恒等式**当场验一遍**（用真几何，逐点）。

⚠ 存的是**有符号** τ，不是 SRP 那种绕回的无符号 idx
--------------------------------------------------
`gen_srp_vectors.py` 为 rv32_srp_scan 存 `idx = floor(τ) mod NFFT`（无符号、绕回），
因为 SRP 只拿它当**相关序列的下标**。转向要的是 τ 的**真值**（要做减法求 min），
绕回就毁了。所以这里存 `idx = τ_q16 >> 16`（算术右移，可负，10 位补码）
加 4 位小数，还原式 `τ = (signed(idx,10) << 16) + (frac4 << 12)`。

⚠ 还原会把 τ 截到 **1/16 样点**（向下取整）。参照**必须走同一条还原**，
否则比的是"截断误差"而不是"实现是否正确" —— 两侧同源是这份参照的全部意义。

输出（写到 build/）
  steer_lut.hex        N_PAIR_STEER*N_GRID 条，14 位 {idx[9:0], frac[3:0]}
  steer_comp_ref.hex   每个格点 8 条 int32（Q16 样点）—— 逐格逐路的参照
  steer_meta.txt       恒等式自检结果与范围，便于人工核对
"""
import os

import numpy as np

from mic_geometry import (FS, C, N_MIC, delay_lut, pair_list, scan_grid,
                          uca_positions)

NFFT = 1024
GRID_W = 16                 # 与 SoC 里 rv32_srp_scan 的档位一致（4 对 × 16×16）
N_GRID = GRID_W * GRID_W
Q = 16
FRAC_BITS = 4
IDX_W = 10
N_PAIR_STEER = N_MIC - 1    # (0,1)..(0,7) = 7 对
OUT = os.path.join(os.path.dirname(__file__), "..", "..", "build")


def q16(tau):
    """浮点样点 -> Q16 整数，四舍五入（与 fw_das_model.q16 同一口径）。"""
    return np.floor(np.asarray(tau, float) * (1 << Q) + 0.5).astype(np.int64)


def pack(t):
    """Q16 -> 14 位 (idx<<4)|frac4。idx 是**算术右移**，可负。"""
    idx = t >> Q
    frac = (t >> (Q - FRAC_BITS)) & 0xF
    return ((idx & ((1 << IDX_W) - 1)) << FRAC_BITS) | frac


def unpack(p):
    """14 位 -> Q16。idx 按 10 位**符号扩展**（这是与绕回口径的分水岭）。"""
    idx = p >> FRAC_BITS
    if idx >= (1 << (IDX_W - 1)):
        idx -= (1 << IDX_W)
    frac = p & 0xF
    return (idx << Q) + (frac << (Q - FRAC_BITS))


def main():
    mics = uca_positions()
    pts, xs, ys = scan_grid(GRID_W, GRID_W)

    # 只用 (0,m) 这 7 对 —— 这正是 comp 的推导式所需
    pairs = [(0, m) for m in range(1, N_MIC)]
    tau = delay_lut(pts, mics, pairs, NFFT)          # (N_GRID, 7) = τ_0 − τ_m

    # τ_{00} ≡ 0，补在最前面，得到 m = 0..7
    t0m = np.concatenate([np.zeros((N_GRID, 1)), tau], axis=1)

    # ── ① 恒等式自检：comp_m = τ_{0m} − min_j τ_{0j} 是否等于 τmax − τ_m ──
    d = np.linalg.norm(pts[:, None, :] - mics[None, :, :], axis=2)   # (P, N)
    tau_abs = d / C * FS
    comp_def = tau_abs.max(axis=1, keepdims=True) - tau_abs
    comp_der = t0m - t0m.min(axis=1, keepdims=True)
    worst = float(np.abs(comp_der - comp_def).max())
    print("① 恒等式 comp_m = tau_0m - min_j tau_0j  vs  定义 taumax - tau_m")
    print("   %d 个格点最大差 = %.3e 样点（= %.3e Q16 LSB）"
          % (N_GRID, worst, worst * (1 << Q)))
    assert worst < 1e-9, "comp 推导式不成立 —— RTL 设计的地基没了"
    assert abs(float(comp_der.min())) < 1e-12, "min_m comp_m 必须恒为 0"

    # ── ② 量化 + 打包 ─────────────────────────────────────────────────
    T = q16(t0m)                                     # (N_GRID, 8) Q16 真值
    packed = np.array([[pack(int(v)) for v in row] for row in T], dtype=np.int64)

    # 参照：**用还原后的值**算 comp，与 RTL 逐步同源（不是用浮点答案当参照）
    Tu = np.array([[unpack(int(p)) for p in row] for row in packed], dtype=np.int64)
    comp_ref = Tu - Tu.min(axis=1, keepdims=True)
    assert comp_ref.min() >= 0

    # 还原误差（截到 1/16 样点）—— 报出来，免得日后误当成实现错
    trunc = np.abs(Tu - T).max()
    print("② 量化：τ 范围 [%d, %d] Q16（= %.2f .. %.2f 样点）"
          % (T.min(), T.max(), T.min() / 2**Q, T.max() / 2**Q))
    print("   还原截断（1/16 样点）最大 %d Q16 = %.4f 样点" % (trunc, trunc / 2**Q))
    print("   comp 参照范围 [%d, %d] Q16（= %.2f .. %.2f 样点）"
          % (comp_ref.min(), comp_ref.max(),
             comp_ref.min() / 2**Q, comp_ref.max() / 2**Q))

    # ── ③ 出文件 ──────────────────────────────────────────────────────
    os.makedirs(OUT, exist_ok=True)
    lut_path = os.path.join(OUT, "steer_lut.hex")
    with open(lut_path, "w") as fh:
        for m in range(8):
            for g in range(N_GRID):
                fh.write("%04x\n" % int(packed[g, m]))

    comp_path = os.path.join(OUT, "steer_comp_ref.hex")
    with open(comp_path, "w") as fh:
        for g in range(N_GRID):
            for m in range(8):
                fh.write("%08x\n" % (int(comp_ref[g, m]) & 0xFFFFFFFF))

    meta_path = os.path.join(OUT, "steer_meta.txt")
    with open(meta_path, "w", encoding="utf-8") as fh:
        fh.write("grid_w=%d\nn_grid=%d\nn_pair=%d\n"
                 % (GRID_W, N_GRID, N_PAIR_STEER))
        fh.write("identity_worst_samples=%.3e\n" % worst)
        fh.write("comp_range_q16=[%d,%d]\n" % (comp_ref.min(), comp_ref.max()))
        fh.write("tau_range_q16=[%d,%d]\n" % (T.min(), T.max()))
        # 抽查中心格与一个边角格，便于人工核对
        for g in (0, N_GRID // 2, N_GRID - 1):
            fh.write("grid %d (x=%.1fmm y=%.1fmm) comp=" % (
                g, xs[g % GRID_W] * 1000, ys[g // GRID_W] * 1000))
            fh.write(" ".join("%d" % v for v in comp_ref[g]) + "\n")

    print("③ 写出 %s（%d 条）、%s（%d 条）"
          % (os.path.basename(lut_path), packed.size,
             os.path.basename(comp_path), comp_ref.size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
