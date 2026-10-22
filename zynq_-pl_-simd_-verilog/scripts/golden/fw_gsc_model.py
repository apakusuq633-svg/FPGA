"""GSC（广义旁瓣抵消器）—— 固件定点模型（README §26.3）。

    d(n) = Σ_m w_m a_m(n)                 固定波束形成（= DAS 那一条）
    u_j(n) = a_j(n) − a_{j+1}(n),  j=0..6 阻塞矩阵：成对相减（§26.3.2 第一版，7 路）
    y(n) = Σ_j Σ_k W_j[k]·u_j(n−k)
    e(n) = d(n) − y(n)                    输出
    W_j[k] += μ·e(n)·u_j(n−k) / (δ + Σ_j‖u_j(n)‖²)

── 为什么 SNR 要用「权值轨迹」分解，不能直接量输出 ────────────────────────────
GSC 是**时变**的。"把同一个波束形成器作用到目标分量和干扰分量上"这句话，
只有在拿到 W(n) 轨迹之后才成立 —— 否则分子分母来自两个不同的滤波器，比值没意义。
golden 的 check_bf.py 就是这么做的（记录 W_hist 再回放）。

**固件里存不下 W 轨迹**：7 路 × 32 抽头 × 512 样点 × 4 B = 458 KB，DTCM 只有 16 KB。
解法是**回放而不存储**：跑三遍，每遍都从混合信号**重算出同一条 W 轨迹**
（更新规则只依赖混合信号），但滤波时分别作用到「目标」「其余」上：

    pass 1  W 更新 + 滤波都用混合   → 定义轨迹
    pass 2  滤波用「目标分量」，W 仍按混合更新 → e_target
    pass 3  滤波用「其余分量」，W 仍按混合更新 → e_other
    SNR_out = 10log10( Σe_target² / Σe_other² )

三遍的 W 轨迹逐位相同（因为更新只看混合），所以分子分母确实来自同一个 W(n)。✓

── 定点约定（C 侧照抄；这里每一条都是有意选的，改一处就要重跑对照）──────────
    u       int16（(a_j−a_{j+1})>>1，压回 int16 量程）
    W       int32，**Q12**（权值 = W/4096），限幅 ±W_LIM_Q12
    滤波    acc += W·(U>>7)，再 y = acc>>5     ← 两级移位是为了不溢出：
            W·U 本身可达 4e6×32767 ≈ 1.3e11，int32 装不下；先砍 U 的 7 位，
            每项 ≤ 4.2e6，224 项 ≤ 9.4e8，安全
    误差    e = d − y（int32）
    范数    nrm = D0 + Σ_j Σ_k (U_j[k]>>4)²    ← 同一套移位：Σu²/256
    更新    W_j[k] += (MU_NUM·(e>>1)·U_j[k]) / nrm    ← **截断除法（向零）**
            MU_NUM=2；推导见下面 mu_eff 的注释

⚠ **截断除法**：C 的 `/` 向零截断，Python 的 `//` 向负无穷 floor。负数上差 1，
  逐位比对会挂。这里统一用 _tdiv()，C 侧不要写 `a / b` 之外的任何东西。
⚠ 抽头数 **L=32**（golden 用 128~256）。固件的抵消能力因此**弱于**浮点金标准，
  报数时两个口径都要给，不能拿固件的 SNR 冒充 golden 的数。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fw_das_model as D  # noqa: E402  场景/源信号/插值与 DAS 共用，保证同一份输入

N = D.N_SAMP
N_CH = 8
N_REF = N_CH - 1          # 成对相减出 7 路
L_TAPS = 16
W_SHIFT = 12              # Q12
W_LIM_Q12 = 2 << W_SHIFT  # ±2.0 —— 实测 |W|max 只到 145/4096≈0.035，±2 是很宽的护栏，
                          #        但它同时给累加器让出了余量（见下面的 Q_SHIFT 选择）
D0 = 1                    # 范数的下限（浮点 δ 的定点对应；防止除零 + 限步长）

# ⚠⚠ **回归量只砍一次，三处（滤波/范数/更新）必须共用同一个值。**
#   第一版让滤波用 `u>>7`、更新用完整的 `u` —— 两者不是同一个回归量。
#   LMS 的梯度方向建立在 y = ΣW·h 上，而实际算的是 ΣW·(h>>7)，
#   自适应方向被系统性带偏。实测后果：同一 μ 下浮点 +0.56 dB、定点 −0.13 dB。
#   现在延迟线里存的就是 `u >> Q_SHIFT`，滤波、范数、更新三处都用它。
# 参数是**扫出来的**，不是拍的（见 build/sweep_gsc*.py 的实测）：
#   Q=5 最好 +6.90 dB 但 acc 峰值 1.88e9（占 int32 的 88%，换个响场景就溢出）
#   Q=6 +6.89、acc 峰值 9.4e8（45%）   ← 选它：增益只差 0.01 dB，余量翻倍
#   Q=7 +6.88、acc 峰值 9.4e8
# 三档差 0.02 dB ⇒ **0.4 dB 的差距不来自回归量量化**，别在这上面继续堆精度。
Q_SHIFT   = 6             # 回归量 = u >> 6
ACC_SHIFT = 12 - Q_SHIFT  # y = ΣW·h >> (12−Q) 才回到 Σw·u 的量纲
UPD_SHIFT = 1             # 更新里 e 先砍 1 位，防 (e·h) 溢出
# MU_NUM 的取值来自扫描：mu_num=2 给 +0.15 dB、3 给 +0.16 dB、4 起转负。
# μ_eff = MU_NUM/64，3/64 ≈ 0.047 落在浮点最优 0.05 旁边。
MU_NUM = 3

# 更新律开关：True = 倒数替换乘法（现行，与固件一致）；False = 老的截断除法。
# 只有 build/cmp_recip_vs_div.py 会把它设成 False，用来量"换了更新律到底差多少"。
USE_RECIP = True

# 探针：非 None 时，run_gsc3 每样点追加 (nrm, MU_NUM*en)。
# 只给 build/probe_nrm_for_vupd.py 用 —— 它判 VUPD 的 g 会不会溢出。
NRM_TRACE = None


def _tdiv(a, b):
    """向零截断的整除。C 的 `/` 就是这个语义；Python 的 `//` 是 floor，必须显式转换。

    ⚠ **已被 _recip/_rmul 取代，只留作参照**（见下面的"倒数替换除法"）。"""
    a = int(a); b = int(b)
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


# ── 倒数替换除法 ────────────────────────────────────────────────────────────
# 动机：更新环路每个样点做 **112 次除法，而分母 nrm 是同一个**。核里的除法是
#   32 次迭代的恢复余数（~34 拍），乘法是组合逻辑单拍 —— 而且 M 扩展有 mulhu。
#   ⇒ 每个样点只算**一次**倒数，其余 111 次换成 mulhu。
#
# 口径（C 侧写 `((uint64_t)a * r) >> 32`，GCC 直接出 mulhu）：
#     r = ⌊(2³²−1)/nrm⌋ + 1
#   ⇒ r·nrm = 2³² + δ，δ ∈ [0, nrm) ⇒ r = (2³²+δ)/nrm
#   ⇒ a·r/2³² = a/nrm + a·δ/(nrm·2³²) < a/nrm + 0.5   （a < 2³¹）
#   ⇒ **绝对误差 < 1 个最低位，且恒偏大**。|W|max 只有 115 ⇒ 相对误差 ≤ 0.9%。
#   ⚠ 有偏（不是无偏噪声）—— 所以必须**量 SNR**，不能只看"误差很小"就收工。
#   nrm=1 时 r 回绕成 0 ⇒ ΔW=0；而 nrm=1 意味着全部 h=0 ⇒ P=0 ⇒ 本来就该是 0。自洽。
def _recip(nrm):
    """≈ 2³²/nrm 的定点倒数（32 位无符号，与 C 的 `0xFFFFFFFFu/nrm + 1u` 一字不差）。"""
    return (0xFFFFFFFF // int(nrm) + 1) & 0xFFFFFFFF


def _rmul(P, r):
    """trunc(P/nrm)：先取 |P|，乘倒数取高 32 位，再套回符号 —— 对应 C 的 mulhu。"""
    P = int(P)
    a = -P if P < 0 else P
    q = (a * int(r)) >> 32
    return -q if P < 0 else q


def aligned_channels(delays):
    """按 DAS 的约定，逐通道算出**混合信号**（目标+干扰+噪声）。

    返回 (8, N) 的 int64 数组。注意与 DAS 的差别：DAS 把三条分量分开求和，
    GSC 需要的是**每通道的混合**（阻塞矩阵作用在通道上，不能先聚再分）。
    """
    Dt, Di = delays
    out = np.zeros((N_CH, N), dtype=np.int64)
    for m in range(N_CH):
        out[m] = (D.channel("target", m, int(Dt[m]))
                  + D.channel("interf", m, int(Di[m]))
                  + D.channel("noise", m, int(Dt[m])))
    return out


def das_of(a):
    """固定波束形成：等权求和（与 fw_das.c 的 fd8 同一条）。"""
    s = a.sum(axis=0)
    return (s + N_CH // 2) // N_CH


def blocking(a):
    """成对相减，再压回 int16 量程（>>1）。"""
    return (a[:-1] - a[1:]) >> 1


def run_gsc3(a_mix, a_tgt, a_oth):
    """一趟同时算三条：混合（定义/更新轨迹）、目标、其余。

    返回 (e_mix, e_t, e_o, W_final, y_mix)

    ⚠⚠ **轨迹必须由混合信号定义，不能由各自的滤波输出定义。**
       第一版写成"三遍各自用本遍的 y 去更新"，结果三遍的 W 轨迹互不相同
       （滤波对象不同 ⇒ y 不同 ⇒ 误差不同 ⇒ 更新不同），SNR 的分子分母就来自
       三个不同的滤波器，比值没有意义。是三遍 W 的逐位断言把这个问题抓出来的。
       正确做法：**更新永远只看混合那一路**；e_t / e_o 只用来报数，不参与更新。
    """
    d_mix, d_t, d_o = das_of(a_mix), das_of(a_tgt), das_of(a_oth)
    u_mix, u_t, u_o = blocking(a_mix), blocking(a_tgt), blocking(a_oth)

    W = np.zeros((N_REF, L_TAPS), dtype=np.int64)
    # 三条延迟线，k=0 最新。历史只保留 int16 量级的 u
    h_mix = np.zeros((N_REF, L_TAPS), dtype=np.int64)
    h_t = np.zeros((N_REF, L_TAPS), dtype=np.int64)
    h_o = np.zeros((N_REF, L_TAPS), dtype=np.int64)
    e_mix = np.zeros(N, dtype=np.int64)
    e_t = np.zeros(N, dtype=np.int64)
    e_o = np.zeros(N, dtype=np.int64)
    y_mix = np.zeros(N, dtype=np.int64)

    def filt(h):
        """h 就是回归量本身（已经砍过 Q_SHIFT），滤波与更新因此是同一个量。"""
        acc = 0
        for j in range(N_REF):
            for k in range(L_TAPS):
                acc += int(W[j, k]) * int(h[j, k])
        return acc >> ACC_SHIFT

    for n in range(N):
        for h, u in ((h_mix, u_mix), (h_t, u_t), (h_o, u_o)):
            h[:, 1:] = h[:, :-1]                     # 右移
            h[:, 0] = u[:, n] >> Q_SHIFT             # 存**回归量**，不是原始 u

        y_mix[n] = filt(h_mix)
        e_mix[n] = int(d_mix[n]) - y_mix[n]
        e_t[n] = int(d_t[n]) - filt(h_t)
        e_o[n] = int(d_o[n]) - filt(h_o)

        # 范数 + 更新：**只看混合那一路**，且用与滤波相同的 h_mix
        nrm = D0
        for j in range(N_REF):
            for k in range(L_TAPS):
                nrm += int(h_mix[j, k]) * int(h_mix[j, k])
        en = int(e_mix[n]) >> UPD_SHIFT
        if NRM_TRACE is not None:           # 探针：见 build/probe_nrm_for_vupd.py
            NRM_TRACE.append((nrm, MU_NUM * en))
        r = _recip(nrm)                     # 一个样点只算一次（原来是 112 次除法）
        K = MU_NUM * en
        for j in range(N_REF):
            for k in range(L_TAPS):
                if USE_RECIP:
                    W[j, k] += _rmul(K * int(h_mix[j, k]), r)
                else:                       # 老口径（除法），只给对比脚本用
                    W[j, k] += _tdiv(K * int(h_mix[j, k]), nrm)
                if W[j, k] > W_LIM_Q12:  W[j, k] = W_LIM_Q12
                if W[j, k] < -W_LIM_Q12: W[j, k] = -W_LIM_Q12

    return e_mix, e_t, e_o, W, y_mix


def _cksum(v):
    c = 0
    for x in v:
        c = (c + int(x)) & 0xFFFFFFFF
    return c


def _wcksum(v):
    c = 0
    for n, x in enumerate(v):
        c = (c + int(x) * (n + 1)) & 0xFFFFFFFF
    return c


def _powacc(v):
    return sum(((int(x) >> 3) ** 2) for x in v)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    Dt, Di = D.build_tables()[:2]

    # 三条分量**分开**建：噪声只归到「其余」里，不能两边都算 ——
    # 否则 DAS 基线的分子分母口径就错了（与 check_bf.py 的 other = a_n + a_i 对齐）
    a_tgt = np.zeros((N_CH, N), dtype=np.int64)
    a_oth = np.zeros((N_CH, N), dtype=np.int64)
    for m in range(N_CH):
        a_tgt[m] = D.channel("target", m, int(Dt[m]))
        a_oth[m] = D.channel("interf", m, int(Di[m])) + D.channel("noise", m, int(Dt[m]))
    a_mix = a_tgt + a_oth

    # 固定波束形成（DAS）在同样两个分量上的输出 —— 对照的基线
    d_t_all = das_of(a_tgt)
    d_o_all = das_of(a_oth)
    snr_das = 10 * np.log10(np.mean(d_t_all.astype(float) ** 2) /
                            (np.mean(d_o_all.astype(float) ** 2) + 1e-30))
    snr_mic = 10 * np.log10(np.mean(a_tgt[0].astype(float) ** 2) /
                            (np.mean(a_oth[0].astype(float) ** 2) + 1e-30))

    e_mix, e_t, e_o, W1, _ = run_gsc3(a_mix, a_tgt, a_oth)

    p_t, p_o = _powacc(e_t), _powacc(e_o)
    snr_gsc = 10 * np.log10(p_t / (p_o + 1e-30))

    fp = {
        "e_cksum": _cksum(e_t),
        "e_wcksum": _wcksum(e_t),
        "p_e_target": p_t,
        "p_e_other": p_o,
        # 混合信号的固定波束输出（诊断用：确认 GSC 的输入确实带干扰）
        "mix_cksum": _cksum(np.clip(das_of(a_mix), -32768, 32767)),
        "w_ck": int(W1.sum()) & 0xFFFFFFFF,
    }
    with open(os.path.join(root, "build", "fw_gsc_fp.hex"), "w", encoding="ascii") as f:
        for k in ("e_cksum", "e_wcksum", "p_e_target", "p_e_other", "mix_cksum", "w_ck"):
            f.write("%08x\n" % (fp[k] & 0xFFFFFFFF))

    print("== GSC 定点模型（L=%d 抽头，Q%d 权值，mu_num=%d）==" % (L_TAPS, W_SHIFT, MU_NUM))
    print("   单麦     %+.2f dB" % snr_mic)
    print("   DAS      %+.2f dB" % snr_das)
    print("   GSC      %+.2f dB   （相对 DAS %+.2f dB）" % (snr_gsc, snr_gsc - snr_das))
    print("   |W| 末值 max = %d (Q12) = %.3f" % (np.abs(W1).max(), np.abs(W1).max() / (1 << W_SHIFT)))
    print("   指纹：e_cksum=0x%08X e_wcksum=0x%08X w_ck=0x%08X"
          % (fp["e_cksum"], fp["e_wcksum"], fp["w_ck"]))


if __name__ == "__main__":
    main()
