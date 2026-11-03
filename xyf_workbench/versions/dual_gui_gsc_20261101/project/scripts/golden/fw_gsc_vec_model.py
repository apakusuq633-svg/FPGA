"""GSC 用 SIMD-MAC 阵列算 —— **模型**。设计见 docs/gsc_vec_design.md。

与标量模型 `fw_gsc_model.py` 逐位可比的同一场景，区别只在**滤波与更新怎么算**：

    标量版：  acc = Σ_j Σ_k W[j][k]·h_j(n−k)        ;  y = acc >> 6
    阵列版：  1) 7 路交织进一条延迟线：x(7n+j) = h_j(n)·2^S
              2) 阵列 y = Σ_t C[t]·x(nn−t)          ;  nn = 7n+6（写指针减一）
              3) 固定件：y = A >> (S + 6)
              4) 更新走 VUPD：C[t] += (g·x[t]) >> 16 ，g = K·2^(16−S)/nrm

⚠⚠ **本文的每一处定标都必须与固件一字不差**，否则指纹对不上。
   §0 的规矩：模型是定点口径的**唯一出处**。
"""
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fw_gsc_model as G       # 复用场景、常数、_tdiv/_recip 等口径
import fw_das_model as D       # noqa: E402

NR, LT, NT = G.N_REF, G.L_TAPS, 120     # 7 路 × 16 抽头，120 抽头（8 的倍数 ≥ 113）
S_SHIFT = 5                              # 回归量左移：阵列侧硬约束 |h·2^S| < 2^15
DL_DEPTH = 512                           # 延迟线深度（阵列是 64 字 × 8 bank）
I16_MIN, I16_MAX = -32768, 32767


def _tdiv(a, b):
    """向零截断整除（C 的 `/`）。"""
    a = int(a); b = int(b)
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def _asr(a, b):
    """算术右移 = floor。C 的 `>>` 就是这个语义，Python 的 `>>` 也是 —— 但必须显式写清。"""
    return int(a) >> int(b)


class Array:
    """阵列的可执行模型：3 条延迟线 + 1 套系数（24 位存储，高 16 位是有效系数）。"""

    def __init__(self):
        # 3 条线：0=mix(x 线) 1=tgt(x'[0]) 2=oth(x'[1])
        self.line = [[0] * DL_DEPTH for _ in range(3)]
        self.wp = [0, 0, 0]                       # 写指针
        self.coef = [0] * NT                      # 24 位存储，C_eff = storage >> 8

    def push(self, ln, v):
        v = max(I16_MIN, min(I16_MAX, int(v)))
        self.line[ln][self.wp[ln]] = v
        self.wp[ln] = (self.wp[ln] + 1) % DL_DEPTH

    def vred(self, ln):
        """Σ_t C_eff[t]·x(nn−t)，nn = 写指针 − 1。"""
        nn = (self.wp[ln] - 1) % DL_DEPTH
        acc = 0
        for t in range(NT):
            acc += (self.coef[t] >> 8) * self.line[ln][(nn - t) % DL_DEPTH]
        return acc

    def vupd(self, ln, g):
        """C_storage[t] += ((g·x(nn−t)) >> 15) << 8 ，再**饱和**到 24 位。

        ⚠⚠ 是 **>>15**，不是 >>16：`rtl/vec/rv32_vec_unit.v:280` 写的是 `gmul >>> 15`
          （注释说"取高 16 位"，但那是 [30:15]）。**按注释写成 >>16 会让步长翻倍。**
          实测指纹：g=x=256 时每个抽头 +2 而不是 +1（`tb_gsc_vec_map`）。
        ⚠ 写回是**饱和**不是回绕：`updated > 2^23-1 ? 0x7fffff : ... < -2^23 ? 0x800000 : ...`
          ⇒ 有效系数 C_eff 饱和在 ±2^15 = ±32768（Q12 口径）。
        """
        g = max(I16_MIN, min(I16_MAX, int(g)))
        nn = (self.wp[ln] - 1) % DL_DEPTH
        for t in range(NT):
            x = self.line[ln][(nn - t) % DL_DEPTH]
            dq15 = _asr(g * x, 15)
            v = self.coef[t] + (dq15 << 8)
            if v >  8388607: v =  8388607
            if v < -8388608: v = -8388608
            self.coef[t] = v

    def load_w(self, W):
        """把 Q12 权值按交织重排塞进系数存储：t = (6−j) + 7k。"""
        self.coef = [0] * NT
        for j in range(NR):
            for k in range(LT):
                t = (6 - j) + NR * k
                self.coef[t] = int(W[j, k]) << 8


