"""DAS 与 GSC —— 对应 README §26。

本模块**刻意按 RTL 的结构写**：

    DAS:  对齐(延迟线) → 求和
    GSC:  对齐(延迟线) → 固定波束形成 d(n)
                       → 阻塞矩阵 u_j
                       → 7 路 NLMS 抵消器 → e(n) = d(n) − y(n)

所以这里的每个数组形状、每次累加，都能在 RTL 里找到对应的一拍。
定点化误差因此可以直接外推（README §39 的四层验证）。

⚠ GSC 的收益**不是必然的**（README §26.6）。它的收益只在有方向性干扰源时
才显出来，而且在混响下可能输给 DAS。所有结论以 check_bf.py 的实测为准。
"""
import numpy as np

from array_sim import _pad_for, frac_delay
from mic_geometry import C, FS, N_MIC, uca_positions


def steering_delays(src_pos, mics=None, fs=FS, c=C):
    """各麦的传播到达延迟（样点）。"""
    if mics is None:
        mics = uca_positions()
    d = np.linalg.norm(np.asarray(src_pos, dtype=float)[None, :] - mics, axis=1)
    return d / c * fs, d


def align_channels(data, src_pos, mics=None, fs=FS, c=C):
    """把各通道对齐到同一波前。

    **因果实现**：补的是 `τ_max − τ_m ≥ 0`，即把早到的通道延迟到最晚那个。
    RTL 里这就是一串延迟线，不需要未来样点。

    返回 (aligned (N,L), comp 补偿量 (N,) 样点)。
    """
    tau, _ = steering_delays(src_pos, mics, fs, c)
    comp = tau.max() - tau
    n_pad = _pad_for(float(comp.max()) + 1.0, data.shape[1])
    out = np.stack([frac_delay(data[m], comp[m], n_pad)
                    for m in range(data.shape[0])])
    return out, comp


# ── DAS ────────────────────────────────────────────────────────
def das_from_aligned(aligned, weights=None):
    """固定波束形成：等权（或按 SNR 加权）求和。"""
    n = aligned.shape[0]
    w = np.full(n, 1.0 / n) if weights is None else np.asarray(weights) / np.sum(weights)
    return w @ aligned


def das(data, src_pos, mics=None):
    aligned, comp = align_channels(data, src_pos, mics)
    return das_from_aligned(aligned), aligned, comp


# ── GSC ────────────────────────────────────────────────────────
class GSC:
    """广义旁瓣抵消器（README §26.3）。

    固定波束形成器 C  → d(n)
    阻塞矩阵 B        → u_0..u_{N-2}   （成对相减，最省的那版）
    自适应抵消器 W    → e(n) = d(n) − Σ_j w_jᵀ u_j(n)
    NLMS 更新         → w_j += μ g e u_j / (δ + Σ_j‖u_j‖²)
    """

    def __init__(self, n_mic=N_MIC, taps=64, mu=0.05, delta=1e-3,
                 leak=0.0, weight_limit=None, gate=True, gate_thresh=3.5,
                 gate_floor=0.0):
        self.n_mic = n_mic
        self.n_ref = n_mic - 1          # 成对相减出 N−1 路
        self.L = taps
        self.mu = mu
        self.delta = delta
        self.leak = leak                # leaky LMS 系数，0 = 不泄漏
        self.weight_limit = weight_limit
        self.gate = gate                # Fault-Preserving 式的门控
        self.gate_thresh = gate_thresh
        self.gate_floor = gate_floor
        self.W = np.zeros((self.n_ref, self.L))
        self.hist_mu = []

    # -- 阻塞矩阵：成对相减（README §26.3.2 第一版）
    @staticmethod
    def blocking(aligned):
        return aligned[:-1] - aligned[1:]

    def _gate_gain(self, d, state):
        """按输出峭度降步长，防止把目标信号学掉（README §26.6）。

        这里用**递推峭度**，RTL 里对应一个滑动统计块（README §13 of NoiseGuard）。
        """
        if not self.gate:
            return 1.0
        x = d - state["mean"]
        state["mean"] += 1e-4 * x
        v = x * x
        state["m2"] += 1e-4 * (v - state["m2"])
        state["m4"] += 1e-4 * (v * v - state["m4"])
        if state["m2"] < 1e-20:
            return 1.0
        kurt = state["m4"] / (state["m2"] ** 2)
        g = 1.0 - (kurt - 3.0) / self.gate_thresh
        return float(np.clip(g, self.gate_floor, 1.0))

    def run(self, aligned, gate_src=None, record_w=False):
        """跑一遍 GSC。返回 (e, d, info)。

        aligned   : (N, L) —— 对齐后的通道
        gate_src  : 门控统计取自哪一路（默认用固定波束形成输出 d）
        record_w  : 是否记录**权值轨迹**（分离目标/干扰分量时必需）

        记录轨迹的理由：GSC 是时变的，"把同一个波束形成器作用到目标分量和
        干扰分量上"这句话对时变系统只有在知道了 W(n) 之后才成立。
        所以 SNR 的分子分母都是拿**同一条 W(n) 轨迹**算出来的，不是估的。
        """
        d = das_from_aligned(aligned)              # 固定波束形成
        u = self.blocking(aligned)                 # (n_ref, L)
        n = d.shape[0]
        e = np.zeros(n)
        self.W = np.zeros((self.n_ref, self.L))
        state = {"mean": 0.0, "m2": 1.0, "m4": 3.0}
        gs = np.ones(n)
        W_hist = np.zeros((n, self.n_ref, self.L)) if record_w else None
        gsrc = d if gate_src is None else gate_src

        for i in range(n):
            lo = max(0, i - self.L + 1)
            hi = i + 1
            m = hi - lo
            U = np.zeros((self.n_ref, self.L))     # 新样点在前，未满补零
            U[:, :m] = u[:, lo:hi][:, ::-1]

            e[i] = d[i] - float(np.sum(self.W * U))

            g = self._gate_gain(gsrc[i], state)
            gs[i] = g

            nrm = self.delta + float(np.sum(U * U))
            # NLMS：w_j += μ·g·e·u_j / (δ + Σ_j‖u_j‖²)，逐抽头
            self.W = (1.0 - self.leak) * self.W + self.mu * g * e[i] * U / nrm
            if self.weight_limit is not None:
                np.clip(self.W, -self.weight_limit, self.weight_limit, out=self.W)
            if record_w:
                W_hist[i] = self.W

        info = {"d": d, "u": u, "gate": gs, "w_norm": np.linalg.norm(self.W)}
        if record_w:
            info["W_hist"] = W_hist
        return e, d, info

    @staticmethod
    def apply_trajectory(aligned, W_hist, L=None):
        """把一条**已记录的权值轨迹**作用到另一组通道上。

        用于把 GSC 的输出分解成「目标的贡献」和「干扰的贡献」，
        从而算出真实的输出 SNR。返回 (e (n,), d (n,))。
        """
        d = das_from_aligned(aligned)
        u = GSC.blocking(aligned)
        n = d.shape[0]
        L = u.shape[1] if L is None else L
        e = np.zeros(n)
        for i in range(n):
            lo = max(0, i - L + 1)
            hi = i + 1
            m = hi - lo
            U = np.zeros((u.shape[0], L))
            U[:, :m] = u[:, lo:hi][:, ::-1]
            e[i] = d[i] - float(np.sum(W_hist[i] * U))
        return e, d
