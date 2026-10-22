#!/usr/bin/env python3
"""AEC 定点字长可行性扫描 —— 时域 NLMS, 16 kHz.

回答: 「16-bit 系数 + 32-bit 累加」够不够达到 40~60 dB ERLE?
不靠估算, 直接跑定点仿真, 扫这几个旋钮:
  系数存储位宽 (wbits) / 系数保留的额外低位 (ef_bits)
  误差 e 的位宽 (ebits) / 乘法器输出的累加器位宽 (acc_bits)
并对照 float64 参考, 以及加了扬声器非线性后的物理天花板.

单位约定: 信号用「Q15 的整数 LSB」表示 (满量程 = 32768 = 1.0)。
  系数 w 的数值 = w_store / 2^(15+ef_bits)，乘进乘法器的是 w_store >> ef_bits (Q15)。
  乘积单位 2^-30，y_acc >> 15 回到 Q15 LSB。
"""
import numpy as np

FS = 1 << 15          # Q15 满量程
RUN = np.random.default_rng


def build_path(N, delay=32, seed=0, decay=0.30, erl_db=-9.0):
    """合成房间冲激响应: 纯延迟 + 几个强早期反射 + 指数衰减扩散尾。
    归一化到单位增益 (0 dB ERL), 即 ||h||=1, 这样 w 的典型量级 ~ 1/sqrt(N)。"""
    rng = RUN(seed)
    h = np.zeros(N)
    L = N - delay
    k = np.arange(L)
    h[delay:] = rng.standard_normal(L) * np.exp(-k / (decay * L))
    for pos, g in ((delay + 4, 0.8), (delay + 17, -0.5), (delay + 33, 0.35),
                   (delay + 71, 0.25), (delay + 129, -0.18)):
        if pos < N:
            h[pos] += g
    return h / np.sqrt(np.sum(h ** 2)) * 10 ** (erl_db / 20.0)


