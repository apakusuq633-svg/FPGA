"""PHAT 的三种做法对比 —— 决定 RTL 里那个归一化块到底怎么写。

README §21 把「除法/开方/归一化」列为 PL 里最难的一块，是要花资源的。
所以它值不值得做、怎么做，必须有实测数字，不能因为"文献说 PHAT 好"就实现。

三个变体
--------
  CC          普通互相关（不白化）
  PHAT-full   全带白化（教科书写法，也是最初的实现）
  PHAT-band   只对**源信号有能量的频段**白化，带外置零

判据：25 个位置 × 每档 SNR 的定位误差（mean / P90）。
"""
import os

import numpy as np

from array_sim import ROOM_DESK, make_case
from mic_geometry import (C, FS, GRID_H, GRID_W, N_PAIR, delay_lut, pair_list,
                          quantize_lut, scan_grid, uca_positions)
from srp_phat import hann, peak_xy, srp_map

N_FRAME = 4096
NFFT = 1024
POS = [(x, y) for y in np.linspace(-0.15, 0.15, 5)
       for x in np.linspace(-0.15, 0.15, 5)]
SNRS = [40, 30, 20, 10, 0, -10]
BAND = (200.0, 8000.0)

CONDITIONS = [
    ("无混响", dict(room=None, order=0)),
    ("一阶混响", dict(room=ROOM_DESK, order=1)),
]


def build_lut(nfft=NFFT):
    pts, xs, ys = scan_grid()
    tau = delay_lut(pts, uca_positions(), pair_list(8), nfft)
    idx, frac = quantize_lut(tau, nfft)
    return idx, frac, xs, ys


def band_mask(nfft, fs=FS, band=BAND, rfft=True):
    n = nfft // 2 + 1 if rfft else nfft
    f = np.fft.rfftfreq(nfft, 1 / fs)[:n] if rfft else np.fft.fftfreq(nfft, 1 / fs)
    return ((f >= band[0]) & (f <= band[1])).astype(float)


def correlate_bank(data, mode, nfft=NFFT):
    x = data * hann(data.shape[1])[None, :]
    X = np.fft.rfft(x, nfft, axis=1)
    pairs = pair_list(data.shape[0])
    G = np.array([X[i] * np.conj(X[j]) for i, j in pairs])       # (28, F)
    if mode == "CC":
        pass
    elif mode == "PHAT-full":
        G = G / (np.abs(G) + 1e-12)
    elif mode == "PHAT-band":
        m = band_mask(nfft)
        G = (G / (np.abs(G) + 1e-12)) * m[None, :]
    else:
        raise ValueError(mode)
    return np.fft.irfft(G, nfft, axis=1)


def locate(data, mode, idx, frac, xs, ys):
    R = correlate_bank(data, mode)
    P = srp_map(R, idx, frac, NFFT)
    return peak_xy(P, xs, ys, True)


def main():
    idx, frac, xs, ys = build_lut()
    print("=" * 76)
    print("PHAT 三变体对比 —— 定位误差 [cm]，25 个位置 × 每档 SNR")
    print(f"源信号频带 {BAND[0]:.0f}–{BAND[1]:.0f} Hz，PHAT-band 只在该带内白化")
    print("=" * 76)
    print(f"{'条件':<8} {'SNR':>5} | {'CC':>14} | {'PHAT-full':>14} | {'PHAT-band':>14}")
    print(f"{'':<8} {'':>5} | {'mean':>6}{'P90':>8} | {'mean':>6}{'P90':>8} | {'mean':>6}{'P90':>8}")

    tab = {}
    for cname, ckw in CONDITIONS:
        for snr in SNRS:
            row = {}
            for mode in ("CC", "PHAT-full", "PHAT-band"):
                errs = []
                for k, (sx, sy) in enumerate(POS):
                    case = make_case((sx, sy), n=N_FRAME, snr_db=snr, seed=7 + k, **ckw)
                    xh, yh, _ = locate(case["data"], mode, idx, frac, xs, ys)
                    errs.append(np.hypot(xh - sx, yh - sy) * 100)
                e = np.array(errs)
                row[mode] = (e.mean(), np.percentile(e, 90))
            tab[(cname, snr)] = row
            cells = " | ".join(f"{row[m][0]:>6.2f}{row[m][1]:>8.2f}"
                               for m in ("CC", "PHAT-full", "PHAT-band"))
            print(f"{cname:<8} {snr:>3} dB | {cells}")

    print()
    print("=" * 76)
    print("结论")
    print("=" * 76)
    for cname, _ in CONDITIONS:
        for mode in ("CC", "PHAT-full", "PHAT-band"):
            m = np.mean([tab[(cname, s)][mode][0] for s in SNRS])
            p = np.mean([tab[(cname, s)][mode][1] for s in SNRS])
            worst = max(tab[(cname, s)][mode][1] for s in SNRS)
            print(f"  {cname:<6} {mode:<10} 全 SNR 平均 mean={m:5.2f} P90={p:5.2f} "
                  f"最差 P90={worst:5.2f} cm")

    print()
    best = None
    for cname, _ in CONDITIONS:
        for mode in ("CC", "PHAT-full", "PHAT-band"):
            w = max(tab[(cname, s)][mode][1] for s in SNRS)
            if best is None or w < best[0]:
                best = (w, cname, mode)
    print(f"  最差情形下最好的一档: {best[2]}（{best[1]}，最差 P90 = {best[0]:.2f} cm）")

    for mode in ("CC", "PHAT-full", "PHAT-band"):
        dry = np.mean([tab[("无混响", s)][mode][0] for s in SNRS])
        rev = np.mean([tab[("一阶混响", s)][mode][0] for s in SNRS])
        print(f"  {mode:<10} 混响代价: {rev - dry:+.2f} cm "
              f"(无混响 {dry:.2f} → 混响 {rev:.2f})")

    ok = best[2] != "PHAT-full"
    print()
    print(f"PASS: 结论已定，RTL 按 {best[2]} 实现" if ok else
          "FAIL: 全带 PHAT 竟然最好，需复核")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
