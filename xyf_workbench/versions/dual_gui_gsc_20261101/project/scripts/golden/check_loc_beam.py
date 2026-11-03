"""定位 → 定向增强：把中间那根箭头接上（README §26.1 / §26.5）。

    8 通道 → SRP-PHAT 定位 θ̂ → 迟滞 + 渐变控制器 → DAS 朝 θ̂ 对齐求和 → 输出 SNR

── 这份脚本要回答的问题 ────────────────────────────────────────────────────
"SRP 算出的那一格，有没有真的去告诉波束形成该往哪转？"

在此之前这条链是断的：`check_srp.py` 定位、`check_bf.py` 增强，
但**两个脚本之间没有数据流** —— `check_bf.py:34` 的 TARGET 写死，
DAS 永远朝同一个方向对齐，和 SRP 报什么无关。
所以"定位 -> 增强"这句话在代码里一次都没被验证过。

── 判据必须能失败 ─────────────────────────────────────────────────────────
如果只有一个"接上了、增益不错"的数，那这个数**证明不了箭头接上了** ——
把转向随便钉一个方向也可能碰巧还不错。所以这里给四组：

  正例    朝 θ̂ 对齐      增益 ≈ 朝真值对齐的增益
  反例 A  朝固定错向对齐  增益必须**塌**    ← 「箭头没接」的等价物
  反例 B  源移动、转向钉死（= 今天 check_bf.py 的行为）→ 源走远则增益塌
  迟滞    单帧跳变不得推动 committed θ̂；持续移位必须推动
  渐变    逐帧补偿变化量必须**小于**不渐变时的整段跳变

反例 A 是关键：**若反例 A 也拿到增益，说明这个测量根本没在量"转向"**。

── 频带前提（§0.3.5，不能省）──────────────────────────────────────────────
8 麦 UCA 只在 ≈ 4–8 kHz 有方向性（PSF 解析，`array_band.py`）。
所以窄带 4–8 kHz 与宽带 200 Hz–8 kHz **两组都报**，且不能互相代替：
宽带里 4 kHz 以下那段不贡献位置、只稀释增益。
"""
import os
import sys

import numpy as np

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from array_sim import ROOM_DESK, source_signal, propagate_reverb
from beamform import align_channels, das_from_aligned, steering_delays
from mic_geometry import FS, PLANE_Z, GRID_W, GRID_H, uca_positions
from srp_phat import Locator, loc_error

N_FRAME = 4096
TARGET = (0.12, -0.08)          # 目标声源（真值）
INTERF = (-0.18, 0.12)          # 方向性干扰源
FIXED = TARGET                  # "转向钉死"用的方向 = 今天 check_bf.py 写死的那个

SNR_INTERF_DB = 0.0             # 麦上 目标:干扰（0 dB 才有事可做）
SNR_NOISE_DB = 30.0             # 麦上 目标:噪声

BAND_WIDE = (200.0, 8000.0)     # §0.3.1 基线口径
BAND_NARROW = (4000.0, 8000.0)  # §0.3.5 唯一有方向性的那段

POS_5x5 = [(x, y) for y in np.linspace(-0.15, 0.15, 5)
           for x in np.linspace(-0.15, 0.15, 5)]

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "results", "beamform")


def _z(x, y):
    return np.array([x, y, PLANE_Z])


def _scale_to(ref, sig, snr_db):
    """把 sig 定标到比 ref 低 snr_db（功率比）。与 check_bf.py 同一口径。"""
    p_ref, p_sig = np.mean(ref ** 2), np.mean(sig ** 2)
    return sig * np.sqrt(p_ref / (p_sig * 10 ** (snr_db / 10.0) + 1e-30))