def nlms(N=512, Nsamp=30000, tail=8000, mu=0.5, wbits=16, ef_bits=0,
         mul_bits=16, ebits=16, acc_bits=48, mode='fixed',
         x_dbfs=-12.0, erl_db=-9.0, mic_noise_dbfs=-90.0, spk_ceiling_db=None,
         seed=1, delay=32, leak=0.0, norm_mode='exact'):
    """返回 (ERLE_dB, 残余功率轨迹局部均值, stall 比例)"""
    rng = RUN(seed + 1000)
    h = build_path(N, delay=delay, seed=seed, erl_db=erl_db)

    x_rms = 10 ** (x_dbfs / 20.0)
    x_f = rng.standard_normal(Nsamp + N) * x_rms
    if spk_ceiling_db is not None:
        # 扬声器非线性: 数字参考 x 进喇叭后软饱和, 之后的一切都不可被线性滤波器抵消
        sat = 10 ** (spk_ceiling_db / 20.0)
        x_spk = sat * np.tanh(x_f / sat)
    else:
        x_spk = x_f
    if spk_ceiling_db is not None:
        # 线性滤波器能拿到的最好结果: x_spk 对 x_f 的最小二乘拟合, 残差就是硬天花板
        g = float(np.dot(x_spk, x_f) / np.dot(x_f, x_f))
        nl = x_spk - g * x_f
        nl_ceiling = 10 * np.log10(np.sum(x_spk ** 2) / np.sum(nl ** 2))
    else:
        nl_ceiling = np.inf
    d_f = np.convolve(x_spk, h)[:Nsamp]                     # 回声
    d_f = d_f + rng.standard_normal(Nsamp) * 10 ** (mic_noise_dbfs / 20.0)

    # 远端的数字信号(参考)与麦克风采到的回声 -> 各自量化到 16-bit ADC
    x_q = np.clip(np.rint(x_f * FS), -FS, FS - 1)
    d_q = np.clip(np.rint(d_f * FS), -FS, FS - 1)

    if mode == 'float':
        w = np.zeros(N)
        xbuf = np.zeros(N)
        err2 = np.zeros(Nsamp)
        for n in range(Nsamp):
            xbuf[1:] = xbuf[:-1]
            xbuf[0] = x_q[n] / FS
            y = float(np.dot(w, xbuf))
            e = d_q[n] / FS - y
            err2[n] = e * e
            nrm = float(np.dot(xbuf, xbuf)) + 1e-12
            w += mu * e * xbuf / nrm
        d2 = (d_q / FS) ** 2
        return 10 * np.log10(np.sum(d2[-tail:]) / np.sum(err2[-tail:])), nl_ceiling, 0.0

    store_frac = 15 + ef_bits
    drop = max(0, ef_bits - (mul_bits - 16))       # 乘进乘法器前丢掉的低位
    w_frac = store_frac - drop                     # 乘法器看到的系数的小数位
    if mul_bits > 16 and acc_bits == 48:
        acc_bits = 64                              # 宽系数模式不做累加器饱和
    w_store = np.zeros(N, dtype=np.int64)          # 系数存储 (Q{15+ef_bits})
    xbuf = np.zeros(N, dtype=np.int64)             # 延迟线 (Q15 LSB)
    err2 = np.zeros(Nsamp)
    n_stall = 0
    n_upd = 0
    lo = -(1 << (wbits - 1))
    hi = (1 << (wbits - 1)) - 1
    for n in range(Nsamp):
        xbuf[1:] = xbuf[:-1]
        xbuf[0] = x_q[n]
        w_mul = (w_store >> drop) if drop else w_store
        y_acc = int(np.dot(w_mul, xbuf))           # Q(w_frac+15)
        # 累加器位宽: 越界即饱和(模拟加法树/累加器溢出)
        lim = (1 << (acc_bits - 1)) - 1
        if y_acc > lim or y_acc < -lim - 1:
            y_acc = lim if y_acc > 0 else -lim - 1
        y = y_acc >> w_frac                        # 回到 Q15 LSB
        e = int(d_q[n]) - y
        elim = (1 << (ebits - 1)) - 1
        if e > elim:
            e = elim
        elif e < -elim - 1:
            e = -elim - 1
        err2[n] = float(e) ** 2
        nrm = float(np.dot(xbuf, xbuf)) + 1e-9     # Q30 of LSB^2
        if norm_mode == 'pow2':
            # 硬件实现: ||x||^2 取最近的 2 的幂, 归一化变成移位, 不需要除法器
            sh = int(np.floor(np.log2(nrm) + 0.5))
            nrm = float(1 << max(sh, 0))
        if nrm > 0:
            delta = mu * e * xbuf / nrm * (1 << store_frac)   # 系数存储的最低位数
            di = np.rint(delta).astype(np.int64)
            n_stall += int(np.count_nonzero(di == 0)) if ef_bits == 0 else 0
            n_upd += N if ef_bits == 0 else 0
            w_store = np.clip(w_store + di, lo, hi)
            if leak:
                w_store -= np.rint(w_store * leak).astype(np.int64)

    d2 = (d_q.astype(np.float64)) ** 2
    erle = 10 * np.log10(np.sum(d2[-tail:]) / np.sum(err2[-tail:]))
    stall = (n_stall / n_upd) if n_upd else float('nan')
    return erle, nl_ceiling, stall


def cfg(name, **kw):
    e, nl, s = nlms(**kw)
    extra = f"   [线性可消上限 {nl:5.1f} dB]" if np.isfinite(nl) else ""
    print(f"  {name:<46s} ERLE = {e:6.2f} dB   stall={s*100:5.2f}%{extra}")
    return e


