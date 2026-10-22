"""GCC-PHAT 的 TDOA 精度实测 —— README §49 Experiment 5 的 PC 版。

做法：合成已知坐标的声源 → 理论 TDOA 从几何算 → GCC-PHAT 估 TDOA → 比。

**必须在有混响的条件下再量一遍。** PHAT 是为多径设计的（README §21），
无混响时它体现不出价值 —— 这个结论本身就是一条要注意的实测结果，
不能因为"文献都说 PHAT 好"就跳过。
"""
import numpy as np

from array_sim import ROOM_DESK, make_case
from gcc_phat import gcc_phat, gcc_phat_sub
from mic_geometry import C, FS, pair_list, uca_positions

SRC = (0.12, -0.08)      # 声源在扫描平面上的位置 (m)
N = 4096
SNR = 30.0

CONDITIONS = [
    ("无混响（只有直射）", dict(room=None, order=0)),
    ("一阶混响（桌面+四壁）", dict(room=ROOM_DESK, order=1)),
]


def all_tdoa(data, phat, sub):
    """全部 28 对的 TDOA。phat=是否白化，sub=是否抛物线插值。"""
    pairs = pair_list(data.shape[0])
    fn = gcc_phat_sub if sub else gcc_phat
    return np.array([fn(data[i], data[j], phat=phat)[0] for i, j in pairs])


def theoretical_tau(case):
    tau = case["tau"]
    return np.array([tau[i] - tau[j] for i, j in pair_list(len(tau))])


def run_condition(name, case_kw):
    case = make_case(SRC, kind="noise", n=N, snr_db=SNR, seed=1, **case_kw)
    ref = theoretical_tau(case)
    data = case["data"]

    print(f"\n── {name} " + "─" * (60 - len(name)))
    print(f"   理论 TDOA 跨度 {ref.min():+.2f} .. {ref.max():+.2f} 样点 "
          f"({(ref.max()-ref.min())*C/FS*1000:.1f} mm 声程)")

    res = {}
    for tag, phat, sub in [
        ("整数峰 + PHAT", True, False),
        ("整数峰 + 普通互相关", False, False),
        ("抛物线插值 + PHAT", True, True),
        ("抛物线插值 + 普通互相关", False, True),
    ]:
        e = all_tdoa(data, phat, sub) - ref
        res[tag] = np.abs(e)
        print(f"   {tag:<24} MAE={np.abs(e).mean():7.3f}  "
              f"max={np.abs(e).max():7.3f}  bias={e.mean():+7.3f}  [样点]")
    return res


def main():
    print("=" * 74)
    print(f"GCC-PHAT TDOA 精度实测   fs={FS} Hz   1 样点 = {C/FS*1000:.3f} mm 声程")
    print(f"声源真值 ({SRC[0]*1000:.0f}, {SRC[1]*1000:.0f}) mm，扫描平面 z = 300 mm")
    print(f"帧长 {N} 样点 = {N/FS*1000:.1f} ms，SNR {SNR:.0f} dB，带限 200–8000 Hz")
    print("=" * 74)

    out = {}
    for name, kw in CONDITIONS:
        out[name] = run_condition(name, kw)

    print()
    print("=" * 74)
    print("结论")
    print("=" * 74)
    for name, _ in CONDITIONS:
        r = out[name]
        best = min(r, key=lambda k: r[k].mean())
        print(f"  {name}")
        print(f"    最好一档     {best}  MAE={r[best].mean():.3f} 样点 "
              f"= {r[best].mean()*C/FS*1000:.2f} mm 声程")
        print(f"    插值的价值   整数 {r['整数峰 + PHAT'].mean():.3f} → "
              f"插值 {r['抛物线插值 + PHAT'].mean():.3f} 样点（PHAT 档）")
        print(f"    PHAT 的价值  普通 {r['抛物线插值 + 普通互相关'].mean():.3f} → "
              f"PHAT {r['抛物线插值 + PHAT'].mean():.3f} 样点（插值档）")

    print()
    dry = out[CONDITIONS[0][0]]
    rev = out[CONDITIONS[1][0]]
    phat_gain_dry = dry["抛物线插值 + 普通互相关"].mean() - dry["抛物线插值 + PHAT"].mean()
    phat_gain_rev = rev["抛物线插值 + 普通互相关"].mean() - rev["抛物线插值 + PHAT"].mean()
    print(f"  PHAT 相对普通互相关的增益：无混响 {phat_gain_dry:+.3f} 样点，"
          f"有混响 {phat_gain_rev:+.3f} 样点")
    print(f"  → PHAT {'在混响下体现价值' if phat_gain_rev > 0 else '仍然没有正收益'}"
          f"（混响下 {'改善' if phat_gain_rev > 0 else '劣化'}"
          f" {abs(phat_gain_rev)*C/FS*1000:.2f} mm 声程）")

    ok = rev["抛物线插值 + PHAT"].mean() < 0.1
    print()
    print(f"PASS: 混响下 抛物线插值+PHAT MAE = {rev['抛物线插值 + PHAT'].mean():.4f} 样点 < 0.1"
          if ok else
          f"FAIL: 混响下 MAE = {rev['抛物线插值 + PHAT'].mean():.4f} 样点，超 0.1")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
