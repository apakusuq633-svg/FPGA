"""GCC-PHAT —— 对应 README §20 / §21。

    Ψ_ij(f) = X_i(f) X_j*(f) / (|X_i(f) X_j*(f)| + ε) · M(f)
    R_ij(τ) = IFFT{Ψ_ij(f)}

峰值位置 τ̂ = τ_i − τ_j（样点），与 mic_geometry 的 TDOA 约定一致。

⚠ **白化必须限带** —— `M(f)` 那个掩码不是可选项。
全带白化会把源信号没有能量的频段（那里只有混响残余和数值噪声）抬到与信号同权，
在相关域造出跨对一致的伪结构，28 对求和时反而叠加。
实测：全带 PHAT 在 40 dB 混响下把定位误差从 0.85 cm 劣化到 5.32 cm，
限带后是 0.56 cm。详见 `docs/issues/027`。

掩码在 RTL 里就是几个 bin 下标的比较，不用乘法器。
"""
import numpy as np

EPS = 1e-12

# 工作频带：源信号有能量的范围（README §17 的带通）
BAND_LO = 200.0
BAND_HI = 8000.0


def band_mask(nfft, fs=None, lo=BAND_LO, hi=BAND_HI):
    """rfft 长度的频段掩码，带内 1 带外 0。"""
    from mic_geometry import FS
    f = np.fft.rfftfreq(nfft, 1 / (FS if fs is None else fs))
    return ((f >= lo) & (f <= hi)).astype(float)


def gcc_phat(x, y, nfft=None, phat=True):
    """返回 (tau_hat 样点, R 相关序列 (nfft,), lags 样点 (nfft,))。

    tau_hat > 0 表示 x 比 y **晚** tau_hat 个样点到达。
    """
    n = max(x.size, y.size)
    if nfft is None:
        nfft = 1 << int(np.ceil(np.log2(2 * n)))
    X = np.fft.rfft(x, nfft)
    Y = np.fft.rfft(y, nfft)
    G = X * np.conj(Y)
    if phat:
        G = G / (np.abs(G) + EPS)
    R = np.fft.irfft(G, nfft)
    lags = np.arange(nfft)
    lags = np.where(lags >= nfft // 2, lags - nfft, lags)
    k = int(np.argmax(R))
    return lags[k], R, lags


def gcc_phat_sub(x, y, nfft=None, phat=True):
    """带抛物线插值，返回**小数**样点延迟。"""
    _, R, lags = gcc_phat(x, y, nfft, phat)
    nfft = R.size
    k = int(np.argmax(R))
    km, kp = (k - 1) % nfft, (k + 1) % nfft
    ym, y0, yp = R[km], R[k], R[kp]
    denom = (ym - 2 * y0 + yp)
    delta = 0.0 if abs(denom) < EPS else 0.5 * (ym - yp) / denom
    delta = float(np.clip(delta, -0.5, 0.5))
    lag = lags[k] + delta
    return lag, R, lags


def tdoa_matrix(data, pairs=None, nfft=None, sub=True):
    """对所有麦克风对算 TDOA。返回 (NPAIR,) 样点。"""
    from mic_geometry import pair_list
    if pairs is None:
        pairs = pair_list(data.shape[0])
    fn = gcc_phat_sub if sub else gcc_phat
    out = np.empty(len(pairs))
    for k, (i, j) in enumerate(pairs):
        out[k] = fn(data[i], data[j], nfft)[0]
    return out


def cross_spectrum_phat(data, nfft=1024, band=True, lo=BAND_LO, hi=BAND_HI):
    """一次性算全部 28 对的 PHAT 互谱，供 SRP 复用（省重复 FFT）。

    返回 (NPAIR, nfft//2+1) 复数。
    **band=True 是默认，也是唯一正确的用法** —— 见模块头与 docs/issues/027。
    """
    from mic_geometry import pair_list
    N = data.shape[0]
    X = np.fft.rfft(data, nfft, axis=1)
    pairs = pair_list(N)
    out = np.empty((len(pairs), X.shape[1]), dtype=complex)
    m = band_mask(nfft, lo=lo, hi=hi)[None, :] if band else 1.0
    for k, (i, j) in enumerate(pairs):
        G = X[i] * np.conj(X[j])
        out[k] = (G / (np.abs(G) + EPS)) * m
    return out
