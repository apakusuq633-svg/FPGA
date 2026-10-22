"""8 麦 UCA（r = 50 mm）的角度分辨力 vs 频率 —— 近场点扩散函数。

回答的问题：**200–8000 Hz 是处理带，不是能定位的带。** 阵列要形成波束，
孔径 D 相对波长 λ 得够大。本脚本用 mic_geometry 的真实几何、按扫描平面
z = PLANE_Z 的**近场球面波**算点扩散函数（PSF），量出 −3 dB 光斑直径，
直接和扫描区尺寸（2×GRID_HALF）比。

判据：光斑 ≥ 扫描区 → 定位退化成"整片都是峰"，那个频带对定位没贡献。

⚠ 这是**解析**结果（真实阵元坐标 + 球面波，但无混响、无噪声、无定点误差），
   不是实测。逐频带的定位精度要实测 —— README §72 的 frequency-selective SRP。
   已实测的 0.57 cm 是**宽带**（200–8000 Hz 一起）的，不能拆到单个频带上用。
"""
import numpy as np

from mic_geometry import C, GRID_HALF, N_MIC, PLANE_Z, R_UCA, aliasing_limit, uca_positions

MICS = uca_positions()
STEER = np.array([0.0, 0.0, PLANE_Z])       # 波束指向扫描区中心
APERTURE = 2.0 * R_UCA


def psf_spot(f, steer=STEER, half=GRID_HALF, n=161):
    """在扫描平面上算 PSF，返回 (−3 dB 光斑直径 mm, 栅瓣峰值 dB)。

    PSF(P) = |Σ_m exp(j2πf(τ_m(P) − τ_m(P_steer)))| / N
    """
    xs = np.linspace(-half, half, n)
    X, Y = np.meshgrid(xs, xs, indexing="xy")
    pts = np.stack([X.ravel(), Y.ravel(), np.full(X.size, PLANE_Z)], axis=1)

    d = np.linalg.norm(pts[:, None, :] - MICS[None, :, :], axis=2)      # (P, N)
    d0 = np.linalg.norm(steer[None, :] - MICS, axis=1)                  # (N,)
    phase = 2.0 * np.pi * f * (d - d0[None, :]) / C
    pat = np.abs(np.exp(1j * phase).sum(axis=1)) / len(MICS)
    psf = (pat / pat.max()).reshape(n, n)

    # 中心起沿 x 轴找 −3 dB 半径
    mid = n // 2
    r3 = None
    for k in range(mid, n):
        if psf[mid, k] <= 10 ** (-3.0 / 20.0):
            r3 = (xs[k] - xs[mid])
            break
    spot = 2.0 * r3 * 1000.0 if r3 else None

    # 栅瓣：主瓣之外（圆形掩膜 r = 1.5×主瓣半径）扫描区内的最高次峰。
    # 掩膜必须跟着光斑走 —— 固定大小的方框在高频时比主瓣还小，
    # 量到的"次峰"其实是主瓣自己的裙边（会读成 −0.0 dB，看着像完全歧义）。
    if r3:
        rr = 1.5 * r3
        X2, Y2 = np.meshgrid(xs - xs[mid], xs - xs[mid], indexing="xy")
        mask = (X2 ** 2 + Y2 ** 2) > rr ** 2
    else:
        mask = np.zeros_like(psf, dtype=bool)      # 无主瓣 → 无栅瓣可谈
        return spot, None, psf
    sidelobe = 20.0 * np.log10(max(psf[mask].max(), 1e-12)) if mask.any() else None
    return spot, sidelobe, psf


if __name__ == "__main__":
    print("=== 8 麦 UCA 的分辨力 vs 频率（近场 PSF，解析）===")
    print(f"  半径 {R_UCA*1000:.0f} mm，孔径 {APERTURE*1000:.0f} mm，"
          f"扫描平面 z = {PLANE_Z*1000:.0f} mm（±{GRID_HALF*1000:.0f} mm，"
          f"{2*GRID_HALF*1000:.0f} mm 见方）")
    print(f"  无空间混叠上限（相邻间距判据 {C/(2*2*R_UCA*np.sin(np.pi/N_MIC)):.0f} Hz）")
    print()
    print(f"{'f (Hz)':>8} {'λ (mm)':>7} {'D/λ':>6} {'光斑 (mm)':>10} {'栅瓣 (dB)':>10}  判读")
    print("-" * 76)
    for f in (200, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4482, 5000, 6000, 8000):
        spot, sl, _ = psf_spot(f)
        lam, ratio = C / f * 1000.0, APERTURE / (C / f)
        if spot is None:
            verdict = "**无方向性**（无 −3 dB 点，整片同相）"
            s_txt, sl_txt = "—", "—"
        else:
            s_txt = f"{spot:.0f}"
            sl_txt = f"{sl:.1f}" if sl is not None else "—"
            if spot >= 2 * GRID_HALF * 1000:
                verdict = "光斑 ≥ 扫描区 → 定位无效"
            elif spot >= GRID_HALF * 1000:
                verdict = "光斑 ≥ 半区 → 只能粗定位"
            elif sl is not None and sl > -3.0:
                verdict = "栅瓣与主瓣同高 → 有歧义"
            else:
                verdict = "可用"
        mark = "  ← 混叠上限" if f == 4482 else ""
        print(f"{f:>8} {lam:>7.0f} {ratio:>6.2f} {s_txt:>10} {sl_txt:>10}  {verdict}{mark}")
    print()
    print("栅瓣 = 扫描区内除主瓣外的最高次峰。−3 dB 表示和主瓣一样高（完全歧义）。")
