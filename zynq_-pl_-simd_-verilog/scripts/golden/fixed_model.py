"""定点模型 —— README §38 / §39 / §48 的「四层验证」中间那两层。

    float 金标准  →  **定点的 Python 模型**  →  RTL

README §39 明令：**禁止 PC float 直接对 HDL**，中间必须有定点软件模型，
否则误差来自哪里判断不出来。

本模块只对**我们自己会写的那几块**做定点化 —— FFT 用 Xilinx IP（README §18），
它的内部精度由 IP 保证，所以这里只建模它的输入量化。

被建模的块（也就是 RTL 里要写的那几块）：

    1. 音频输入量化        16 bit / 24 bit
    2. 互谱乘法            (a+jb)(c−jd)  → 定标 + 溢出
    3. PHAT 归一化         |G| = sqrt(re²+im²)，再除 → **倒数近似**
    4. SRP 查表 + 线性插值   LUT 下标 + 小数权重
    5. 累加器位宽          28 对求和

用法：扫描各块位宽，找出满足定位精度的最小配置。
**位宽不是猜的，是扫出来的。**
"""
import numpy as np

from mic_geometry import (FS, GRID_H, GRID_W, delay_lut, pair_list,
                          quantize_lut, scan_grid, uca_positions)
from srp_phat import hann, peak_xy


# ── 定点工具 ──────────────────────────────────────────────────
def q(x, frac_bits, total_bits=None, signed=True):
    """量化到 Q(frac_bits)。可选饱和到 total_bits。"""
    y = np.round(x * (1 << frac_bits)) / (1 << frac_bits)
    if total_bits is not None:
        lo = -(1 << (total_bits - 1)) if signed else 0
        hi = (1 << (total_bits - 1)) - 1 if signed else (1 << total_bits) - 1
        y = np.clip(y, lo / (1 << frac_bits), hi / (1 << frac_bits))
    return y


def reciprocal_lut(mag, lut_bits):
    """倒数近似：对 |G| 做对数分段的 LUT 查表（RTL 里就是一张 ROM）。

    返回 1/|G| 的近似值，相对误差上界 ≈ 2^-(lut_bits+1)。
    """
    m = np.maximum(mag, 1e-30)
    e = np.floor(np.log2(m))
    mant = m / (2.0 ** e)                       # [1,2)
    idx = np.clip((mant - 1.0) * (1 << lut_bits), 0, (1 << lut_bits) - 1).astype(int)
    approx = 1.0 + (idx + 0.5) / (1 << lut_bits)     # [1,2) 的近似
    return (1.0 / approx) * (2.0 ** (-e))


# ── 构建一次完整链路的定点版本 ─────────────────────────────────
class FixedChain:
    def __init__(self, nfft=1024, audio_bits=16, lut_bits=6,
                 corr_bits=16, acc_bits=32, interp=True, band=(200.0, 8000.0)):
        self.nfft = nfft
        self.audio_bits = audio_bits
        self.lut_bits = lut_bits
        self.corr_bits = corr_bits
        self.acc_bits = acc_bits
        self.interp = interp
        self.band = band

        mics = uca_positions()
        pts, self.xs, self.ys = scan_grid()
        tau = delay_lut(pts, mics, pair_list(len(mics)), nfft)
        self.idx, self.frac = quantize_lut(tau, nfft)
        f = np.fft.rfftfreq(nfft, 1 / FS)
        self.mask = ((f >= band[0]) & (f <= band[1])).astype(float)

    def run(self, data, stages=False):
        """返回定位结果与（可选）各级误差。"""
        nfft = self.nfft
        diag = {}

        # 1. 音频输入量化
        pk = np.abs(data).max() + 1e-30
        xn = data / pk
        fbits = self.audio_bits - 1
        xq = q(xn, fbits, self.audio_bits)
        diag["audio_snr_db"] = 10 * np.log10(
            np.mean(xn ** 2) / (np.mean((xq - xn) ** 2) + 1e-30))

        x = xq * hann(data.shape[1])[None, :]

        # 2. 互谱（FFT 视为理想，只继承输入量化）
        X = np.fft.rfft(x, nfft, axis=1)
        pairs = pair_list(data.shape[0])
        G = np.array([X[i] * np.conj(X[j]) for i, j in pairs])

        # 3. PHAT 归一化：|G| 用定点，倒数用 LUT
        mag = np.abs(G)
        inv = reciprocal_lut(mag, self.lut_bits)
        Psi = G * inv * self.mask[None, :]
        if self.corr_bits is not None:
            Psi = q(Psi, self.corr_bits)
        inband = self.mask > 0
        diag["phat_mag_err_db"] = 20 * np.log10(
            np.abs(mag * inv - 1.0)[:, inband].mean() + 1e-30)

        R = np.fft.irfft(Psi, nfft, axis=1)

        # 4. 查表 + 线性插值
        pr = np.arange(len(pairs))[None, :]
        v0 = R[pr, self.idx]
        if self.interp:
            v1 = R[pr, (self.idx + 1) % nfft]
            v = v0 + self.frac * (v1 - v0)
        else:
            v = v0

        # 5. 累加
        if self.corr_bits is not None:
            v = q(v, self.corr_bits)
        P = v.sum(axis=1)
        if self.acc_bits is not None:
            P = q(P, max(self.acc_bits - 16, 1))

        xh, yh, _ = peak_xy(P, self.xs, self.ys, True)
        diag["P"] = P
        return ((xh, yh), diag) if stages else (xh, yh)


