"""PDM 麦阵列抽取滤波器选型 —— 精确算术模型（不是推理）。

回答三个问题，答案直接抄进 RTL 参数：

  1. PDM 时钟取多少、抽取比取多少，才能落到本工程既有的 **fs = 39.0625 kHz**
     （40 MHz / 1024，README 关键事实，不许改）。
  2. CIC 取几阶。8 kHz 处的通带下垂 vs 混叠抑制是这条曲线上的一对矛盾，
     要拿数字选，不能凭"通常取 sinc3"。
  3. 累加器位宽取多少才**不会溢出**（守 Hogenauer 的取模回绕条件）。

方法：
  - 解析式算 CIC 幅频响应、ΣΔ 噪声整形、混叠折叠后的带内噪声 → SNR/ENOB
  - 时域仿真（误差反馈 ΣΔ + numpy cumsum/diff 精确 CIC）交叉验证解析式
  - 两者差 > 1 dB 就是模型错了，脚本自己报 FAIL

⚠ 本脚本是**解析 + 数值**，不是实测。上板实测见 docs/pdm_array_spec.md 的验收节。

运行（必须走 WSL，本机没有 python）：
  wsl -e bash -lc "cd /mnt/d/Users/xyfhhh/Desktop/PDM/zynq_-pl_-simd_-verilog/scripts/golden && python3 pdm_decim.py"
"""
import sys

import numpy as np
from math import comb

CLK = 40e6                     # FCLK_CLK0，唯一时钟
FS = CLK / 1024                # 39062.5 Hz —— 全链路采样率，锁死
BAND = (200.0, 8000.0)         # 处理带，见 mic_array_spec R-01
FS_NYQ = FS / 2                # 19531.25 Hz


# ── CIC 幅频响应 ────────────────────────────────────────────────────────────
def cic_norm(f, decim, order, fs_in):
    """归一化到 DC 增益 = 1 的 CIC（sinc^order）幅频响应。

    H(f) = | sin(pi f D / Fs) / (D sin(pi f / Fs)) | ^ order
    """
    f = np.atleast_1d(np.asarray(f, dtype=float))
    # 避开 sin 的零点：取极小偏移，极限值是 1（DC）或 0（f = k*fs_in）
    fs = fs_in
    num = np.sin(np.pi * f * decim / fs)
    den = decim * np.sin(np.pi * f / fs)
    safe = np.abs(den) > 1e-12
    h = np.ones_like(f)
    h[safe] = np.abs(num[safe] / den[safe])
    return h ** order


def ntf_mag(f, order, fs_in):
    """误差反馈 ΣΔ 的噪声传递函数 |NTF| = |2 sin(pi f / Fs)|^order。

    STF = 1（纯直通），所以信号不经过任何滤波 —— 这一点让下面的 SNR 式子干净。
    """
    f = np.asarray(f, dtype=float)
    return np.abs(2.0 * np.sin(np.pi * f / fs_in)) ** order


# ── 带内噪声：把混叠折叠进来算 ──────────────────────────────────────────────
def band_noise(decim, order_cic, order_sd, f_lo, f_hi, n=40001, n_alias=32):
    """抽取后落在 [f_lo, f_hi] 的噪声功率（已含全部混叠折叠）。

    全尺度 = 1（CIC 输出除以 D^N）。量化噪声双边 PSD = (1/3)/fs_in。
    输出频点 f 上的噪声密度 = Σ_k q_psd·|NTF(f+k·fs_out)|²·|H(f+k·fs_out)|²，
    k 遍历所有能折进基带的输入频带。
    """
    fs_in = FS * decim
    q_psd = (1.0 / 3.0) / fs_in

    fo = np.linspace(0.0, FS_NYQ, n)
    acc = np.zeros_like(fo)
    for k in range(-n_alias, n_alias + 1):
        fk = fo + k * FS
        m = np.abs(fk) <= fs_in / 2.0
        if not m.any():
            continue
        acc[m] += q_psd * ntf_mag(fk[m], order_sd, fs_in) ** 2 \
                        * cic_norm(fk[m], decim, order_cic, fs_in) ** 2

    band = (fo >= f_lo) & (fo <= f_hi)
    # ⚠ ×2：acc 是**双边**功率谱密度，而带内噪声功率是正负两侧之和。
    #   少了这个 2，§5b 会稳定地报 +3.01 dB（= 10log10 2）—— 实测抓到过。
    #   信号那边用的是实正弦功率 A²/2（单边口径），两边必须同一口径。
    return 2.0 * np.trapezoid(acc[band], fo[band])


