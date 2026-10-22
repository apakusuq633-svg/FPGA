#!/usr/bin/env python3
"""AEC: 时域 NLMS vs 频域分块 PBFDAF —— 分析脚本，不参与构建与验证。

回答一个问题：N=2048 @ 16 kHz 的 AEC，时域 NLMS 到底输在哪、输多少。
做两件事：
  [1] 代价/延迟模型：PBFDAF 相对时域 NLMS 省多少算术，附加延迟多少。
  [2] 数值仿真：同一房间冲激响应 + 同一有色输入，量收敛速度与稳态 ERLE。

结论摘要见 README 里对应段落。脚本本身只是把数字算出来，不做判断。

跑法（WSL）：
    wsl -e python3 scripts/aec_td_vs_fd.py
"""

import math
import numpy as np

FS = 16000
N = 2048                 # 抽头数 = 128 ms @ 16 kHz
RT60 = 0.20              # 房间混响时间
BULK = 96                # 扬声器-麦克风体延迟（样本），6 ms


# ---------------------------------------------------------------------------
# [1] 代价模型
# ---------------------------------------------------------------------------
# 口径：实乘次数。复数乘法 = 4 实乘；实 FFT size M 约 (M/2)*log2(M) 个复乘。
# PBFDAF：重叠保留，DFT size M=2L，K=N/L 个分块。
#   每块（L 个样本）：1 次实 FFT + 1 次实 IFFT（输入块的 DFT 跨块复用）
#                   + K 次复乘（滤波）+ K 次复乘（权更新）
#   约束更新（MDF）：每个分块再加 IFFT + 清零 + FFT = 2 次 size-M 变换

def td_cost(n):
    """时域 NLMS 每样本实乘：滤波 n 次 + 权更新 n 次（归一化能量 O(1) 摊掉）。"""
    return 2 * n


def fd_cost(n, L):
    """返回 (每块实乘, 每样本实乘-无约束, 每样本实乘-加约束, K, M)。"""
    K, M = n // L, 2 * L
    xform = (M / 2) * math.log2(M) * 4          # 一次实 size-M 变换的实乘数
    uc = 2 * xform + 2 * K * 4                   # FFT+IFFT + 滤波 + 更新
    con = uc + 2 * K * xform                     # 每分块 2 次变换
    return uc, uc / L, con / L, K, M


def delay_samples(L):
    """重叠保留 PBFDAF 算法延迟 = 2L-1 样本（下界 L）。Moonen/Eneman 同口径。"""
    return 2 * L - 1


def section_cost():
    print('=' * 78)
    print('[1] 代价与延迟：N=2048 @ 16 kHz')
    print('=' * 78)
    td = td_cost(N)
    print(f'时域 NLMS：{td} 实乘/样本 = {td*FS/1e6:.1f} MMAC/s')
    print(f'  闭式：约束 PBFDAF 相对时域的加速比 = L / (4*log2(2L))，只与 L 有关，与 N 无关')
    print()
    hdr = (f"{'L':>5}{'K':>5}{'M':>6}{'无约束/样本':>13}{'约束/样本':>12}"
           f"{'约束 vs 时域':>14}{'闭式':>8}{'延迟(samp)':>11}{'延迟(ms)':>10}"
           f"{'G.167 2ms':>10}{'G.167 16ms':>11}")
    print(hdr)
    print('-' * 100)
    for L in [8, 16, 32, 64, 128, 256, 512]:
        uc, uc_s, con_s, K, M = fd_cost(N, L)
        d = delay_samples(L)
        dms = d / FS * 1000
        closed = L / (4 * math.log2(2 * L))
        print(f'{L:>5}{K:>5}{M:>6}{uc_s:>13.1f}{con_s:>12.1f}'
              f'{td/con_s:>13.2f}x{closed:>8.2f}'
              f'{d:>11}{dms:>10.2f}'
              f'{"PASS" if dms <= 2 else "FAIL":>10}'
              f'{"PASS" if dms <= 16 else "FAIL":>11}')
    print()
    print('G.167 约束换算：2 ms 预算 -> 2L-1 <= 32 -> L <= 16；16 ms -> L <= 128')
    print()
    LANES, FCLK = 32, 40e6
    bud = FCLK / FS
    print(f'本项目 32 lane x 16-bit @ {FCLK/1e6:.0f} MHz，16 kHz 样本预算 {bud:.0f} 拍：')
    for n in (1024, 2048):
        mac = 2 * n
        print(f'  N={n}: 归约 {n} + 逐元素 {n} = {mac} MAC -> {mac/LANES:.0f} 拍 '
              f'= {mac/LANES/bud*100:.2f}% 预算')
    print()


# ---------------------------------------------------------------------------
# [2] 数值仿真
# ---------------------------------------------------------------------------

def make_rir(n, rt60, bulk, seed=1):
    """指数衰减白噪 + 体延迟 —— 合成房间冲激响应。"""
    rng = np.random.default_rng(seed)
    t = np.arange(n - bulk) / FS
    h = rng.standard_normal(n - bulk) * np.exp(-6.9 * t / rt60)
    h[:64] *= 0.15
    h = np.concatenate([np.zeros(bulk), h])[:n]
    return h / np.sqrt(np.sum(h ** 2))