def build_scene(target_xy=TARGET, interf_xy=INTERF, n=N_FRAME, seed=0,
                band=BAND_WIDE, room=ROOM_DESK, order=1,
                snr_interf_db=SNR_INTERF_DB):
    """合成场景，**分量分开留着** —— SNR 的分子分母必须是同一套对齐下的分量。

    分开留的理由与 check_bf.py:53-72 一样：DAS 是线性的，所以
    "把同一个波束形成器作用到目标分量 / 其余分量上" 成立，
    前提是两个分量用的是**同一份转向补偿**（见 below 的同一 comp 断言）。
    """
    mics = uca_positions()
    t_sig = source_signal("noise", n, f_lo=band[0], f_hi=band[1],
                          rng=np.random.default_rng(seed))
    i_sig = source_signal("noise", n, f_lo=band[0], f_hi=band[1],
                          rng=np.random.default_rng(seed + 100))
    t_raw, _, _ = propagate_reverb(_z(*target_xy), t_sig, mics, room, order)
    i_raw, _, _ = propagate_reverb(_z(*interf_xy), i_sig, mics, room, order)
    n_raw = np.random.default_rng(seed + 7).standard_normal((mics.shape[0], n))

    i_raw = _scale_to(t_raw, i_raw, snr_interf_db)
    n_raw = _scale_to(t_raw, n_raw, SNR_NOISE_DB)
    return {"t": t_raw, "o": i_raw + n_raw,
            "data": t_raw + i_raw + n_raw, "mics": mics}


def db(sig, other):
    return 10.0 * np.log10(np.mean(sig ** 2) / (np.mean(other ** 2) + 1e-30))


def snr_out(parts, steer_xy):
    """朝 steer_xy 对齐后的输出 SNR（dB）。单麦基线同法，取第 0 路。

    ⚠ 两个分量必须用**同一份补偿**。comp 只由 steer_xy 决定、与 data 无关
      （beamform.align_channels 内部就是这么算的），所以这里对两个分量
      各调一次 align_channels 是等价的 —— 但断言一次更保险。
    """
    a_t, c_t = align_channels(parts["t"], _z(*steer_xy), parts["mics"])
    a_o, c_o = align_channels(parts["o"], _z(*steer_xy), parts["mics"])
    assert np.allclose(c_t, c_o), "两个分量拿到的转向补偿必须相同"
    return db(das_from_aligned(a_t), das_from_aligned(a_o)), db(a_t[0], a_o[0])


def comp_of(steer_xy, mics=None):
    """朝 steer_xy 的 8 路补偿（样点）—— §26.5.1 渐变作用的就是这个量。"""
    tau, _ = steering_delays(_z(*steer_xy), mics)
    return tau.max() - tau


# ══ §26.5.2 目标方位迟滞 ════════════════════════════════════════════════════
class SteerController:
    """EMPTY → CANDIDATE → ACTIVE → HOLD → RELEASE → EMPTY（README §26.5.2）。

    为什么需要它：θ̂ 逐帧抖动，波束跟着来回摆会让后面的自适应滤波器反复重新收敛
    （§26.5.2 原话）。所以"连续若干帧稳定在同一区域"才切过去；
    短暂跳走进 HOLD，不立即释放。
    """

    def __init__(self, cell_tol=0.030, cand_frames=3, hold_frames=5):
        self.cell_tol = cell_tol          # 同一个"区域"的判据（m）≈ 2.3 个格距
        self.cand_frames = cand_frames
        self.hold_frames = hold_frames
        self.reset()

    def reset(self):
        self.state = "EMPTY"
        self.cand = None
        self.cand_cnt = 0
        self.away_cnt = 0
        self.committed = None
        self.log = []

    def _near(self, a, b):
        return a is not None and b is not None and \
            np.hypot(a[0] - b[0], a[1] - b[1]) <= self.cell_tol

    def update(self, det):
        """喂一帧的定位结果 det=(x,y) 或 None。返回当前 committed（或 None）。"""
        if self.state == "EMPTY":
            if det is not None:
                self.cand, self.cand_cnt, self.state = det, 1, "CANDIDATE"

        elif self.state == "CANDIDATE":
            if self._near(det, self.cand):
                self.cand_cnt += 1
                # 取候选窗内的最新位置：真值缓慢移动时也要跟得上
                self.cand = det
                if self.cand_cnt >= self.cand_frames:
                    self.committed, self.state = det, "ACTIVE"
            else:
                self.cand, self.cand_cnt = det, 1     # 换了个地方，重新数

        elif self.state == "ACTIVE":
            if self._near(det, self.committed):
                self.committed = det
            else:
                self.away_cnt, self.state = 1, "HOLD"

        elif self.state == "HOLD":
            # 短暂跳走进 HOLD，**不立即释放**；跳回来就回 ACTIVE
            if self._near(det, self.committed):
                self.away_cnt, self.state = 0, "ACTIVE"
            else:
                self.away_cnt += 1
                if self.away_cnt >= self.hold_frames:
                    self.state = "RELEASE"

        elif self.state == "RELEASE":
            self.committed, self.cand, self.cand_cnt = None, None, 0
            self.state = "EMPTY"
            if det is not None:                       # 同帧可以重新起候选
                self.cand, self.cand_cnt, self.state = det, 1, "CANDIDATE"

        self.log.append(self.state)
        return self.committed


