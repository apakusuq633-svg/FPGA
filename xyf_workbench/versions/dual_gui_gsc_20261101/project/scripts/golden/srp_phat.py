"""SRP-PHAT 空间扫描 —— 对应 README §23 / §24 / §25。

    P(r) = Σ_{i<j} R_ij( τ_ij(r) )

**本文件刻意按 RTL 的结构写**（README §25）：
一次批量算 28 对互谱与 IFFT，然后对 1024 个网格点做「LUT 查表 + 累加」。
PL 里做的就是同一件事 —— 所以这里的定点化误差可以直接外推。
"""
import numpy as np

from gcc_phat import cross_spectrum_phat
from mic_geometry import (GRID_H, GRID_W, N_PAIR, delay_lut, pair_list,
                          quantize_lut, scan_grid, uca_positions)


def hann(n):
    return 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) / (n - 1))


def correlation_bank(data, nfft=1024, window=True):
    """28 对 PHAT 互谱 → IFFT → 相关库 R。返回 (28, nfft)。"""
    x = data
    if window:
        x = x * hann(data.shape[1])[None, :]
    cs = cross_spectrum_phat(x, nfft)
    return np.fft.irfft(cs, nfft, axis=1)


def srp_map(R, lut_idx, lut_frac=None, nfft=1024):
    """按 LUT 查表累加，得空间能量谱 P。返回 (P,)。

    这是 RTL 里那个 SIMD-MAC 循环的逐条对应：
        对每个网格点、每个麦克风对：取值、按小数权重插值、累加。
    """
    npair, p = R.shape[0], lut_idx.shape[0]
    pair_r = np.arange(npair)[None, :]                     # (1, 28)
    v0 = R[pair_r, lut_idx]                                # (P, 28)
    if lut_frac is not None:
        v1 = R[pair_r, (lut_idx + 1) % nfft]
        v = v0 + lut_frac * (v1 - v0)
    else:
        v = v0
    return v.sum(axis=1)


def peak_xy(P, xs, ys, sub=True):
    """从空间谱里找峰，做二维抛物线插值。返回 (x, y, 峰值)。"""
    i = int(np.argmax(P))
    iy, ix = divmod(i, GRID_W)
    if not sub:
        return xs[ix], ys[iy], P[i]

    Pm = P.reshape(GRID_H, GRID_W)

    def parab(a, b, c):
        den = a - 2 * b + c
        return 0.0 if abs(den) < 1e-30 else float(np.clip(0.5 * (a - c) / den, -0.5, 0.5))

    dx = parab(Pm[iy, ix - 1], Pm[iy, ix], Pm[iy, (ix + 1) % GRID_W]) \
        if 0 < ix < GRID_W - 1 else 0.0
    dy = parab(Pm[iy - 1, ix], Pm[iy, ix], Pm[(iy + 1) % GRID_H, ix]) \
        if 0 < iy < GRID_H - 1 else 0.0
    stepx = xs[1] - xs[0]
    stepy = ys[1] - ys[0]
    return xs[ix] + dx * stepx, ys[iy] + dy * stepy, P[i]


class Locator:
    """一次建 LUT，反复用。RTL 里 LUT 是 BRAM，这里是 numpy 数组。"""

    def __init__(self, nfft=1024, mics=None, interp=True, grid=None):
        self.nfft = nfft
        self.mics = uca_positions() if mics is None else mics
        pts, xs, ys = scan_grid() if grid is None else grid
        self.pts, self.xs, self.ys = pts, xs, ys
        tau = delay_lut(pts, self.mics, pair_list(len(self.mics)), nfft)
        self.idx, self.frac = quantize_lut(tau, nfft)
        self.interp = interp

    def locate(self, data, sub=True, window=True):
        R = correlation_bank(data, self.nfft, window)
        P = srp_map(R, self.idx, self.frac if self.interp else None, self.nfft)
        x, y, pk = peak_xy(P, self.xs, self.ys, sub)
        return {"x": x, "y": y, "peak": pk, "P": P}


def loc_error(x_hat, y_hat, x_true, y_true):
    return float(np.hypot(x_hat - x_true, y_hat - y_true))