def run_gsc_vec(a_mix, a_tgt, a_oth):
    """与 G.run_gsc3 同场景、同更新律，但滤波与更新走阵列。

    返回 (e_mix, e_t, e_o, W_out, y_mix)  —— 与 run_gsc3 同形状，便于直接比。
    """
    NS = a_mix.shape[1]
    arr = Array()

    # ⚠ 场景与阻塞矩阵**直接复用**标量模型的口径（das_of / blocking），
    #   不在这里另写一套 —— 口径的唯一出处是 fw_gsc_model.py。
    d_mix, d_t, d_o = G.das_of(a_mix), G.das_of(a_tgt), G.das_of(a_oth)
    u_mix, u_t, u_o = G.blocking(a_mix), G.blocking(a_tgt), G.blocking(a_oth)

    W = np.zeros((NR, LT), dtype=np.int64)      # 固件侧的 W（Q12），与系数存储镜像
    arr.load_w(W)

    h_hist = np.zeros((NR, LT), dtype=np.int64)  # 只为算范数保留（阵列不给 Σx²）
    e_mix = np.zeros(NS, dtype=np.int64)
    e_t = np.zeros(NS, dtype=np.int64)
    e_o = np.zeros(NS, dtype=np.int64)
    y_mix = np.zeros(NS, dtype=np.int64)

    g_sat = 0
    for n in range(NS):
        # ── 交织推入：位置 7n+j 放 ref j 的回归量（左移 S_SHIFT）──────────
        for ln, u in ((0, u_mix), (1, u_t), (2, u_o)):
            for j in range(NR):
                arr.push(ln, (int(u[j, n]) >> G.Q_SHIFT) << S_SHIFT)

        # ── 阵列滤波： y = A >> (S_SHIFT + ACC_SHIFT) ──────────────────
        y_mix[n] = _asr(arr.vred(0), S_SHIFT + G.ACC_SHIFT)
        e_mix[n] = int(d_mix[n]) - y_mix[n]
        e_t[n] = int(d_t[n]) - _asr(arr.vred(1), S_SHIFT + G.ACC_SHIFT)
        e_o[n] = int(d_o[n]) - _asr(arr.vred(2), S_SHIFT + G.ACC_SHIFT)

        # ── 范数：阵列不给 Σx²，固件自己维护滑动和 ────────────────────
        for j in range(NR):
            h_hist[j, 1:] = h_hist[j, :-1]
            h_hist[j, 0] = int(u_mix[j, n]) >> G.Q_SHIFT
        nrm = G.D0 + int((h_hist * h_hist).sum())

        # ── 更新：走 VUPD。 g = K·2^(**15**−S)/nrm ─────────────────────
        # ⚠ 指数里的 15 来自 RTL 的 `gmul >>> 15`（见 Array.vupd）。写 16 会让步长翻倍。
        # ⚠ 固件用 int32（写 int64 会拉进 __divdi3），所以先把 K 钳在 2^21 ——
        #   `K<<10` 溢出 int32 的界。实测本场景 |K| 最大 ~16,000，**一次都不触发**，
        #   但模型必须与固件**同一条钳位**，否则哪天触发了就对不上。
        K = G.MU_NUM * (e_mix[n] >> G.UPD_SHIFT)
        Kc = max(-2097152, min(2097152, K))
        g = _tdiv(Kc * (1 << (15 - S_SHIFT)), nrm)
        if g > I16_MAX or g < I16_MIN:
            g = I16_MAX if g > 0 else I16_MIN
            g_sat += 1
        arr.vupd(0, g)

        # 固件侧的 W 只是系数存储的镜像（用于报数/比对）
        for j in range(NR):
            for k in range(LT):
                W[j, k] = arr.coef[(6 - j) + NR * k] >> 8

    return e_mix, e_t, e_o, W, y_mix, g_sat


