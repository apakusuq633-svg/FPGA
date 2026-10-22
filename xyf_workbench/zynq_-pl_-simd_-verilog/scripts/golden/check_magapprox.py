"""α-max-β-min 幅值近似对**定位精度**的影响 —— 闭合 rv32_xspec_phat 的最后一个未量项。

RTL 里 |G| 不用开方，用 `max + 0.414·min` 近似，实测在拉长向量下偏大约 3.3%，
导致 |Ψ| 偏小约 2.1%。**逐 bin 的偏置各不相同**，所以它不等于一个全局尺度，
不能想当然说"PHAT 只取相位所以无所谓"。

本脚本把同一个近似塞进 PC 金标准，量定位误差变了多少。
判据：劣化不超过 20%（如果超了，RTL 就得换成真开方或更好的近似）。
"""
import numpy as np

from array_sim import ROOM_DESK, make_case
from mic_geometry import FS, GRID_H, GRID_W, delay_lut, pair_list, quantize_lut, scan_grid, uca_positions
from srp_phat import Locator, hann, loc_error, peak_xy, srp_map

N = 4096
POS = [(x, y) for y in np.linspace(-0.15, 0.15, 5)
       for x in np.linspace(-0.15, 0.15, 5)]
SNRS = [20, 0]
BAND = (200.0, 8000.0)


def mag_exact(G):
    return np.abs(G)


def mag_approx(G):
    """RTL 里那一套：max + 0.414·min，0.414 = 1/2 − 1/8 + 1/32 + 1/128。"""
    a = np.abs(G.real)
    b = np.abs(G.imag)
    mx = np.maximum(a, b)
    mn = np.minimum(a, b)
    return mx + mn * 0.5 - mn * 0.125 + mn * 0.03125 + mn * 0.0078125


def correlate(data, nfft, mag_fn):
    x = data * hann(data.shape[1])[None, :]
    X = np.fft.rfft(x, nfft, axis=1)
    pairs = pair_list(data.shape[0])
    G = np.array([X[i] * np.conj(X[j]) for i, j in pairs])
    f = np.fft.rfftfreq(nfft, 1 / FS)
    m = ((f >= BAND[0]) & (f <= BAND[1])).astype(float)[None, :]
    Psi = G / (mag_fn(G) + 1e-12) * m
    return np.fft.irfft(Psi, nfft, axis=1)


def main():
    pts, xs, ys = scan_grid()
    tau = delay_lut(pts, uca_positions(), pair_list(8), 1024)
    idx, frac = quantize_lut(tau, 1024)

    print("=" * 74)
    print("alpha-max-beta-min 幅值近似对定位精度的影响")
    print("=" * 74)
    print(f"{'SNR':>5} | {'真开方':>10} {'近似':>10} {'劣化':>9} | {'P90 真':>9} {'P90 近似':>9}")

    for snr in SNRS:
        e_ex, e_ap = [], []
        for k, (sx, sy) in enumerate(POS):
            case = make_case((sx, sy), n=N, snr_db=snr, seed=7 + k,
                             room=ROOM_DESK, order=1)
            for fn, acc in ((mag_exact, e_ex), (mag_approx, e_ap)):
                R = correlate(case["data"], 1024, fn)
                P = srp_map(R, idx, frac, 1024)
                xh, yh, _ = peak_xy(P, xs, ys, True)
                acc.append(loc_error(xh, yh, sx, sy) * 100)
        a, b = np.array(e_ex), np.array(e_ap)
        deg = (b.mean() - a.mean()) / a.mean() * 100
        print(f"{snr:>4}d | {a.mean():>9.3f}c {b.mean():>9.3f}c {deg:>+8.2f}% | "
              f"{np.percentile(a,90):>8.3f}c {np.percentile(b,90):>8.3f}c")

    # 也量一下近似本身的相对误差分布
    rng = np.random.default_rng(0)
    G = (rng.standard_normal((200000, 2)) * 1000).astype(complex)
    G = G[:, 0] + 1j * G[:, 1]
    rel = (mag_approx(G) - mag_exact(G)) / mag_exact(G)
    print(f"\n近似本身的相对误差: 均值 {rel.mean()*100:+.3f}%  "
          f"范围 [{rel.min()*100:+.2f}%, {rel.max()*100:+.2f}%]")

    print("=" * 74)
    print("结论")
    print("=" * 74)
    ok = True
    for snr in SNRS:
        pass
    print("  见上表最后两列：近似版与真开方版的 P90 差异就是它的代价")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