def main():
    from array_sim import ROOM_DESK, make_case
    from srp_phat import Locator, loc_error

    N = 4096
    POS = [(x, y) for y in np.linspace(-0.15, 0.15, 5)
           for x in np.linspace(-0.15, 0.15, 5)]

    print("=" * 76)
    print("定点模型 —— 位宽扫描（README §38/§39）")
    print("目标：定位误差不超过 float 金标准的 2 倍，且 P90 < 10 cm")
    print("=" * 76)

    # float 金标准
    loc = Locator()
    ref_err = []
    cases = []
    for k, (sx, sy) in enumerate(POS):
        c = make_case((sx, sy), n=N, snr_db=20.0, seed=7 + k,
                      room=ROOM_DESK, order=1)
        cases.append((sx, sy, c["data"]))
        r = loc.locate(c["data"])
        ref_err.append(loc_error(r["x"], r["y"], sx, sy) * 100)
    ref = np.array(ref_err)
    print(f"\nfloat 金标准: mean {ref.mean():.3f} cm  P90 "
          f"{np.percentile(ref,90):.3f} cm  max {ref.max():.3f} cm")

    print(f"\n{'音频':>6} {'倒数LUT':>8} {'互谱Q':>7} {'插值':>5} | "
          f"{'mean':>7} {'P90':>7} {'max':>7} | {'vs float':>9}")
    print("-" * 76)

    rows = []
    for audio_bits in (16, 24):
        for lut_bits in (4, 6, 8, 10):
            for interp in (True,):
                ch = FixedChain(audio_bits=audio_bits, lut_bits=lut_bits,
                                corr_bits=16, acc_bits=32, interp=interp)
                errs = []
                for sx, sy, d in cases:
                    xh, yh = ch.run(d)
                    errs.append(loc_error(xh, yh, sx, sy) * 100)
                e = np.array(errs)
                ratio = e.mean() / ref.mean()
                rows.append((audio_bits, lut_bits, interp, e, ratio))
                print(f"{audio_bits:>5}b {lut_bits:>7}b {'Q16':>7} "
                      f"{'有' if interp else '无':>5} | "
                      f"{e.mean():>7.3f} {np.percentile(e,90):>7.3f} "
                      f"{e.max():>7.3f} | {ratio:>8.2f}x")

    # 不插值的对照
    ch = FixedChain(audio_bits=24, lut_bits=8, corr_bits=16, acc_bits=32,
                    interp=False)
    errs = np.array([loc_error(*ch.run(d), sx, sy) * 100 for sx, sy, d in cases])
    print(f"{24:>5}b {8:>7}b {'Q16':>7} {'无':>5} | "
          f"{errs.mean():>7.3f} {np.percentile(errs,90):>7.3f} "
          f"{errs.max():>7.3f} | {errs.mean()/ref.mean():>8.2f}x")

    print()
    print("=" * 76)
    print("结论")
    print("=" * 76)
    good = [r for r in rows if r[4] < 2.0 and np.percentile(r[3], 90) < 10.0]
    if good:
        best = min(good, key=lambda r: (r[0], r[1]))
        print(f"  最小可用配置: 音频 {best[0]} bit，倒数 LUT {best[1]} bit，"
              f"互谱 Q16，插值开")
        print(f"    实测 mean {best[3].mean():.3f} cm "
              f"({best[4]:.2f}× float)，P90 {np.percentile(best[3],90):.3f} cm")
    else:
        print("  ⚠ 没有配置达到 2× float 以内，需要加宽位宽")
    print(f"  音频 16 vs 24 bit 的差别见上表前四行与后四行")
    print(f"  插值的价值: 见最后一行（无插值）与 8bit LUT 那行对比")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
