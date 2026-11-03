"""DAS vs GSC 对照 —— 回答 README §0.3 的**假设③**（README §49 Experiment 11）。

必须分两组做（§26.6.1）：

  组一  只有弥散噪声        → 预期两者差不多
  组二  加方向性干扰源      → 预期 GSC 明显赢

怎么测 SNR 才是真的
------------------
GSC 是**时变**的，所以"把同一个波束形成器作用到目标分量和干扰分量上"
这句话只有在拿到 W(n) 轨迹之后才成立。做法：

  1. 分别合成 目标 / 干扰 / 噪声，按**同一目标方位**对齐
  2. 混合后跑 GSC，**记录 W(n) 轨迹**
  3. 用同一条轨迹分别作用到「目标分量」和「其余分量」上
  4. SNR_out = P(e_目标) / P(e_其余)

分子分母来自同一条轨迹，不是估的。

三个口径都要报：单麦 → DAS → GSC。单麦是"什么都不做"的基线，
DAS 是"做空间滤波但不自适应"，GSC 是"加了闭环"。

GSC 给了它最好的机会：μ 和抽头数都扫描取最优。**不能拿一个没调好的 GSC 去比。**
"""
import os

import numpy as np

from array_sim import ROOM_DESK, propagate_reverb, source_signal
from beamform import GSC, align_channels, das_from_aligned
from mic_geometry import FS, PLANE_Z, uca_positions

N = 8192
TARGET = (0.12, -0.08)
INTERF = (-0.18, 0.12)
MIC_SNR_NOISE = 30.0     # 麦上 目标 : 噪声
MIC_SNR_INTERF = 0.0     # 麦上 目标 : 干扰（0 dB = 一样响，GSC 才有事可做）
TAPS_SWEEP = [128, 256]
MU_SWEEP = [0.002, 0.005, 0.01, 0.02, 0.05]
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "results", "beamform")


def _z(x, y):
    return np.array([x, y, PLANE_Z])


def _scale_to(ref, sig, snr_db):
    """把 sig 定标到比 ref 低 snr_db（功率比）。"""
    p_ref, p_sig = np.mean(ref ** 2), np.mean(sig ** 2)
    return sig * np.sqrt(p_ref / (p_sig * 10 ** (snr_db / 10.0) + 1e-30))


def build(seed=3):
    """合成三个分量，都按目标方位对齐。返回 dict。"""
    mics = uca_positions()
    t_sig = source_signal("noise", N, rng=np.random.default_rng(seed))
    i_sig = source_signal("noise", N, rng=np.random.default_rng(seed + 100))

    t_raw, _, _ = propagate_reverb(_z(*TARGET), t_sig, mics, ROOM_DESK, 1)
    i_raw, _, _ = propagate_reverb(_z(*INTERF), i_sig, mics, ROOM_DESK, 1)
    n_raw = np.random.default_rng(seed + 7).standard_normal((mics.shape[0], N))

    i_raw = _scale_to(t_raw, i_raw, MIC_SNR_INTERF)
    # 噪声按「单麦上」定标，与对齐无关
    n_raw = _scale_to(t_raw, n_raw, MIC_SNR_NOISE)

    return {
        "mics": mics,
        "a_t": align_channels(t_raw, _z(*TARGET), mics)[0],
        "a_i": align_channels(i_raw, _z(*TARGET), mics)[0],
        "a_n": align_channels(n_raw, _z(*TARGET), mics)[0],
    }


def db(sig, other):
    return 10.0 * np.log10(np.mean(sig ** 2) / (np.mean(other ** 2) + 1e-30))


def run_group(name, parts, with_interf):
    other = parts["a_n"] + (parts["a_i"] if with_interf else 0.0)
    mix = parts["a_t"] + other

    # 基线：单麦（对齐后不做任何空间处理）
    base = db(parts["a_t"][0], other[0])

    # DAS：固定权值，线性时不变
    das = db(das_from_aligned(parts["a_t"]), das_from_aligned(other))

    # GSC：μ × 抽头数 扫描取最优
    best = None
    for taps in TAPS_SWEEP:
        for mu in MU_SWEEP:
            g = GSC(taps=taps, mu=mu, delta=1e-3, gate=False)
            _, _, info = g.run(mix, record_w=True)
            et, _ = GSC.apply_trajectory(parts["a_t"], info["W_hist"], taps)
            eo, _ = GSC.apply_trajectory(other, info["W_hist"], taps)
            o = db(et, eo)
            if best is None or o > best[0]:
                best = (o, mu, taps, info)

    gsc, mu, taps, info = best
    print(f"\n── {name} " + "─" * (54 - len(name)))
    print(f"   单麦      {base:+7.2f} dB   （基线）")
    print(f"   DAS       {das:+7.2f} dB   改善 {das - base:+6.2f} dB")
    print(f"   GSC       {gsc:+7.2f} dB   改善 {gsc - base:+6.2f} dB   "
          f"(μ={mu}, L={taps})")
    print(f"   → GSC 相对 DAS  {gsc - das:+6.2f} dB")
    return dict(base=base, das=das, gsc=gsc, gain=gsc - das, mu=mu, taps=taps)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    parts = build()
    print("=" * 74)
    print("DAS vs GSC 对照  (README §49 Experiment 11 / §26.6)")
    print(f"目标 ({TARGET[0]*1000:+.0f},{TARGET[1]*1000:+.0f}) mm   "
          f"干扰 ({INTERF[0]*1000:+.0f},{INTERF[1]*1000:+.0f}) mm")
    print(f"帧长 {N} 样点 = {N/FS*1000:.0f} ms，一阶混响")
    print(f"麦上 目标:干扰 = {MIC_SNR_INTERF:.0f} dB，目标:噪声 = {MIC_SNR_NOISE:.0f} dB")
    print("=" * 74)

    g1 = run_group("组一  只有弥散噪声", parts, with_interf=False)
    g2 = run_group("组二  加方向性干扰源", parts, with_interf=True)

    print()
    print("=" * 74)
    print("结论 —— 假设③（GSC 有收益）")
    print("=" * 74)
    print(f"  组一（无方向性干扰）  GSC 相对 DAS {g1['gain']:+6.2f} dB   "
          f"（预期 ≈0，实测{'符合' if abs(g1['gain']) < 1.0 else '偏离'}）")
    print(f"  组二（有方向性干扰）  GSC 相对 DAS {g2['gain']:+6.2f} dB   "
          f"← 有意义的那个数")
    print()
    print(f"  DAS 相对单麦:  组一 {g1['das']-g1['base']:+.2f} dB，"
          f"组二 {g2['das']-g2['base']:+.2f} dB")
    print(f"  GSC 相对单麦:  组一 {g1['gsc']-g1['base']:+.2f} dB，"
          f"组二 {g2['gsc']-g2['base']:+.2f} dB")

    ok = g2["gain"] > 1.0
    print()
    print(f"PASS: 有干扰时 GSC 领先 DAS {g2['gain']:+.2f} dB" if ok else
          f"结果: 有干扰时 GSC {'领先' if g2['gain']>0 else '落后'} "
          f"{abs(g2['gain']):.2f} dB")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