def level_plan(N=512, Nsamp=20000, x_dbfs=-12.0, erl_db=-9.0, seed=1):
    """打印电平预算, 确认没有 ADC 削波 (削波会伪造出很低的 ERLE 天花板)"""
    rng = RUN(seed + 1000)
    h = build_path(N, seed=seed, erl_db=erl_db)
    x = rng.standard_normal(Nsamp + N) * 10 ** (x_dbfs / 20.0)
    d = np.convolve(x, h)[:Nsamp]
    pk = np.abs(d).max()
    print(f"  远端 x  = {x_dbfs:+.1f} dBFS rms")
    print(f"  路径 ERL= {erl_db:+.1f} dB (||h||)")
    print(f"  回声 d  = {20*np.log10(d.std()):+.1f} dBFS rms, 峰值 {20*np.log10(pk):+.1f} dBFS"
          f"  -> ADC 削波: {'是 (仿真无效)' if pk > 1.0 else '否'}")
    print(f"  系数 |w| 最大 = {np.abs(h).max():.4f} (= {20*np.log10(np.abs(h).max()):+.1f} dBFS)")


if __name__ == '__main__':
    import sys
    N = 512
    print(f"=== AEC 定点字长扫描: N={N} taps, 16 kHz, ===")
    level_plan(N=N)
    print("--- 0) 算法/物理上限 ---")
    cfg("float64 NLMS (无量化 无噪声)", mode='float', N=N, mic_noise_dbfs=-120)
    print("--- 1) 纯 16-bit: 系数16 / e16 / 累加48 ---")
    cfg("w16 e16 acc48 mul16", N=N, wbits=16, ef_bits=0, mul_bits=16)
    print("--- 2) 系数多留低位(乘法器仍16-bit) ---")
    cfg("w16+ef4 (20-bit 存储)", N=N, wbits=20, ef_bits=4, mul_bits=16)
    cfg("w16+ef8 (24-bit 存储)", N=N, wbits=24, ef_bits=8, mul_bits=16)
    print("--- 3) e 的位宽 ---")
    cfg("w16 e12 acc48", N=N, wbits=16, ef_bits=0, ebits=12)
    cfg("w16 e10 acc48", N=N, wbits=16, ef_bits=0, ebits=10)
    print("--- 4) 累加器位宽 ---")
    for ab in (32, 28, 24, 21, 20):
        cfg(f"w16 e16 acc{ab}", N=N, wbits=16, ef_bits=0, acc_bits=ab)
    print("--- 5) 32-bit 系数 (32x16 乘法器, 2 个 DSP48E1/lane) ---")
    cfg("w32 e16 mul32", N=N, wbits=32, ef_bits=16, mul_bits=32)
    print("--- 6) 物理天花板: 扬声器非线性 (线性滤波器无解) ---")
    for s in (6, 3, 0, -3, -6, -10, -16):
        cfg(f"float64 + 喇叭软拐点 {s:+d} dBFS", mode='float', N=N, spk_ceiling_db=s)
    print("--- 7) 步长 mu 的影响 (w16, 纯定点) ---")
    for mu in (0.05, 0.2, 0.5, 1.0):
        cfg(f"w16 mu={mu}", N=N, mu=mu, wbits=16, ef_bits=0)
    print("--- 8) 回声电平低 20 dB 时 (系数变小 -> 定点相对误差变大) ---")
    cfg("w16 e16 acc48, x=-12 ERL=-29", N=N, wbits=16, ef_bits=0, erl_db=-29.0)
    cfg("w16+ef8,         x=-12 ERL=-29", N=N, wbits=24, ef_bits=8, erl_db=-29.0)
    print("--- 9) N=2048 (更长滤波器) ---")
    for nm, kw in (("w16 e16 acc48", dict(wbits=16, ef_bits=0)),
                   ("w16+ef8", dict(wbits=24, ef_bits=8)),
                   ("w32 e16 mul32", dict(wbits=32, ef_bits=16, mul_bits=32))):
        cfg(f"N=2048 {nm}", N=2048, Nsamp=60000, tail=15000, **kw)