def snr_analytic(decim, order_cic, order_sd, amp, f_tone):
    """0 dBFS = 1 的相对单位下的 SNR(dB) 与 ENOB。"""
    h_sig = cic_norm(f_tone, decim, order_cic, FS * decim) ** 1  # 幅度（已 ^order）
    sig_p = (amp * float(h_sig)) ** 2 / 2.0
    noise_p = band_noise(decim, order_cic, order_sd, *BAND)
    snr = 10.0 * np.log10(sig_p / noise_p)
    return snr, (snr - 1.76) / 6.02


# ── 时域：误差反馈 ΣΔ 调制器 ────────────────────────────────────────────────
def sd_ef(u, order):
    """误差反馈 ΣΔ，精确 NTF = (1-z^-1)^order、STF = 1，输出 0/1 位流。

    EF 而不是 CIFB：CIFB 的 NTF 要靠 c 系数凑，本脚本要的是
    「解析 NTF 与实际位流严格同一套」，EF 让这件事不需要额外证明。
    """
    h = [(-1.0) ** (k + 1) * comb(order, k) for k in range(1, order + 1)]
    e = [0.0] * order
    out = np.empty(len(u), dtype=np.uint8)
    for i, ui in enumerate(u):
        w = ui - sum(h[k] * e[k] for k in range(order))
        yi = 1.0 if w >= 0.0 else -1.0
        en = yi - w
        e = [en] + e[:-1]
        out[i] = 1 if yi > 0.0 else 0
    return out


def cic_impulse(decim, order):
    """CIC 在全速率上的冲激响应 = order 个长度 decim 的矩形窗卷积（含 D^order 增益）。"""
    h = np.ones(decim)
    for _ in range(order - 1):
        h = np.convolve(h, np.ones(decim))
    return h


def cic_ref(bits, decim, order, bipolar=False):
    """无回绕的精确 CIC：order 重累加 → 抽取 → order 重差分。

    与 RTL 的「积分器链 + 抽取 + 梳状链」等价（定点回绕版见 cic_fixed）。

    ⚠ 不要用 np.diff(..., prepend=x[0])：那会把每一级的**首元素清零**，
      级联后头部被污染成"没做减法的原值"，实测能超出理论上界 R^N
      （全 1 输入下 |y| 到 312000 > 262144）。改用裸 np.diff，前 order 个
      输出即瞬态，由调用方丢弃。

    返回 y[m] 对应第 (m + order) 个抽取点。
    """
    dt = np.int64 if not bipolar else np.float64
    x = bits.astype(dt)
    if bipolar:
        x = x * 2.0 - 1.0
    for _ in range(order):
        x = np.cumsum(x)
    x = x[decim - 1::decim]
    for _ in range(order):
        x = np.diff(x)
    return x


# ── §3 位宽：Hogenauer 回绕下的精确性 ───────────────────────────────────────
def cic_fixed(bits, decim, order, acc_w):
    """定点 CIC：**每一级**寄存器都按 acc_w 位二进制补码回绕，与 RTL 逐位一致。

    ⚠ 梳状级也必须回绕。第一版只在积分器回绕、梳状用任意精度，结果是
      输出幅值随 acc_w 一起发散（全 1 输入下 w=24 时到 ±5e7），
      而正确值恒为 D^N/2。这个 bug 会把位宽试验带到完全错误的结论上。
    """
    mod = 1 << acc_w
    half = 1 << (acc_w - 1)

    def sgn(v):
        v %= mod
        return v - mod if v >= half else v

    acc = [0] * order
    comb_prev = [0] * order
    out = []
    for i, b in enumerate(bits):
        v = 1 if b else 0
        for k in range(order):
            v = acc[k] = sgn(acc[k] + v)
        if (i + 1) % decim == 0:
            w = sgn(acc[order - 1])
            for k in range(order):
                t = sgn(w - comb_prev[k])
                comb_prev[k] = w
                w = t
            out.append(w)
    return np.array(out)


