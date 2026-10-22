"""合成 8 通道阵列数据 —— Stage 0 的测试夹具。

README §32：第一阶段允许用扬声器模拟声源。本模块把这件事搬到 PC 上，
让定位/波束形成算法在**没有任何硬件**的情况下就有已知真值的输入。

模型
----
球面扩散 + 传播延迟 + 加性噪声：

    x_m(n) = A / d_m · s(n − d_m/c · fs) + v_m(n)

其中 A 把幅度归一到阵列中心距离处为 1，避免数值过大过小。
不做混响（第一版）；混响要在 Stage 2 上板之后才谈（README §26.6 的风险就在那里）。
"""
import numpy as np

from mic_geometry import FS, C, N_MIC, uca_positions


def _pad_for(tau_max, n):
    """给 FFT 小数延迟留够不环绕的缓冲。"""
    need = n + int(np.ceil(abs(tau_max))) + 2
    return 1 << int(np.ceil(np.log2(max(need, 16))))


def frac_delay(x, tau, n_pad=None):
    """FFT 相位法小数延迟。tau 单位样点，正 = 延迟，负 = 提前，可非整数。"""
    n = x.size
    if n_pad is None:
        n_pad = _pad_for(tau, n)
    X = np.fft.rfft(x, n_pad)
    k = np.arange(X.size)
    X = X * np.exp(-2j * np.pi * k * tau / n_pad)
    return np.fft.irfft(X, n_pad)[:n]


def source_signal(kind="noise", n=4096, fs=FS, f_lo=200.0, f_hi=8000.0, rng=None):
    """生成源信号。

    kind:
      'noise'  —— 带限白噪声（宽带，定位最常用）
      'tone'   —— 单音 + 少量谐波（模拟机械阶次）
      'chirp'  —— 扫频
    """
    rng = np.random.default_rng(0) if rng is None else rng
    t = np.arange(n) / fs
    if kind == "noise":
        w = rng.standard_normal(n)
        W = np.fft.rfft(w)
        f = np.fft.rfftfreq(n, 1 / fs)
        W[(f < f_lo) | (f > f_hi)] = 0.0
        s = np.fft.irfft(W, n)
    elif kind == "tone":
        f0 = 400.0
        s = sum(np.sin(2 * np.pi * f0 * k * t) / k for k in (1, 2, 3))
    elif kind == "chirp":
        f1 = 6000.0
        s = np.sin(2 * np.pi * (f_lo + (f1 - f_lo) * t / t[-1]) * t)
    else:
        raise ValueError(kind)
    return s / (np.abs(s).max() + 1e-12)


def propagate(src_pos, sig, mics=None, fs=FS, c=C):
    """把源信号传播到各麦。返回 (data (N,L), delays 样点 (N,), dists 米 (N,))。

    幅度按 1/d 球面扩散，并归一到「阵列中心距离 = 1」。
    """
    if mics is None:
        mics = uca_positions()
    d = np.linalg.norm(np.asarray(src_pos)[None, :] - mics, axis=1)   # (N,)
    tau = d / c * fs
    d_ref = np.linalg.norm(src_pos)
    n_pad = _pad_for(tau.max(), sig.size)
    out = np.stack([frac_delay(sig, t, n_pad) * (d_ref / dm) for t, dm in zip(tau, d)],
                   axis=0)
    return out, tau, d


def add_noise(data, snr_db, rng=None):
    """按**整体** SNR 加白噪声。snr_db = 10log10(P_sig / P_noise)。"""
    rng = np.random.default_rng(1) if rng is None else rng
    p_sig = np.mean(data ** 2)
    p_noise = p_sig / (10 ** (snr_db / 10.0))
    noise = rng.standard_normal(data.shape) * np.sqrt(p_noise)
    return data + noise