if __name__ == "__main__":
    Dt, Di = D.build_tables()[:2]
    N = D.N_SAMP
    NC = int(Dt.size)
    a_tgt = np.zeros((NC, N), dtype=np.int64)
    a_oth = np.zeros((NC, N), dtype=np.int64)
    for m in range(NC):
        a_tgt[m] = D.channel("target", m, int(Dt[m]))
        a_oth[m] = D.channel("interf", m, int(Di[m])) + D.channel("noise", m, int(Dt[m]))
    a_mix = a_tgt + a_oth

    _, et_s, eo_s, W_s, _ = G.run_gsc3(a_mix, a_tgt, a_oth)
    _, et_v, eo_v, W_v, _, g_sat = run_gsc_vec(a_mix, a_tgt, a_oth)

    def db(n, d):
        return 10.0 * np.log10(n / (d + 1e-30))

    snr_s = db(G._powacc(et_s), G._powacc(eo_s))
    snr_v = db(G._powacc(et_v), G._powacc(eo_v))
    print("== GSC：标量 vs 阵列 ==")
    print("  标量（现固件）%+.3f dB" % snr_s)
    print("  阵列（本模型）%+.3f dB     差 %+.3f dB" % (snr_v, snr_v - snr_s))
    print("  g 饱和次数 %d / %d" % (g_sat, len(et_v)))

    # ── 负例对照：阵列通路必须**真的在算**，否则 +7.1 分不清"算对了"与"没接线" ──
    # 判据：① 权值真的自适应了（|W| 远大于 0）② 滤波输出非零 ③ 两版权值**不同**
    _, _, _, W_s2, y_s = G.run_gsc3(a_mix, a_tgt, a_oth)
    y_v = np.array([int(d) for d in (G.das_of(a_mix) - (G.das_of(a_mix) - np.array(
        [0] * len(et_v))))])   # 占位，下面直接算
    print()
    print("  对照（这几条不成立就说明阵列通路是死的）：")
    print("    |W|max  标量 %d / 阵列 %d        （都必须 ≫ 0）"
          % (np.abs(W_s2).max(), np.abs(W_v).max()))
    print("    非零权值 标量 %d / 阵列 %d   / %d"
          % (int((W_s2 != 0).sum()), int((W_v != 0).sum()), W_v.size))
    print("    两版权值不同位数 %d / %d        （不同才对：更新律本来就不同）"
          % (int((W_s2 != W_v).sum()), W_v.size))
    print("    e_t 非零样点 %d / %d" % (int((et_v != 0).sum()), len(et_v)))
    print("  ⚠ 两版**不该**逐位相同（定标不同），要比的是 SNR 与相对 DAS 的增益。")

    # 阵列那路的指纹给 TB 用（p_e_target / p_e_other，与固件同一条 `>>3 再平方`）
    fp = os.path.join(HERE, "..", "..", "build", "fw_gsc_vec_fp.hex")
    with open(fp, "w") as f:
        f.write("%08x\n" % (G._powacc(et_v) & 0xFFFFFFFF))
        f.write("%08x\n" % (G._powacc(eo_v) & 0xFFFFFFFF))
    print("  指纹已写 %s" % os.path.normpath(fp))
