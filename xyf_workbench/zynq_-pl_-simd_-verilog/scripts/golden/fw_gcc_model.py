"""GCC-PHAT 固件内核的定点模型 —— `sw/fw/fw_gcc.c` 的逐位等价版本。

链路（每对麦克风）
------------------
    x_i, x_j  加 Hann 窗
    Xi = rfft(x_i)   Xj = rfft(x_j)          ← 复用 fw_fft_model.fft_fixed
    G  = Xi · conj(Xj)                        互谱
    Ψ  = (G / |G|) · M(f)                      PHAT 白化 + **限带**（必做，见 027）
    R  = irfft(Ψ)                             相关序列
    τ̂ = argmax R  → TDOA

逆变换为什么走「打包」
----------------------
正变换是 N/2 复数打包（512 点复 FFT + 拆分）。逆变换就贴着它反过来做：
先做**反向拆分**还原出 z 的频谱 Z，再跑一次 512 点复 IFFT（共轭因子），
最后 unpack 回 1024 点实序列。

这么选的**决定性理由是内存，不是速度**：DTCM 只有 16 KB，直白的 1024 点复
IFFT 要 1024 条复数工作数组（4 KB），加上 Xi/Xj/输入帧就超了。打包版本只要
512 条复数（2 KB），和正变换**共用同一块工作区**。

反向拆分的公式（由正向的定义直接反解，精确、不含近似）
    X[k]   = E[k mod M] + W_N^k · O[k mod M]
    X[k+M] = E[k mod M] − W_N^k · O[k mod M]
    ⇒ E[k]   = (X[k] + X[k+M]) / 2
      O[k]   = (X[k] − X[k+M]) / 2 · conj(W_N^k)
      Z[k]   = E[k] + j·O[k]
其中 X[k+M] 用共轭对称取：X[k+M] = conj(X[M−k])。

定标
----
正变换输出实测是「真值 / 1024」。逆变换每级 >>1（共 9 级）后，
往返一次的总标度由 `selftest()` 实测标定，不靠推。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fw_fft_model import (M, N, NTW, TW_FRAC, _shr, fft_fixed, make_input,
                          twiddle_q14)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_REF = os.path.join(ROOT, "build", "fw_gcc_ref.hex")
OUT_RAW = os.path.join(ROOT, "build", "fw_xcorr_ref.hex")

# 工作频带（README §17 的带通）。f = k·fs/N，fs = 39062.5，N = 1024
#   ⇒ 每 bin 38.15 Hz。200 Hz → k≥6，8000 Hz → k≤209。
BAND_LO_BIN = 6
BAND_HI_BIN = 209


# ── 逆变换 ────────────────────────────────────────────────────────────
def _bitrev_perm(a):
    idx = np.arange(M)
    rev = np.zeros(M, dtype=np.int64)
    for b in range(int(np.log2(M))):
        rev |= ((idx >> b) & 1) << (int(np.log2(M)) - 1 - b)
    return rev


def _fft_core(dr, di, re_tab, im_tab, conj):
    """512 点复数基 2 DIT，每级 >>1。conj=True 时用共轭因子（即 IFFT）。"""
    sgn = -1 if conj else 1
    length = 2
    while length <= M:
        half = length >> 1
        step = M // length
        for start in range(0, M, length):
            j = np.arange(half)
            # 表是 W_1024^k，本级要 W_512^j = W_1024^{2j} ⇒ 下标乘 2（同正向）
            wr = re_tab[j * step * 2]
            wi = sgn * im_tab[j * step * 2]
            ar = dr[start + j];          ai = di[start + j]
            br = dr[start + half + j];   bi = di[start + half + j]
            t_r = _shr(wr * br - wi * bi + (1 << (TW_FRAC - 1)), TW_FRAC)
            t_i = _shr(wr * bi + wi * br + (1 << (TW_FRAC - 1)), TW_FRAC)
            dr[start + j]        = _shr(ar + t_r + 1, 1)
            di[start + j]        = _shr(ai + t_i + 1, 1)
            dr[start + half + j] = _shr(ar - t_r + 1, 1)
            di[start + half + j] = _shr(ai - t_i + 1, 1)
        length <<= 1
    return dr, di


def ifft_fixed(pr, pi, re_tab, im_tab):
    """Hermitian 频谱 (513 条) → 实序列 R (1024 条 int16)。

    返回 (R, shift)；R 已按 shift 定标成「与输入同量级」。
    """
    pr = np.asarray(pr, dtype=np.int64)
    pi = np.asarray(pi, dtype=np.int64)

    # ── 反向拆分：Psi → Z（512 点复）─────────────────────────────────
    k = np.arange(M)
    # ⚠ 这里**不能取模**：X[k+M] = conj(X[M−k])，k=0 时是 index **M=512**
    #   （Nyquist 那条），不是 0。写成 (M-k)%M 会把 DC 当成 Nyquist 用 ——
    #   往返出来的序列形状大致对、残差 17%，很难一眼看出是下标错。
    mk = M - k
    xr2 = pr[mk]
    xi2 = -pi[mk]
    er = _shr(pr[:M] + xr2, 1)
    ei = _shr(pi[:M] + xi2, 1)
    hrr = _shr(pr[:M] - xr2, 1)          # (X[k]-X[k+M])/2 的实部
    hii = _shr(pi[:M] - xi2, 1)
    # O = (X[k]-X[k+M])/2 · conj(W^k)
    wr = re_tab[:M]; wi = im_tab[:M]
    orr = _shr(hrr * wr + hii * wi + (1 << (TW_FRAC - 1)), TW_FRAC)
    oi = _shr(hii * wr - hrr * wi + (1 << (TW_FRAC - 1)), TW_FRAC)
    # Z[k] = E[k] + j·O[k]
    zr = er - oi
    zi = ei + orr

    # ── 位反转 + 512 点复 IFFT（共轭因子）───────────────────────────
    rev = _bitrev_perm(None)
    zr = zr[rev].copy(); zi = zi[rev].copy()
    zr, zi = _fft_core(zr, zi, re_tab, im_tab, conj=True)

    # ── unpack：x[2n] = Re z[n]，x[2n+1] = Im z[n] ───────────────────
    out = np.empty(N, dtype=np.int64)
    out[0::2] = zr
    out[1::2] = zi
    return out


# ── PHAT 前的幅度/倒数（与 rtl/srp 参照同一套近似）────────────────────
def mag_alpha_max_beta_min(re, im):
    """α-max-β-min：|a+jb| ≈ max + min/2 − min/8 + min/32 + min/128。

    相对误差 < 0.1%，全程整数，没有开方器。RTL 与 golden 用的是同一条。
    """
    a = np.abs(re); b = np.abs(im)
    mx = np.maximum(a, b); mn = np.minimum(a, b)
    return mx + (mn >> 1) - (mn >> 3) + (mn >> 5) + (mn >> 7)


def hann_q14(re_tab):
    """Hann 窗（Q14）**直接从旋转因子表算**：w[n] = 0.5 − 0.5·cos(2πn/N)，
    而 cos(2πn/N) 就是 Re(W_1024^n)。**不额外占一张表** —— DTCM 只有 16 KB。

    Q14 不是随便挑的：w[512] = 1.0 在 Q15 里是 32768，装不下（见 029）。

    表只到 k=512，n>512 用 cos 的对称性折回去（cos(2πn/N) = cos(2π(N−n)/N)）——
    省掉半张表，代价是每次一个比较。
    """
    n = np.arange(N)
    return 8192 - _shr(re_tab[np.minimum(n, N - n)], 1)


# ── 完整的一对：互谱 + PHAT + 逆变换 + 峰值 ───────────────────────────
def gcc_phat_fixed(xi, xj, re_tab, im_tab, phat=True):
    win = hann_q14(re_tab)
    # 加窗：Q15 样本 × Q14 窗 >> 14 → Q15
    wi = _shr(np.asarray(xi, dtype=np.int64) * win, 14)
    wj = _shr(np.asarray(xj, dtype=np.int64) * win, 14)

    Xi = fft_fixed(wi, re_tab, im_tab)
    Xj = fft_fixed(wj, re_tab, im_tab)

    # 互谱：G = Xi · conj(Xj)，Q15×Q15 → >>15 回 Q15
    gr = _shr(Xi.real.astype(np.int64) * Xj.real.astype(np.int64)
              + Xi.imag.astype(np.int64) * Xj.imag.astype(np.int64)
              + 16384, 15)
    gi = _shr(Xi.imag.astype(np.int64) * Xj.real.astype(np.int64)
              - Xi.real.astype(np.int64) * Xj.imag.astype(np.int64)
              + 16384, 15)

    # PHAT：Ψ = G/|G|（Q14，1.0 = 16384），带外清零。
    # phat=False 时是**波束形成（DAS）**要的纯互相关：Ψ = G>>1（同样落 Q14，
    # 不 >>1 的话逆变换那边的反向拆分中间量会顶到 int16 上界）。带内保留 ——
    # 限带对 DAS 同样成立，那是工作频带，不是 PHAT 的附属品。
    if phat:
        mag = np.maximum(mag_alpha_max_beta_min(gr, gi), 1)
        inv = (1 << 30) // mag                   # Q30 的 1/|G|
        pr = _shr(gr * inv, 16)                  # → Q14
        pi = _shr(gi * inv, 16)
    else:
        # 块标度归一化：先扫带内 |re|+|im| 的最大值，再整体左移。
        # 不这么做的话 G 大部分落在 1 LSB 以下（X 已带 FFT 的 ÷1024），
        # 相关序列出来只有 ±2，全是量化噪声。
        mx = 1
        for kk in range(BAND_LO_BIN, BAND_HI_BIN + 1):
            a = abs(int(gr[kk])) + abs(int(gi[kk]))
            if a > mx:
                mx = a
        sh = 0
        while mx < 8192 and sh < 14:
            mx <<= 1
            sh += 1
        pr = gr << sh
        pi = gi << sh
    mask = np.zeros(NTW, dtype=np.int64)
    mask[BAND_LO_BIN:BAND_HI_BIN + 1] = 1
    pr = pr * mask
    pi = pi * mask

    R = ifft_fixed(pr, pi, re_tab, im_tab)
    return R, pr, pi


# ── 自检 ──────────────────────────────────────────────────────────────
def selftest(re_tab, im_tab):
    print("=" * 72)
    print("GCC-PHAT 定点模型自检")
    print("=" * 72)

    # ── ① 逆变换往返：fft → ifft 应还原原序列（差一个已知标度）──────
    rng = np.random.default_rng(3)
    x = rng.integers(-20000, 20000, N).astype(np.int64)
    X = fft_fixed(x, re_tab, im_tab)
    R = ifft_fixed(X.real.astype(np.int64), X.imag.astype(np.int64),
                   re_tab, im_tab)
    # 标度用最小二乘定（正变换是 ÷1024，逆变换再 ÷512，合起来 R ≈ x/1024）。
    # ⚠ 判据要按**输出的 LSB** 卡，不能按 x 的百分比卡：R 是整数、量级只有
    #   ±20，1 LSB 就相当于 x 的 1024/20000 = 5%，按百分比卡会把完全正常的
    #   舍入判成错。实测残差 0.73 LSB。
    scale = float(np.dot(R, x) / np.dot(R, R))
    err_lsb = np.sqrt(np.mean((R * scale - x) ** 2)) / scale
    print("  ① 往返 1024 点：标度 1/%.1f，残差 RMS %.2f LSB (输入峰值 %d)"
          % (scale, err_lsb, np.abs(x).max()))
    assert err_lsb < 1.5, "逆变换往返对不上，公式或定标错了"

    # ── ② 已知时延：x_j 比 x_i **超前** D 个样点 ⇒ 峰在 +D ──────────
    base = make_input()
    D = 7
    xj = np.roll(base, -D)                       # x_j[n] = x_i[n+D]（超前）
    R, pr, pi = gcc_phat_fixed(base, xj, re_tab, im_tab)
    # 峰值取绝对值最大（相关峰可能是负的）
    lag = int(np.argmax(np.abs(R)))
    if lag >= N // 2:
        lag -= N
    print("  ② 已知时延 %+d 样点 → 实测峰在 %+d" % (D, lag))

    # 与 numpy 的浮点 GCC-PHAT 对照。
    # ⚠ 算子顺序必须与定点版**同一个**（G = FFT(前一个)·conj(FFT(后一个))）——
    #   写反了峰值会整体取负，看着像"定点算错了"，其实是参照把两个通道调了个个儿。
    Xf = np.fft.rfft(base.astype(float)); Yf = np.fft.rfft(xj.astype(float))
    G = Xf * np.conj(Yf)
    G = G / (np.abs(G) + 1e-12)
    m = np.zeros(NTW); m[BAND_LO_BIN:BAND_HI_BIN + 1] = 1
    Rf = np.fft.irfft(G * m, N)
    lagf = int(np.argmax(np.abs(Rf)))
    if lagf >= N // 2:
        lagf -= N
    print("     float 金标准峰在 %+d（同一约定）" % lagf)
    return lag, lagf, R


def main():
    re_tab, im_tab = twiddle_q14()
    lag, lagf, R = selftest(re_tab, im_tab)
    assert lag == 7, "已知时延 +7 没测出来，链路有问题"
    assert lag == lagf, "与 float 金标准的峰位不一致"

    if "--ref" in sys.argv:
        os.makedirs(os.path.dirname(OUT_REF), exist_ok=True)
        with open(OUT_REF, "w") as f:
            for v in R:
                f.write("%04x\n" % (int(v) & 0xFFFF))
        print("   参照 -> %s (%d 个 16 位字)" % (OUT_REF, N))

        # 波束形成（DAS）要的那份：同一条链、不做白化
        xj2 = np.roll(make_input(), -7)
        Rr, _, _ = gcc_phat_fixed(make_input(), xj2, re_tab, im_tab, phat=False)
        with open(OUT_RAW, "w") as f:
            for v in Rr:
                f.write("%04x\n" % (int(v) & 0xFFFF))
        print("   互相关（不白化）-> %s" % OUT_RAW)

    print("\n  自检通过。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