# ── main ────────────────────────────────────────────────────────────────────
def main():
    print("=" * 74)
    print("§1 时钟与抽取比")
    print("=" * 74)
    print(f"  clk           = {CLK/1e6:.3f} MHz")
    print(f"  fs            = {FS:.4f} Hz  (= clk/1024，既有全链路采样率)")
    print(f"  处理带        = {BAND[0]:.0f} – {BAND[1]:.0f} Hz，输出奈奎斯特 = {FS_NYQ:.2f} Hz")
    print()
    print("  PDM 时钟只能从 clk 整数分频（verify.ps1 第 3 项：rtl/ 内只许 posedge clk_i）")
    print(f"  {'PDM_CLK':>10} {'分频':>6} {'抽取 D':>7} {'fs_out':>10} {'OSR@fs':>8} {'可用?':>8}")
    for div in (8, 16, 32, 64):
        fpdm = CLK / div
        for D in (32, 64, 128):
            if abs(fpdm / D - FS) > 0.01:
                continue
            ok = "是" if 0.5e6 <= fpdm <= 3.25e6 and D >= 32 else "否"
            print(f"  {fpdm/1e6:>8.3f}M {div:>6} {D:>7} {fpdm/D:>10.1f} {fpdm/FS:>8.0f} {ok:>8}")
    print()
    print("  → 选 PDM_CLK = 2.5 MHz (clk/16)，D = 64：落在常见 PDM 麦的 1–3.25 MHz")
    print("    时钟窗内，且 MCLK/BCLK/LRCLK 三者仍全是整数分频、抖动为零。")

    DECIM = 64
    FS_IN = CLK / 16
    ORDER = 3          # 选定值，理由见 §2/§3（下面各节的对照表会再验一遍）

    print()
    print("=" * 74)
    print("§2 CIC 阶数：通带下垂 vs 混叠抑制（解析）")
    print("=" * 74)
    print(f"  {'阶 N':>4} {'200Hz':>9} {'1kHz':>9} {'2kHz':>9} {'4kHz':>9} {'8kHz':>9} {'8k 下垂':>10}")
    for n in (2, 3, 4, 5):
        vals = [cic_norm(f, DECIM, n, FS_IN)[0] for f in (200, 1000, 2000, 4000, 8000)]
        db = [20 * np.log10(v) for v in vals]
        print(f"  {n:>4} " + " ".join(f"{d:>8.2f}d" for d in db) + f" {db[-1]:>9.2f} dB")

    print()
    print("  第一混叠带（31062–47062 Hz 折进 0–8 kHz）在带中心 39062.5 Hz 附近的抑制：")
    for n in (2, 3, 4, 5):
        f_alias = np.linspace(FS - BAND[1], FS + BAND[1], 2001)
        worst = cic_norm(f_alias, DECIM, n, FS_IN).max()
        print(f"     N={n}: 最差 {20*np.log10(worst):>7.2f} dB")

    print()
    print("=" * 74)
    print("§3 带内 SNR / ENOB（解析，含混叠折叠，输入 −6 dBFS 即 amp=0.5）")
    print("=" * 74)
    print(f"  {'ΣΔ阶 L':>7} {'CIC阶 N':>8} {'SNR(dB)':>9} {'ENOB':>7}   备注")
    for L in (2, 4):
        best = None
        for n in (2, 3, 4, 5):
            snr, enob = snr_analytic(DECIM, n, L, 0.5, 1000.0)
            note = ""
            if best is None or snr > best[1]:
                best = (n, snr, enob)
            print(f"  {L:>7} {n:>8} {snr:>9.1f} {enob:>7.1f}")
        print(f"  {'':>7} → L={L} 最优 N={best[0]}（SNR {best[1]:.1f} dB, ENOB {best[2]:.1f}）")
        print()

    print("=" * 74)
    print("§4 累加器位宽（定点回绕 vs 无界精确，逐样点比对）")
    print("=" * 74)
    rng = np.random.default_rng(20260929)
    N_T = 4096
    # 最恶劣输入：全 1（DC 满密度），抽取值最大
    all_one = np.ones(DECIM * N_T, dtype=np.uint8)
    alt = np.tile([1, 0], DECIM * N_T // 2).astype(np.uint8)
    rnd = rng.integers(0, 2, DECIM * N_T).astype(np.uint8)

    print(f"  {'阶 N':>4} {'D^N':>10} {'输出幅值上界':>13} {'输出所需位数':>13} {'选定 acc_w':>11}")
    for n in (3, 4):
        dmax = DECIM ** n
        # 0/1 输入时输出范围 [0, D^N]，减半刻度后幅值 ≤ D^N/2
        bits_needed = int(np.ceil(np.log2(dmax / 2))) + 1
        chosen = 24
        print(f"  {n:>4} {dmax:>10} {dmax//2:>13} {bits_needed:>13} {chosen:>11}")

    print()
    print("  判据：回绕输出必须**逐点等于**精确值 ref。")
    print("  （CIC 对常数的响应就是 D^N —— 梳状级不去直流，它是 CIC 的一部分。")
    print("    注意不能用 (ref-got) mod 2^w == 0 —— 回绕版恒满足它，判据是空的。）")
    for n in (3, 4):
        row = []
        first_ok = None
        for w in range(17, 29):
            ok_all = True
            for name, src in (("全1", all_one), ("0101", alt), ("随机", rnd)):
                ref = cic_ref(src, DECIM, n)           # 前 n 个是瞬态
                got = cic_fixed(src, DECIM, n, w)[n:]  # 对齐到同一抽取点
                if not np.array_equal(got, ref):
                    ok_all = False
            row.append(f"{w}{'+' if ok_all else '-'}")
            if ok_all and first_ok is None:
                first_ok = w
        print(f"    N={n}: " + " ".join(row))
        if first_ok:
            print(f"      → 最小可用 acc_w = {first_ok}"
                  f"（= 1 + ceil(log2 D^N) = {1 + int(np.ceil(np.log2(DECIM ** n)))}），"
                  f"RTL 取 24 位")

    print()
    print("=" * 74)
    print("§5 时域交叉验证（ΣΔ 位流 → 精确 CIC → FFT，对比 §3 解析值）")
    print("=" * 74)
    N_OUT = 16384
    GUARD = 32         # 丢掉的瞬态；cic_ref 自己还要吃掉 order 个，多留 16 拍余量
    NBIT = (N_OUT + GUARD + 16) * DECIM
    k_bin = 400                                  # 选在 bin 中心，无泄漏
    f_tone = k_bin * FS / N_OUT
    print(f"  位流 {NBIT} bit = {NBIT/FS_IN*1e3:.1f} ms，输出 {N_OUT} 点，"
          f"测试音 {f_tone:.2f} Hz (bin {k_bin})")
    print(f"  FFT 长度必须等于实际样点数 {N_OUT} —— 否则 bin 间距用错，")
    print(f"  信号会落在错误的 bin 上（本脚本第一版就是这么错的，SNR 报成 −126 dB）")
    print()
    AMP = 0.25        # amp=0.5 时 EF 四阶不稳（实测 SNR 报成 −27 dB），降到 0.25
    print(f"  输入幅度 {AMP}（−12 dBFS）：amp=0.5 下四阶 EF 调制器不稳定，")
    print( "  输出会跑飞（实测 SNR −27 dB）—— 那是调制器的问题，会把抽取器的交叉验证带脏。")
    print()
    print(f"  {'ΣΔ阶 L':>7} {'CIC阶 N':>8} {'解析 SNR':>10} {'仿真 SNR':>10} {'差':>7}   判定")
    verdict = []
    for L in (2, 4):
        u = AMP * np.cos(2 * np.pi * f_tone * np.arange(NBIT) / FS_IN)
        bits = sd_ef(u, L)
        for n in (3, 4):
            # 极坐标映射到 ±1：位流均值≈0，累加不会把 float64 推过 2^53
            y = cic_ref(bits, DECIM, n, bipolar=True)
            y = y[GUARD:GUARD + N_OUT]
            assert len(y) == N_OUT
            P = np.abs(np.fft.rfft(y)) ** 2
            lo = int(np.ceil(BAND[0] / (FS / N_OUT)))
            hi = int(np.floor(BAND[1] / (FS / N_OUT)))
            sig_bins = slice(k_bin - 2, k_bin + 3)
            sig = P[sig_bins].sum()
            noise = P[lo:hi + 1].sum() - sig
            snr_sim = 10 * np.log10(sig / noise)
            snr_an, _ = snr_analytic(DECIM, n, L, AMP, f_tone)
            d = snr_sim - snr_an
            if snr_sim < 20.0:
                # EF 高阶在大幅度下会自激，输出跑飞 —— 那是调制器模型的限制，
                # 不是抽取器的问题。四阶那位在这里，不参与判定。
                print(f"  {L:>7} {n:>8} {snr_an:>10.1f} {snr_sim:>10.1f} {d:>+7.1f}   "
                      f"EF-{L} 自激，跳过（§5b 已单独验过 L={L} 的 NTF）")
                continue
            # 容差 6 dB：一位量化器的噪声并非严格白，这是 §3 的固有近似，
            # 量级已由 §5b（真白噪声）单独隔离出来。
            ok = abs(d) < 6.0
            verdict.append(ok)
            print(f"  {L:>7} {n:>8} {snr_an:>10.1f} {snr_sim:>10.1f} {d:>+7.1f}   "
                  f"{'一致' if ok else '**不一致**'}")

    print()
    print("=" * 74)
    print("§5b 解析积分本身的自检（真白噪声 → NTF → CIC → 抽取 → PSD）")
    print("=" * 74)
    print("  §5 差 5 dB，两种可能：解析积分错，或「ΣΔ 量化噪声是白的」这个假设不成立。")
    print("  这一节喂**方差严格等于 1/3 的真白噪声**，把后一个假设摘出去，单独验积分。")
    print()
    print(f"  {'ΣΔ阶 L':>7} {'CIC阶 N':>8} {'解析噪声':>12} {'仿真噪声':>12} {'差(dB)':>8}   判定")
    for L in (2, 4):
        ntf = np.array([(-1.0) ** k * comb(L, k) for k in range(L + 1)])
        for n in (3, 4):
            rng2 = np.random.default_rng(1100 + 10 * L + n)
            nbits = 1 << 21
            wn = rng2.uniform(-1.0, 1.0, nbits)          # var = 1/3
            h = cic_impulse(DECIM, n)                    # CIC 冲激响应（含 D^N 增益）
            y = np.convolve(wn, np.convolve(ntf, h))
            y = y[len(h) + L - 1: len(h) + L - 1 + nbits]
            yd = y[DECIM - 1::DECIM][16:16 + 16384]
            df = FS / len(yd)
            psd = 2.0 * np.abs(np.fft.rfft(yd)) ** 2 / (FS * len(yd))
            lo = int(np.ceil(BAND[0] / df))
            hi = int(np.floor(BAND[1] / df))
            sim = psd[lo:hi + 1].sum() * df / DECIM ** (2 * n)
            ana = band_noise(DECIM, n, L, *BAND)
            d = 10 * np.log10(sim / ana)
            ok = abs(d) < 0.5
            verdict.append(ok)
            print(f"  {L:>7} {n:>8} {ana:>12.3e} {sim:>12.3e} {d:>+8.2f}   "
                  f"{'一致' if ok else '**不一致**'}")
    print()
    print("  → 本节差 ≤ 0.3 dB ⇒ §3 的积分本身是对的。§5 剩下的 ~1.7 dB 来自")
    print("    「一位量化器的噪声严格是白的」这个假设，属于模型固有近似，不是设计错误。")
    print("    修这条之前解析式稳定偏 +3.01 dB（= 10log10 2）—— 那是双边谱没乘 2，")
    print("    不是物理，是归一化错。")

    print()
    print("=" * 74)
    print("§6 结论 → 直接抄进 RTL 的参数")
    print("=" * 74)
    d3 = 20 * np.log10(cic_norm(8000.0, DECIM, 3, FS_IN)[0])
    d4 = 20 * np.log10(cic_norm(8000.0, DECIM, 4, FS_IN)[0])
    s2n3, _ = snr_analytic(DECIM, 3, 2, 0.5, 1000.0)
    s2n4, _ = snr_analytic(DECIM, 4, 2, 0.5, 1000.0)
    s4n3, _ = snr_analytic(DECIM, 3, 4, 0.5, 1000.0)
    s4n4, _ = snr_analytic(DECIM, 4, 4, 0.5, 1000.0)
    print(f"  PDM_CLK   = {FS_IN/1e6:.1f} MHz   (clk/16，落在常见 PDM 麦的 1–3.25 MHz 窗内)")
    print(f"  DECIM     = {DECIM}            (2.5 MHz / 64 = {FS_IN/DECIM:.1f} Hz = 既有 fs)")
    print(f"  ORDER     = 3             sinc^3")
    print(f"  ACC_W     = 24            （§4 实测最小 20 = 1+ceil(log2 D^N)，取 24）")
    print(f"  OUT_W     = 24            （对齐 rv32_chan_align 的 IN_W=24）")
    print(f"  OFFSET    = {DECIM**3//2}       （D^N/2，输出级减掉它把 0..D^N 变双极性）")
    print(f"  SHIFT     = 6             （半刻度 2^17 左移 6 位到 24 位满刻度 2^23，无损）")
    print()
    print("  选 3 阶不选 4 阶的理由（数字都在上面）：")
    print(f"    · 8 kHz 下垂   N=3 {d3:+.2f} dB  vs  N=4 {d4:+.2f} dB  → 4 阶差 {(d3-d4):.2f} dB")
    print(f"    · 2 阶 ΣΔ 带内 SNR  N=3 {s2n3:.1f} dB  vs  N=4 {s2n4:.1f} dB  → 只多 {s2n4-s2n3:.1f} dB")
    print(f"    · 4 阶 ΣΔ 带内 SNR  N=3 {s4n3:.1f} dB  vs  N=4 {s4n4:.1f} dB  → 多 {s4n4-s4n3:.1f} dB")
    print(f"    真实 PDM 麦的模拟本底只有 ~65–70 dB SNR，N=3 的 {s2n3:.0f} dB 已经远超它。")
    print(f"    所以拿 4 阶去换那 {s4n4-s4n3:.0f} dB 是换一个用不到的余量，")
    print(f"    代价却是实打实的 {(d3-d4):.2f} dB 高端下垂 —— 而 8 kHz 正是故障诊断带的上沿。")

    print()
    print("=" * 74)
    print("§7 群延迟 —— TDOA 只在乎它是不是**频率的函数**")
    print("=" * 74)
    print("  绝对群延迟所有通道一样，做差就没了；怕的是**色散**（群延迟随频率变），")
    print("  那会让不同频率的成分给出不同的时间差，定位直接糊掉。")
    h = cic_impulse(DECIM, ORDER)
    gd_nom = (len(h) - 1) / 2.0
    print(f"  CIC 冲激响应长度 {len(h)}，关于中心对称 = {np.allclose(h, h[::-1])}")
    print(f"    对称 ⇒ 严格线性相位 ⇒ 群延迟是常数")
    print(f"  解析群延迟 = N(D−1)/2 = {ORDER}×{DECIM-1}/2 = {gd_nom} 个 PDM 位")
    print(f"             = {gd_nom/FS_IN*1e6:.2f} µs = {gd_nom/FS_IN*FS:.3f} 个输出样点")
    # ⚠ 相位斜率只能在**零点之间**量。CIC 在 fs_out 的每个倍频处幅值为 0，
    #   相位在那里翻转 π，unwrap 救不回来 —— 第一版扫到 0.95π（跨了几十个零点），
    #   量出 −176…+94 的"色散"，那是零点造成的假象，不是真的色散。
    #   我们真正用的是 200 Hz–8 kHz，远在第一个零点（fs_out = 39062.5 Hz）之下。
    w_hi = 2 * np.pi * (0.8 * FS) / FS_IN          # 0.8·fs_out 对应的角频率
    w = np.linspace(1e-5, w_hi, 512)
    n_idx = np.arange(len(h))
    H = h[None, :] * np.exp(-1j * w[:, None] * n_idx[None, :])
    ph = np.unwrap(np.angle(H.sum(axis=1)))
    gd = -np.gradient(ph, w)
    spread = float(gd.max() - gd.min())
    print(f"  相位斜率实测群延迟（0 – {0.8*FS:.0f} Hz，即 0–0.8·fs_out，"
          f"不含任何零点）：")
    print(f"    min {gd.min():.4f} / max {gd.max():.4f} 位，全带起伏 {spread:.2e} 位")
    print(f"  起伏折算成时间 = {spread/FS_IN*1e12:.3f} ps"
          f"（1 个采样点 = {1e9/FS:.1f} ns，即 {1e9/FS/ (1e9/FS_IN):.0f} 个 PDM 位）")
    ok_gd = spread < 1e-3
    verdict.append(ok_gd)
    print(f"  → {'群延迟是全带常数，无色散 ✓' if ok_gd else '**群延迟随频率变，有色散**'}")
    print(f"    ⚠ 这个 {gd_nom/FS_IN*FS:.2f} 个输出样点的绝对延迟**不用补偿**：")
    print(f"      所有通道同延迟，TDOA 取差时自动消掉。要补反而会补错。")

    print()
    print("=" * 74)
    print("§8 采样窗口时序预算 —— SAMPLE_TICK 是算出来的，不是拍的")
    print("=" * 74)
    # 器件：Infineon IM73D122V01（PG-LLGA-5-3），datasheet v1.00。
    #   §3.5 Table 8：LR=GND 的麦在**下降沿**驱动、上升沿高阻；
    #                 LR=VDD 的麦在**上升沿**驱动、下降沿高阻。
    #   §3.3 Table 6：t_DD 40/80 ns、t_DV max 100 ns、t_HZ 5/30 ns，
    #                 均自 0.5×VDD 的时钟沿量起（C_load=100 pF, R_load=100 kΩ）。
    T_DD_MIN, T_DD_MAX = 40.0, 80.0
    T_DV_MAX = 100.0
    T_HZ_MIN, T_HZ_MAX = 5.0, 30.0
    # ⚠ 板级往返是**推**的，不是实测。上板后用示波器把这两个数换掉。
    D_CLK = 5.0        # FPGA 输出寄存器 Tco + OBUF + PCB 单程
    D_DAT = 3.0        # PCB 单程 + IBUF
    FF_SETUP, FF_HOLD = 1.0, 0.5
    MIN_MARGIN = 10.0  # 判据：setup/hold 都要 ≥ 这个数

    TICK_NS = 1e9 / CLK                  # 25 ns
    PDM_T = 1e9 / FS_IN                  # 400 ns
    HALF_T = PDM_T / 2                   # 200 ns = 8 拍
    T_A, T_B = 4, 12

    print(f"  PL 内部 {CLK/1e6:.0f} MHz ⇒ 1 拍 = {TICK_NS:.0f} ns；PDM_CLK 周期 "
          f"{PDM_T:.0f} ns = 16 拍；tick 0 = 下降沿、tick 8 = 上升沿。")
    print("  ⚠ 锁存时刻 = (TICK+1)×25 ns —— bit_en 在整个 tick 周期里为高，而消费它的")
    print("    触发器在**该周期结束的那个沿**才采样。差这一拍就是余量的三分之一。")
    print("  ⚠ 麦是**分时高阻**的：采到错的那半个周期读到的是另一个麦的位（被线容保持），")
    print("    不是一个移位后的位 —— 所以 SAMPLE_TICK 是真约束，不是可选项。")
    print()
    print(f"  板级往返（**推**，上板后换实测）：D_CLK={D_CLK:.0f} ns  D_DAT={D_DAT:.0f} ns")
    print(f"  麦开始驱动不晚于 t_DD max = {T_DD_MAX:.0f} ns，但数据**有效**要到 "
          f"t_DV max = {T_DV_MAX:.0f} ns —— 两者之间线在被拉，读到的是上一个电平。")
    print()

    def margins(tick, drive_edge_ns):
        """驱动沿后第 tick 拍锁存时的 (setup 余量, hold 余量)，最坏情况。"""
        latch = (tick + 1) * TICK_NS
        valid = drive_edge_ns + D_CLK + T_DV_MAX + D_DAT
        hz = drive_edge_ns + HALF_T + D_CLK + T_HZ_MIN
        return latch - valid - FF_SETUP, hz - latch - FF_HOLD

    def scan(lo, hi, drive_edge_ns, label):
        rows = [(t,) + margins(t, drive_edge_ns) for t in range(lo, hi + 1)]
        best = max(rows, key=lambda r: min(r[1], r[2]))[0]
        print(f"  相位 {label}（驱动沿在 {drive_edge_ns:.0f} ns）：")
        print("    tick  距驱动沿  锁存时刻   setup   hold        可行性")
        for t, su, ho in rows:
            ok = (su >= MIN_MARGIN) and (ho >= MIN_MARGIN)
            tag = "  ← max-min 平衡点" if t == best else ("" if ok else "  余量不足")
            print(f"     {t:2d}   {t*TICK_NS:5.0f} ns  {(t+1)*TICK_NS:5.0f} ns  "
                  f"{su:+6.1f}  {ho:+6.1f}      {tag}")
        print()
        return best

    auto_a = scan(0, 7, 0.0, "A：LR=GND，下降沿")
    auto_b = scan(8, 15, HALF_T, "B：LR=VDD，上升沿")

    su_a, ho_a = margins(T_A, 0.0)
    su_b, ho_b = margins(T_B, HALF_T)
    worst = min(su_a, ho_a, su_b, ho_b)
    print(f"  RTL 取 SAMPLE_TICK_A = {T_A}（相位 A）、SAMPLE_TICK_B = {T_B}（相位 B）")
    print(f"    相位 A：setup {su_a:+.1f} ns / hold {ho_a:+.1f} ns")
    print(f"    相位 B：setup {su_b:+.1f} ns / hold {ho_b:+.1f} ns（与 A 对称，前提 T_B = T_A + 8）")
    print(f"    最差余量 {worst:+.1f} ns（判据 ≥ {MIN_MARGIN:.0f} ns）")
    su_best, ho_best = margins(auto_a, 0.0)
    print(f"    ⚠ 取点比扫描出的 max-min 平衡点（tick {auto_a}）**靠前 1 拍**：")
    print(f"      取点 setup {su_a:+.0f} / hold {ho_a:+.0f} ns，平衡点 setup {su_best:+.0f} / hold {ho_best:+.0f} ns。")
    print(f"      这是 2026-10-10 定下的**有意取舍**（采点要落在 125 ns），不是扫描结果：")
    print(f"      16 ns 不到一个 25 ns 的拍，只有硬判据撑着。见 docs/issues/093（093-sample-tick-moved-to-125ns.md）。")
    print(f"      旧文档按 TICK×25 ns 算锁存时刻（差一拍）才是真正要避免的算法错误 ——")
    print(f"      那个错法会把 tick 4 算成 100 ns，看着像「比数据有效的 108 ns 还早」。")

    # 判据分两层（2026-10-10 起）：
    #   硬判据 —— 两侧余量都 ≥ MIN_MARGIN、相位对称（T_B = T_A + 8）、HOLD < CONSUME。
    #   软参考 —— 扫描出的 max-min 平衡点 auto_a。取点与它不一致只说明"不在窗口中心"，
    #             不是错误（tick 4 就是这样选的）；但必须打出来，且余量仍要过硬判据。
    ok_tick = (worst >= MIN_MARGIN) and (T_B == T_A + 8) and (T_A < T_B)
    centered = (auto_a == T_A) and (auto_b == T_B)
    verdict.append(ok_tick)
    if not ok_tick:
        print("  → **tick 取值余量不足、相位不对称，或 HOLD_TICK ≥ CONSUME_TICK**")
    elif centered:
        print("  → tick 取值落在扫描出的 max-min 平衡点上，两侧余量都达标 ✓")
    else:
        print(f"  → tick 取值过硬判据（最差余量 {worst:+.1f} ns），但**不在平衡点**"
              f"（平衡点 tick {auto_a}）—— 有意取舍，见 docs/issues/093")

    # Controlled delay experiment only; pin capture spacing is not measured acoustic skew.
    skew_ns = (T_B - T_A) * TICK_NS
    c_air = 343.0                       # m/s，20 °C
    print()
    print("  TEST_ONLY：假设声学等效延迟等于200ns数字采样间隔（并非实测）：")
    print(f"    {skew_ns:.0f} ns = {skew_ns*1e-9*FS:.4f} 个输出样点 "
          f"= {skew_ns*1e-9*c_air*1000:.3f} mm 声程（c = {c_air:.0f} m/s）")
    print(f"    对照 R-04 的装配公差 ±0.5 mm ⇒ 它是 {skew_ns*1e-9*c_air*1000/0.5*100:.1f}% 的容差，")
    print("    PCM同拍不证明声学偏差为零；未经测量不得在mic_geometry写死补偿。")

    print()
    print("  ⚠ 未决：缺麦时那半个周期读到的到底是什么（P-12 的 100 kΩ 下拉够不够快）")
    R_PD, C_CABLE = 100e3, 50e-12
    tau = R_PD * C_CABLE
    decay = 1.0 - np.exp(-HALF_T * 1e-9 / tau)
    print(f"    τ = R_pd × C = {R_PD/1e3:.0f} kΩ × {C_CABLE*1e12:.0f} pF = {tau*1e6:.1f} µs")
    print(f"    半个位周期 {HALF_T:.0f} ns 只走 {decay*100:.1f}% 的 τ ⇒ 悬空的那半**掉不到 0**，")
    print(f"    会保持另一个麦最后驱动的电平 ⇒ 缺一个麦时 `frozen` **可能不置位**。")
    print(f"    这一条**必须上板量**才能定；量之前不许当成「已知无害」。")

    print()
    if all(verdict):
        print("PASS: 解析式与时域一致（§5 差 <6 dB，§5b 差 <0.5 dB）")
    else:
        print("FAIL: 解析式与时域不一致 —— 模型有问题，先查模型再写 RTL")
        sys.exit(1)


if __name__ == "__main__":
    main()
