"""SRP-PHAT 定位精度实测 —— 回答 README §0.3 的**假设①**。

判据（README §45）：定位误差 < 10 cm 算成功。
本脚本把这件事量出来：单点、位置扫描、SNR 扫描、有/无混响。

输出
----
- 控制台表格（mean / median / P90）
- results/localization/*.png 热力图与曲线
- results/localization/summary.txt 存档
"""
import os
import sys

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from array_sim import ROOM_DESK, make_case
from mic_geometry import FS, PLANE_Z, GRID_W, GRID_H
from srp_phat import Locator, loc_error

N_FRAME = 4096
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "results", "localization")

# 声源位置扫描：±150 mm 内 5×5
POS = [(x, y) for y in np.linspace(-0.15, 0.15, 5)
       for x in np.linspace(-0.15, 0.15, 5)]
SNRS = [30, 20, 10, 0, -10]

CONDITIONS = [
    ("无混响", dict(room=None, order=0)),
    ("一阶混响", dict(room=ROOM_DESK, order=1)),
]


def stats(errs):
    e = np.asarray(errs) * 100.0   # → cm
    return dict(mean=e.mean(), median=np.median(e),
                p90=np.percentile(e, 90), max=e.max())


def sweep_positions(loc, cond_kw, snr, seed=7):
    errs = []
    for k, (sx, sy) in enumerate(POS):
        case = make_case((sx, sy), n=N_FRAME, snr_db=snr, seed=seed + k, **cond_kw)
        r = loc.locate(case["data"])
        errs.append(loc_error(r["x"], r["y"], sx, sy))
    return errs


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = []

    def out(s=""):
        print(s)
        lines.append(s)

    out("=" * 74)
    out(f"SRP-PHAT 定位精度实测   判据: 误差 < 10 cm (README §45)")
    out(f"fs={FS} Hz  扫描平面 z={PLANE_Z*1000:.0f} mm  {GRID_W}×{GRID_H} 网格")
    out(f"帧长 {N_FRAME} 样点 = {N_FRAME/FS*1000:.1f} ms，声源扫描 ±150 mm 5×5")
    out("=" * 74)

    loc = Locator()

    # ── 1. 单点热力图 ────────────────────────────────────────
    src = (0.12, -0.08)
    case = make_case(src, n=N_FRAME, snr_db=20.0, seed=1, room=ROOM_DESK, order=1)
    r = loc.locate(case["data"])
    e = loc_error(r["x"], r["y"], *src) * 100
    out(f"\n单点: 真值 ({src[0]*1000:+.0f}, {src[1]*1000:+.0f}) mm  "
        f"→ 估计 ({r['x']*1000:+.0f}, {r['y']*1000:+.0f}) mm  误差 {e:.2f} cm")

    fig, ax = plt.subplots(figsize=(5.2, 4.4))
    P = r["P"].reshape(GRID_H, GRID_W)
    half = 200
    im = ax.imshow(P / P.max(), origin="lower", extent=[-half, half, -half, half],
                   cmap="inferno", aspect="equal")
    ax.plot(src[0] * 1000, src[1] * 1000, "c+", ms=14, mew=2, label="真值")
    ax.plot(r["x"] * 1000, r["y"] * 1000, "wo", ms=7, mfc="none", mew=1.5, label="估计")
    ax.set_xlabel("x [mm]"); ax.set_ylabel("y [mm]")
    ax.set_title(f"SRP-PHAT 空间谱（误差 {e:.1f} cm）")
    ax.legend(loc="upper right", fontsize=8)
    fig.colorbar(im, ax=ax, label="归一化能量")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "srp_single.png"), dpi=130)
    plt.close(fig)

    # ── 2. SNR 扫描 ─────────────────────────────────────────
    out("\n" + "=" * 74)
    out("SNR 扫描（25 个位置 × 每档 SNR）")
    out("=" * 74)
    out(f"{'条件':<10} {'SNR':>6} {'mean':>8} {'median':>8} {'P90':>8} {'max':>8}   [cm]")
    snr_tab = {}
    for cname, ckw in CONDITIONS:
        for snr in SNRS:
            s = stats(sweep_positions(loc, ckw, snr))
            snr_tab[(cname, snr)] = s
            out(f"{cname:<10} {snr:>4} dB {s['mean']:>8.2f} {s['median']:>8.2f} "
                f"{s['p90']:>8.2f} {s['max']:>8.2f}")

    # ── 3. 位置扫描（逐个点看有没有盲区）──────────────────────
    out("\n" + "=" * 74)
    out("位置扫描：真值 (x,y) mm → 误差 cm   [一阶混响, SNR 20 dB]")
    out("=" * 74)
    grid_err = np.zeros((5, 5))
    for k, (sx, sy) in enumerate(POS):
        case = make_case((sx, sy), n=N_FRAME, snr_db=20.0, seed=7 + k,
                         room=ROOM_DESK, order=1)
        r = loc.locate(case["data"])
        grid_err[k // 5, k % 5] = loc_error(r["x"], r["y"], sx, sy) * 100
    out("        " + "".join(f"{x*1000:>9.0f}" for x in np.linspace(-0.15, 0.15, 5)))
    for i, y in enumerate(np.linspace(-0.15, 0.15, 5)):
        out(f"y={y*1000:>5.0f}  " + "".join(f"{v:>9.2f}" for v in grid_err[i]))
    out(f"\n  这一档: mean={grid_err.mean():.2f}  max={grid_err.max():.2f} cm")

    # ── 4. 结论 ─────────────────────────────────────────────
    out("\n" + "=" * 74)
    out("结论 —— 假设①（定位精度 < 10 cm）")
    out("=" * 74)
    key = ("一阶混响", 20)
    s20 = snr_tab[key]
    ok20 = s20["p90"] < 10.0
    s0 = snr_tab[("一阶混响", 0)]
    ok0 = s0["p90"] < 10.0
    out(f"  20 dB: mean {s20['mean']:.2f} cm, P90 {s20['p90']:.2f} cm  "
        f"{'✅ PASS' if ok20 else '❌ FAIL'} (P90 < 10 cm)")
    out(f"   0 dB: mean {s0['mean']:.2f} cm, P90 {s0['p90']:.2f} cm  "
        f"{'✅ PASS' if ok0 else '❌ FAIL'}")
    lo = snr_tab[("一阶混响", -10)]
    out(f" -10 dB: mean {lo['mean']:.2f} cm, P90 {lo['p90']:.2f} cm  "
        f"{'✅' if lo['p90'] < 10 else '❌ 已到极限'}")

    out("\n  曲线：")
    for cname, _ in CONDITIONS:
        row = " ".join(f"{snr_tab[(cname, s)]['mean']:6.2f}" for s in SNRS)
        out(f"    {cname:<8} SNR {' '.join(f'{s:>6}' for s in SNRS)}")
        out(f"    {'':<8} mean {row}  cm")

    fig, ax = plt.subplots(figsize=(5.6, 3.6))
    for cname, _ in CONDITIONS:
        ax.semilogy(SNRS, [snr_tab[(cname, s)]["mean"] for s in SNRS], "o-", label=cname)
    ax.axhline(10, color="r", ls="--", lw=1, label="10 cm 判据")
    ax.set_xlabel("SNR [dB]"); ax.set_ylabel("平均定位误差 [cm]")
    ax.set_title("SRP-PHAT 定位误差 vs SNR")
    ax.grid(True, which="both", alpha=0.3); ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "srp_vs_snr.png"), dpi=130)
    plt.close(fig)

    path = os.path.join(OUT_DIR, "summary.txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"\n存档: {os.path.normpath(path)}")
    print(f"图:   {os.path.normpath(OUT_DIR)}/srp_single.png, srp_vs_snr.png")

    return 0 if ok20 else 1


if __name__ == "__main__":
    raise SystemExit(main())