def add_interferer(data, if_pos, sig_if, mics=None, snr_db=0.0, fs=FS, c=C):
    """叠加一个**方向性干扰源**（另一只音箱）。

    README §26.6.1：GSC 的收益只在有方向性干扰源时才显出来。
    所以这个函数是 DAS vs GSC 对照实验的必要件。
    """
    if mics is None:
        mics = uca_positions()
    d = np.linalg.norm(np.asarray(if_pos)[None, :] - mics, axis=1)
    tau = d / c * fs
    d_ref = np.linalg.norm(if_pos)
    n_pad = _pad_for(tau.max(), sig_if.size)
    layer = np.stack([frac_delay(sig_if, t, n_pad) * (d_ref / dm)
                      for t, dm in zip(tau, d)], axis=0)
    p_sig = np.mean(data ** 2)
    p_if = np.mean(layer ** 2)
    layer = layer * np.sqrt(p_sig / (p_if * (10 ** (snr_db / 10.0)) + 1e-30))
    return data + layer


def make_case(src_xy, kind="noise", n=4096, snr_db=20.0, seed=0,
              mics=None, z=None, room=None, order=0):
    """一步造一个带真值的测试用例。返回 dict。

    room/order 非空时启用镜像源混响（见 image_sources）。
    """
    from mic_geometry import PLANE_Z
    if mics is None:
        mics = uca_positions()
    if z is None:
        z = PLANE_Z
    rng = np.random.default_rng(seed)
    src = np.array([src_xy[0], src_xy[1], z], dtype=float)
    sig = source_signal(kind, n, rng=rng)
    if room is None:
        data, tau, d = propagate(src, sig, mics)
    else:
        data, tau, d = propagate_reverb(src, sig, mics, room, order)
    if snr_db is not None:
        data = add_noise(data, snr_db, rng=rng)
    return {"src": src, "data": data, "tau": tau, "dists": d,
            "mics": mics, "sig": sig, "room": room, "order": order}


# ── 混响：镜像源法（一阶）──────────────────────────────────────
# PHAT 是为多径设计的（README §21）。没有混响时它体现不出价值，
# 所以 DAS vs GSC、PHAT vs 普通互相关这两组对照都必须在这个条件下做。
ROOM_DESK = {
    "x": (-0.60, 0.60),   # m
    "y": (-0.60, 0.60),
    "z": (-0.05, 0.70),   # 桌面在 −0.05，阵列架在桌面上 5 cm
}
WALL_ALPHA = 0.55         # 墙面反射系数（能量约 −5.2 dB）


def image_sources(src, room, order=1, alpha=WALL_ALPHA):
    """矩形房间的一阶镜像源。返回 [(pos(3,), 累积增益), ...]，含直射路径。"""
    bounds = [room["x"], room["y"], room["z"]]
    out = [(np.asarray(src, dtype=float), 1.0)]
    cur = [(np.asarray(src, dtype=float), 1.0)]
    for _ in range(order):
        nxt = []
        for p, w in cur:
            for ax in range(3):
                for plane in bounds[ax]:
                    q = p.copy()
                    q[ax] = 2.0 * plane - p[ax]
                    nxt.append((q, w * alpha))
        out.extend(nxt)
        cur = nxt
    return out


def propagate_reverb(src, sig, mics=None, room=None, order=1, fs=FS, c=C):
    """直射 + 一阶镜像反射。返回 (data, tau_direct, dist_direct)。

    tau/dists 只报**直射路径** —— 那才是定位的真值，混响是干扰不是信号。
    """
    if mics is None:
        mics = uca_positions()
    if room is None:
        room = ROOM_DESK
    imgs = image_sources(src, room, order)

    # 所有路径的最大延迟，一次定好 padding
    dmax = max(np.linalg.norm(p[None, :] - mics, axis=1).max() for p, _ in imgs)
    n_pad = _pad_for(dmax / c * fs, sig.size)

    data = np.zeros((mics.shape[0], sig.size))
    d_direct = np.linalg.norm(np.asarray(src)[None, :] - mics, axis=1)
    d_ref = np.linalg.norm(src)
    for p, w in imgs:
        d = np.linalg.norm(p[None, :] - mics, axis=1)
        tau = d / c * fs
        for m in range(mics.shape[0]):
            data[m] += frac_delay(sig, tau[m], n_pad) * (d_ref / d[m]) * w
    return data, d_direct / c * fs, d_direct