def make_input(nsamp, seed=2):
    """有色（类语音）输入：两个共振峰极点 r=0.95 @ 500/1500 Hz 驱动的 AR 过程。"""
    rng = np.random.default_rng(seed)
    e = rng.standard_normal(nsamp)
    aa = np.poly([0.95 * np.exp(1j * 2 * math.pi * 500 / FS),
                  0.95 * np.exp(-1j * 2 * math.pi * 500 / FS),
                  0.95 * np.exp(1j * 2 * math.pi * 1500 / FS),
                  0.95 * np.exp(-1j * 2 * math.pi * 1500 / FS)]).real
    x = np.zeros(nsamp)
    for i in range(nsamp):
        acc = e[i]
        for k in range(1, len(aa)):
            if i - k >= 0:
                acc -= aa[k] * x[i - k]
        x[i] = acc
    return x / (np.std(x) + 1e-12)


def run_nlms(x, d, n, mu, eps=1e-6):
    """时域 NLMS：逐样本，窗能量归一化。"""
    nsamp = len(x)
    w, e = np.zeros(n), np.zeros(nsamp)
    xpad = np.concatenate([np.zeros(n - 1), x])
    for i in range(nsamp):
        xv = xpad[i:i + n]
        ei = d[i] - np.dot(w, xv)
        e[i] = ei
        w += mu * ei * xv / (np.dot(xv, xv) + eps)
    return e


def run_pbfdaf(x, d, n, L, mu, constrained=False, smooth=0.8):
    """PBFDAF（重叠保留）。constrained=True 即 MDF：每分块 2 次额外变换。"""
    K, M = n // L, 2 * L
    nsamp = len(x)
    W = np.zeros((K, M // 2 + 1), dtype=complex)
    Xr = np.zeros((K, M // 2 + 1), dtype=complex)
    power = np.ones(M // 2 + 1) * 1e-6
    xprev, e = np.zeros(L), np.zeros(nsamp)
    for b in range(nsamp // L):
        xb = x[b * L:(b + 1) * L]
        X = np.fft.rfft(np.concatenate([xprev, xb]))
        Xr = np.roll(Xr, 1, axis=0)
        Xr[0] = X
        y = np.fft.irfft(np.sum(W * Xr, axis=0), M)[L:]
        eb = d[b * L:(b + 1) * L] - y
        e[b * L:(b + 1) * L] = eb
        E = np.fft.rfft(np.concatenate([np.zeros(L), eb]))   # 误差放后半，对齐有效输出
        power = np.maximum(smooth * power + (1 - smooth) * np.sum(np.abs(Xr) ** 2, axis=0),
                           1e-9)
        dW = mu * np.conj(Xr) * E / power
        if constrained:
            tmp = np.fft.irfft(dW, M, axis=1)
            tmp[:, L:] = 0.0                                  # 时域约束：清零后半
            dW = np.fft.rfft(tmp, M, axis=1)
        W = W + dW
        xprev = xb
    return e


def erle_curve(d, e, win=1600):
    out = []
    for b in range(len(d) // win):
        sl = slice(b * win, (b + 1) * win)
        out.append(10 * math.log10((np.mean(d[sl] ** 2) + 1e-20)
                                   / (np.mean(e[sl] ** 2) + 1e-20)))
    return np.array(out)


def best_of(x, d, runner, params):
    """扫参，返回（稳态最优的超参, 1s, 5s, 稳态）。"""
    best = None
    for p in params:
        e = runner(p)
        if not np.all(np.isfinite(e)):
            continue
        c = erle_curve(d, e)
        r = (c[0], c[4], float(np.mean(c[-5:])))
        if best is None or r[2] > best[0][2]:
            best = (r, p)
    return best


def section_sim():
    print('=' * 78)
    print('[2] 数值仿真：同一回声路径、同一有色输入，N=2048 @ 16 kHz')
    print('=' * 78)
    NS = FS * 20
    h = make_rir(N, RT60, BULK)
    x = make_input(NS)
    d = np.convolve(x, h)[:NS]
    d /= np.std(d)
    x = x / np.std(x)
    print(f'回声路径 {N} 抽头（{N/FS*1000:.0f} ms），RT60={RT60*1000:.0f} ms，'
          f'体延迟 {BULK} 样本（{BULK/FS*1000:.1f} ms）')
    print(f'输入 20 s 有色噪声（2 极点 r=0.95，谱动态约 26 dB）')
    print()
    print(f"{'算法':<30}{'1s':>8}{'5s':>8}{'20s 稳态':>11}{'附加延迟':>12}")
    print('-' * 70)
    for mu in [0.2, 0.5, 1.0]:
        e = run_nlms(x, d, N, mu)
        c = erle_curve(d, e)
        print(f'{"时域 NLMS mu=" + str(mu):<30}{c[0]:>8.1f}{c[4]:>8.1f}'
              f'{np.mean(c[-5:]):>11.1f}{"1 样本":>12}')
    print()
    for L in [64, 256]:
        for cons in [False, True]:
            tag = '约束' if cons else '无约束'
            b = best_of(x, d, lambda mu, L=L, c=cons: run_pbfdaf(x, d, N, L, mu, c),
                        [0.02, 0.05, 0.1, 0.2, 0.4, 1.0])
            if b is None:
                continue
            (r1, r5, rss), mu = b
            print(f'{f"PBFDAF L={L} {tag} mu={mu}":<30}{r1:>8.1f}{r5:>8.1f}'
                  f'{rss:>11.1f}{f"{delay_samples(L)/FS*1000:.1f} ms":>12}')
        print()
    print('口径提醒：这是我自己写的 PBFDAF，超参按稳态 ERLE 选。测到的初始收敛')
    print('比 NLMS 慢，与教科书"频域对有色输入收敛更快"的说法相反 —— 未查清是')
    print('我的实现调参问题还是该说法只对未归一化的 LMS 成立，按不确定性记录。')
    print()


def main():
    section_cost()
    section_sim()


if __name__ == '__main__':
    main()