def ramp_at(cur0, tgt, step, k):
    """§26.5.1 指向渐变：第 k 帧（k 从 0 起）的补偿。

    README 写的是 `0% → 20% → 40% → 60% → 80% → 100%` —— 这是**线性**推进：
    每帧走 step 比例的**整段**，5 帧走满。
    ⚠ 别写成 `cur += step·(tgt−cur)`（指数逼近）：那样永远差最后一点，
      残差 0.8^k 收敛不到 0 —— 第一版就是这么写的，被判据抓出来了。
    step<=0 = 立即到位（README："0 = 立即到位"）。
    """
    cur0 = np.asarray(cur0, float)
    tgt = np.asarray(tgt, float)
    if step <= 0.0:
        return tgt.copy()
    f = min(1.0, (k + 1) * step)
    return cur0 + f * (tgt - cur0)


# ══ 主流程 ═════════════════════════════════════════════════════════════════
def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    lines = []

    def out(s=""):
        print(s)
        lines.append(s)

    loc = Locator()
    fails = []

    def judge(cond, msg):
        if not cond:
            fails.append(msg)
        return "PASS" if cond else "FAIL"

    out("=" * 78)
    out("定位 → 定向增强  箭头验收   (README §26.1 / §26.5)")
    out(f"fs={FS:.1f} Hz  扫描 {GRID_W}×{GRID_H}  平面 z={PLANE_Z*1000:.0f} mm"
        f"  帧长 {N_FRAME} 样点 = {N_FRAME/FS*1000:.1f} ms")
    out(f"目标 ({TARGET[0]*1000:+.0f},{TARGET[1]*1000:+.0f}) mm   "
        f"干扰 ({INTERF[0]*1000:+.0f},{INTERF[1]*1000:+.0f}) mm")
    out(f"麦上 目标:噪声 = {SNR_NOISE_DB:.0f} dB；干扰源分 20 dB / 0 dB 两档（实验 2/2b）")
    out("=" * 78)

    # ── 实验 1：单点，看「转向朝哪」对输出的影响 ───────────────────────—
    out("\n[1] 单点：转向方向 → 输出增益（宽带 200 Hz–8 kHz，干扰 20 dB）")
    out("-" * 78)
    sc = build_scene(snr_interf_db=20.0)
    r = loc.locate(sc["data"])
    th = (r["x"], r["y"])
    err_cm = loc_error(r["x"], r["y"], *TARGET) * 100
    out(f"    SRP 定位: 真值 ({TARGET[0]*1000:+.0f},{TARGET[1]*1000:+.0f}) mm "
        f"→ θ̂ ({th[0]*1000:+.1f},{th[1]*1000:+.1f}) mm   误差 {err_cm:.2f} cm")

    steer_cases = [
        ("朝真值    (0.12,-0.08)", TARGET),
        ("朝 θ̂  (SRP 报的)",      th),
        ("朝阵列中心  (0.00, 0.00)", (0.0, 0.0)),
        ("朝干扰源  (-0.18, 0.12)", INTERF),
    ]
    g = {}
    base = None
    for name, s in steer_cases:
        snr, mic = snr_out(sc, s)
        if base is None:
            base = mic
        g[name] = snr - mic
        out(f"    {name:<26} 输出 {snr:+7.2f} dB   相对单麦 {snr - mic:+6.2f} dB")

    g_srp = g["朝 θ̂  (SRP 报的)"]
    g_truth = g["朝真值    (0.12,-0.08)"]
    g_center = g["朝阵列中心  (0.00, 0.00)"]
    out("")
    out(f"    箭头接上（朝 θ̂）      {g_srp:+6.2f} dB")
    out(f"    上界（朝真值）         {g_truth:+6.2f} dB")
    out(f"    反例 A（朝阵列中心）   {g_center:+6.2f} dB")
    ok_a = g_center < g_srp - 3.0
    out(f"    判据：反例 A 必须比朝 θ̂ 低 3 dB 以上   {judge(ok_a, 'repro A')} "
        f"(差 {g_srp - g_center:+.2f} dB)")

    # ── 实验 2：源移动，箭头接上 vs 转向钉死 ─────────────────────────────——
    #    这是最直接的证据：今天 check_bf.py 的行为 = 「钉死」那一列。
    #
    #    ⚠ 判据必须**把两件事分开**：箭头对不对（本脚本要证的）
    #      与 SRP 定得准不准（check_srp.py 的事，且受干扰源电平支配）。
    #      混在一起判会得出"箭头不行"的错误结论 —— 第一版就是这么翻车的。
    #      证据：干扰 ≥10 dB 时定位稳在 1 cm 内；0 dB 时 SRP 本身会锁到干扰源上
    #      （实测 mean 0.91 cm → 13.06 cm，最差 44 cm）。
    def sweep(band, snr_interf, label, judge_here):
        out("\n" + "=" * 78)
        out(f"[2] 源位置扫描 —— 箭头接上 vs 转向钉死   [{label}]")
        out("=" * 78)
        out(f"    {'真值 (x,y) mm':>18} {'定位误差':>9} {'接上':>8} {'钉死':>8} "
            f"{'朝真值':>8}")
        rows = []
        for k, (sx, sy) in enumerate(POS_5x5):
            s2 = build_scene(target_xy=(sx, sy), seed=7 + k, band=band,
                             snr_interf_db=snr_interf)
            rr = loc.locate(s2["data"])
            e2 = loc_error(rr["x"], rr["y"], sx, sy) * 100
            s_srp, mic = snr_out(s2, (rr["x"], rr["y"]))     # 箭头接上
            s_fix, _ = snr_out(s2, FIXED)                    # 转向钉死在 (0.12,-0.08)
            s_trl, _ = snr_out(s2, (sx, sy))                 # 上界：朝真值
            rows.append((e2, s_srp - mic, s_fix - mic, s_trl - mic))
            out(f"    ({sx*1000:+6.1f},{sy*1000:+6.1f}) {e2:>8.2f} cm "
                f"{s_srp - mic:>+8.2f} {s_fix - mic:>+8.2f} {s_trl - mic:>+8.2f}")
        rows = np.array(rows)

        # 定位成功的子集 —— 箭头该在这些点上与"朝真值"一致
        good = rows[:, 0] < 10.0          # §45 的 10 cm 判据
        out("")
        out(f"    定位成功（误差 < 10 cm）{int(good.sum())}/{len(rows)} 个点")
        if good.any():
            mc, mt = rows[good, 1].mean(), rows[good, 3].mean()
            out(f"    这些点上：接上 {mc:+.2f} dB   朝真值 {mt:+.2f} dB   "
                f"差 {mc - mt:+.2f} dB")
        out(f"    全 25 点平均：接上 {rows[:,1].mean():+.2f} dB   "
            f"钉死 {rows[:,2].mean():+.2f} dB   朝真值 {rows[:,3].mean():+.2f} dB")
        out(f"    钉死那一列最差 {rows[:,2].min():+.2f} dB"
            f"（源走到离钉死方向最远处）")
        if judge_here and good.any():
            ok_t = rows[good, 1].mean() > rows[good, 3].mean() - 1.0
            out(f"    判据：定位成功的点上，接上 ≥ 朝真值 − 1 dB   "
                f"{judge(ok_t, 'conn vs truth')} "
                f"(差 {rows[good,1].mean() - rows[good,3].mean():+.2f} dB)")
        return rows

    narrow_rows = sweep(BAND_NARROW, 20.0, "窄带 4–8 kHz，干扰 20 dB（定位可靠）",
                        judge_here=True)
    sweep(BAND_WIDE, 20.0, "宽带 200 Hz–8 kHz，干扰 20 dB（§0.3.1 基线口径）",
          judge_here=False)

    out("\n" + "=" * 78)
    out("[2b] 同响度方向性干扰（0 dB）—— SRP 本身会失手，如实报")
    out("=" * 78)
    hard = sweep(BAND_NARROW, 0.0, "窄带 4–8 kHz，干扰 0 dB", judge_here=False)
    out("")
    out("    ⚠ 这一档失手的是**定位**，不是箭头：箭头忠实地朝 θ̂ 转，")
    out("      θ̂ 错的时候 DAS 朝错方向对齐，把目标抵消掉（负增益）——")
    out("      这恰恰说明箭头**真的接上了**：若没接，增益不会随 θ̂ 变。")
    ok_faithful = hard[hard[:, 0] >= 10.0, 1].mean() < \
        hard[hard[:, 0] < 10.0, 1].mean() - 5.0
    out(f"    判据：定位失手的点上，接上的增益必须塌（证明箭头随 θ̂ 变）  "
        f"{judge(ok_faithful, 'arrow faithful')}")

    # ── 实验 3：迟滞 ─────────────────────────────────────────────────——
    out("\n" + "=" * 78)
    out("[3] 迟滞（§26.5.2）：单帧跳变不得推动 committed θ̂")
    out("=" * 78)
    ctl = SteerController(cand_frames=3, hold_frames=5)

    def run_seq(seq):
        ctl.reset()
        return [ctl.update(d) for d in seq]

    stable = [TARGET] * 10
    _ = run_seq(stable)
    locked = ctl.committed
    out(f"    10 帧稳定在 {tuple(round(v,3) for v in locked)} → 已锁定 "
        f"(state={ctl.state})")

    # ① 单帧跳变（远离 0.1 m）—— ACTIVE 帧不检查 _near 的 push，走 HOLD
    jit = [TARGET] * 3 + [(0.0, 0.15)] + [TARGET] * 3
    seq = run_seq(jit)
    held = all(c is None or np.hypot(c[0] - TARGET[0], c[1] - TARGET[1]) < 0.05
               for c in seq)
    states = "→".join(ctl.log)
    out(f"    单帧跳变后状态轨迹: {states}")
    out(f"    committed 未被推动: {'是' if held else '否'}")
    ok_h1 = held and "HOLD" in ctl.log and "RELEASE" not in ctl.log
    out(f"    判据：进 HOLD 但不 RELEASE      {judge(ok_h1, 'hyst single')}")

    # ② 持续移位 —— 必须释放并重新锁定到新位置
    newpos = (-0.18, 0.12)
    sus = [TARGET] * 3 + [newpos] * 12
    seq = run_seq(sus)
    moved = any(c is not None and np.hypot(c[0] - newpos[0], c[1] - newpos[1]) < 0.05
                for c in seq)
    out(f"    持续移位后状态轨迹: {'→'.join(ctl.log)}")
    out(f"    committed 已跟到新位置: {'是' if moved else '否'}")
    ok_h2 = moved and "RELEASE" in ctl.log
    out(f"    判据：持续移位必须释放并跟过去   {judge(ok_h2, 'hyst sustained')}")

    # ── 实验 4：渐变 ─────────────────────────────────────────────────——
    out("\n" + "=" * 78)
    out("[4] 指向渐变（§26.5.1）：不允许瞬间切换")
    out("=" * 78)
    mics = uca_positions()
    c_from = comp_of(TARGET, mics)
    c_to = comp_of((-0.18, 0.12), mics)
    gap = float(np.abs(c_to - c_from).max())

    STEP = 0.2
    traj = [ramp_at(c_from, c_to, STEP, k) for k in range(6)]
    deltas = [float(np.abs(traj[k + 1] - traj[k]).max()) for k in range(5)]
    max_step = max(deltas)
    settled = float(np.abs(traj[-1] - c_to).max())
    snap = float(np.abs(ramp_at(c_from, c_to, 0.0, 0) - c_from).max())

    out(f"    两方向之间 comp 的整段跳变   {gap:.2f} 样点")
    out(f"    不渐变（step=0）一帧跳满     {snap:.2f} 样点  ← 会爆音")
    out(f"    渐变 step={STEP} 逐帧步进     "
        + " ".join(f"{d:.2f}" for d in deltas) + " 样点")
    out(f"    单帧最大变化                 {max_step:.2f} 样点")
    out(f"    5 帧后残差                   {settled:.2e} 样点（README: 5 帧走满）")
    ok_r1 = max_step < snap * 0.5
    ok_r2 = settled < 1e-9
    out(f"    判据：单帧变化 < 整段跳变的一半  {judge(ok_r1, 'ramp step')}")
    out(f"    判据：5 帧必须走满（残差→0）    {judge(ok_r2, 'ramp settle')}")

    # ── 出图 ───────────────────────────────────────────────────────────
    # ⚠ 图上的文字一律用 ASCII：本仓的 WSL 环境里没有 CJK 字体
    #   （matplotlib 会报 "Glyph missing from font(s) DejaVu Sans" 并画成方框）。
    #   中文口径记在 summary.txt 里，那才是给人读的存档。
    fig, ax = plt.subplots(figsize=(5.2, 4.4))
    P = r["P"].reshape(GRID_H, GRID_W)
    half = 200
    im = ax.imshow(P / P.max(), origin="lower", extent=[-half, half, -half, half],
                   cmap="inferno", aspect="equal")
    ax.plot(TARGET[0]*1000, TARGET[1]*1000, "c+", ms=14, mew=2, label="truth")
    ax.plot(th[0]*1000, th[1]*1000, "wo", ms=7, mfc="none", mew=1.5, label="SRP estimate")
    ax.annotate("", xy=(th[0]*1000, th[1]*1000),
                xytext=(0, 0),
                arrowprops=dict(arrowstyle="->", color="w", lw=1.6))
    ax.set_xlabel("x [mm]"); ax.set_ylabel("y [mm]")
    ax.set_title(f"SRP estimate steers the beam (err {err_cm:.1f} cm)")
    ax.legend(loc="upper right", fontsize=8)
    fig.colorbar(im, ax=ax, label="normalized energy")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "loc_beam_map.png"), dpi=130)
    plt.close(fig)

    xs_mm = [p[0]*1000 for p in POS_5x5]
    fig, ax = plt.subplots(figsize=(5.6, 3.8))
    ax.plot(xs_mm, narrow_rows[:, 1], "o-", label="arrow connected (steer at SRP estimate)")
    ax.plot(xs_mm, narrow_rows[:, 2], "s--", label="steer pinned (today's behaviour)")
    ax.plot(xs_mm, narrow_rows[:, 3], "^:", label="upper bound (steer at truth)")
    ax.set_xlabel("source x [mm] (y sweeps with the 5x5 grid)")
    ax.set_ylabel("gain over single mic [dB]")
    ax.set_title("Source moves: connected vs pinned (band 4-8 kHz)")
    ax.grid(True, alpha=0.3); ax.legend(fontsize=7)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_DIR, "loc_beam_gain.png"), dpi=130)
    plt.close(fig)

    # ── 结论 ───────────────────────────────────────────────────────────
    out("\n" + "=" * 78)
    out("结论 —— 「定位结果用于定向增强」")
    out("=" * 78)
    if fails:
        out(f"  ❌ FAIL: {len(fails)} 条判据不成立 → {fails}")
    else:
        out("  ✅ PASS: 箭头接上 —— 朝 SRP 报的那一格对齐，增益与朝真值对齐相当；")
        out("           朝固定错向对齐增益塌；迟滞与渐变均按 §26.5 生效。")
    out("")
    out("  ⚠ 频带前提（§0.3.5）：阵列只在 ≈4–8 kHz 有方向性。")
    out("     上面的窄带一列才是「可定位带」内的结论；宽带那列被 4 kHz 以下稀释。")

    path = os.path.join(OUT_DIR, "summary.txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"\n存档: {os.path.normpath(path)}")
    print(f"图:   {os.path.normpath(OUT_DIR)}/loc_beam_map.png, loc_beam_gain.png")

    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
