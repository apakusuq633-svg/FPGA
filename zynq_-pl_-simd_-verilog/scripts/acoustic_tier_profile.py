#!/usr/bin/env python3
# 声学检测（振动/异响）三级分工的算力账：PL / A9#1 / A9#0。
# 只做算术，不跑信号处理。数字逐条标来源：
#   [M] 本仓库/前序实测   [D] ARM/Xilinx 文档规格   [R] 用户设计报告   [E] 估算
#
# 与本目录其它脚本的分工：
#   ps_a9_scalar_model.py —— 单核标量路径的拍数/吞吐
#   mpc_feasibility.py    —— 控制那一轴需要多大算力
#   本脚本                 —— 声学检测那一轴的三级算力账

import math

# ---- 实测锚点 [M] ----------------------------------------------------------
A9_F = 666.666666e6        # [M] scripts/ps7_config.tcl:18 APU 主频
PL_F = 40e6                # [M] README「时序与 FCLK 频率」FCLK_CLK0
A9_NEON_MMAC = 394.5       # [M] 单核 NEON NLMS 两趟实测 3.38 拍/tap
A9_SCALAR_MMAC = 143.7     # [M] 单核标量 9.28 拍/tap
PL_SCALAR_MMAC = 3.77      # [M] PL 核 21.22 拍/tap @40MHz
PL_ARRAY_PEAK = 1280.0     # [M]/[E] 32 lane @40MHz，0 行 RTL
A9_JITTER_CYC = 595        # [M] 实测抖动 spread 上界
A9_IRQ_ENTRY_US = 5.99     # [M] 第三方实测最坏中断入口

NEON_FLOPS = A9_NEON_MMAC * 2 * 1e6    # 1 MAC = 2 FLOP 口径，394.5 MMAC/s → 789 MFLOP/s
A9_CYC_PER_FLOAT = A9_F / NEON_FLOPS   # NEON 实测口径下每 FLOP 拍数 = 0.845


A9_NEON_MMAC_S = A9_NEON_MMAC * 1e6          # MAC/s


def us_of(flop):
    """每帧 flop → 单帧秒数，换算成 us"""
    return flop / NEON_FLOPS * 1e6


def duty_of(flop, fps):
    """单核占用 %：每帧耗时 × 帧率"""
    return us_of(flop) * 1e-6 * fps * 100


def ms_of(mac):
    """一次推理的 MAC 数 → ms"""
    return mac / A9_NEON_MMAC_S * 1000


def mk(flop, fps, name):
    """返回 (名字, 每帧 flop, MFLOP/s, us/帧, 单核占用%)"""
    return name, flop, flop * fps / 1e6, us_of(flop), duty_of(flop, fps)


# ═══ 1. FFT ═════════════════════════════════════════════════════════════════
print("=" * 92)
print("[1] FFT / STFT")
print("=" * 92)
N = 1024
BF = N // 2 * int(math.log2(N))                       # radix-2 蝶形数
FLOP_R2 = BF * (4 + 6)                                # 复乘 4mul+2add，两个复加 4add
FLOP_REAL = FLOP_R2 / 2                               # 实输入 FFT ≈ 复数的一半
print("  N = %d  radix-2 蝶形数 = (N/2)log2N = %d" % (N, BF))
print("    每个蝶形 4 实乘 + 6 实加 = 10 FLOP  → 复数 FFT %6d FLOP  [E]")
print("    实输入 rfft ≈ 一半                    → 实 FFT   %6d FLOP  [E]" % FLOP_REAL)
print("    文献常用口径 5*N*log2N = %d（复数）、2.5*N*log2N = %d（实数）" %
      (5 * N * int(math.log2(N)), 5 * N * int(math.log2(N)) // 2))
print()

CASES = [("报告 §5：48 kHz / hop 512", 48000, 512),
         ("任务口径：16 kHz / hop 256", 16000, 256),
         ("下采样到 16 kHz / hop 128", 16000, 128)]
print("  %-30s %8s %10s %10s %10s %10s" %
      ("场景", "帧率/s", "复FFT", "实FFT", "实FFT us/帧", "占单核"))
fft_rows = []
for name, fs, hop in CASES:
    fps = fs / hop
    _, f, mfl, us, duty = mk(FLOP_REAL, fps, name)
    print("  %-30s %8.2f %8.2f %8.2f %10.2f %9.3f%%" %
          (name, fps, f * fps / 1e6, mfl, us, duty))
    fft_rows.append((name, fps))
print("  外部锚点（换到 666.67 MHz 口径）：")
for tag, cyc, note in (("Xilinx 论文 定点 Q[12,20] 实数 FFT（800MHz 实测 34.15us）", None, "定点"),
                       ("AC6 培训 单精度复数 FFT 汇编", 106000, "float"),
                       ("DSP Concepts 表 单精度复数 FFT", 45157, "float")):
    if cyc is None:
        print("    %-52s → %6.2f us @666MHz  [D] 第三方实测" % (tag, 34.15 * 800 / 666.67))
    else:
        print("    %-52s → %6.2f us @666MHz  [D] 第三方" % (tag, cyc / A9_F * 1e6))
print("    → 本脚本反推的 32.45 us 下界和第三方定点实测 40.98 us 同量级，说明口径没跑偏。")
print("      取 41~68 us 作为现实区间；即使取最差的 float 159 us，占单核也仅 1.5%。")
print()

# ═══ 2. DSP 特征 ════════════════════════════════════════════════════════════
print("=" * 92)
print("[2] DSP 特征（报告 §7 全表，N=1024）")
print("=" * 92)
items = []
items.append(("DC 去除 + 窗（Hann）", 2 * N + N))
items.append(("RMS / Variance（和 + 平方和共用）", 2 * N + 2))
items.append(("Peak / P2P（比较）", 2 * N))
items.append(("Kurtosis（四次矩）", 4 * N))
items.append(("功率谱 P=|X|^2，512 bin", 512 * 3))
items.append(("Spectral Energy + Band Energy", 512 + 512))
items.append(("Spectral Centroid（加权和/归一）", 512 * 3))
items.append(("Spectral Peak（argmax）", 512))
tot = 0
print("  %-38s %10s" % ("环节", "FLOP/帧"))
for nm, fl in items:
    tot += fl
    print("  %-38s %10d" % (nm, fl))
print("  %-38s %10d" % ("小计", tot))
print()
for name, fs, hop in CASES:
    fps = fs / hop
    _, f, mfl, us, duty = mk(tot, fps, name)
    print("  %-30s 帧率 %6.2f/s → %6.3f MFLOP/s  %6.2f us/帧  占单核 %5.3f%%"
          % (name, fps, mfl, us, duty))
print()

# 前端 FIR 才是这一支真正的大头
print("  前端带通 FIR（每样本都得算，不是每帧）：")
for fs, taps in ((48000, 64), (48000, 128), (16000, 64), (16000, 128)):
    mmac = fs * taps / 1e6
    print("    %5d Hz × %3d tap = %6.3f MMAC/s  → PS 单核 NEON %5.2f%%  PL 标量核 %6.1f%%  PL阵列(50%%) %5.2f%%"
          % (fs, taps, mmac, mmac / A9_NEON_MMAC * 100,
             mmac / PL_SCALAR_MMAC * 100, mmac / (PL_ARRAY_PEAK / 2) * 100))
print()

# ═══ 3. INT8 CNN ════════════════════════════════════════════════════════════
print("=" * 92)
print("[3] INT8 CNN（报告 §9 结构：Conv3x3 → DW3x3 → PW1x1 → GAP → FC）")
print("=" * 92)


def cnn(in_hw, chans, fc_out, tag):
    """chans: [(kind, cin, cout)]；返回 MAC/次"""
    mac = 0
    hw = in_hw
    for kind, cin, cout in chans:
        if kind == 'conv':
            mac += hw * hw * cout * cin * 9
        elif kind == 'dw':
            mac += hw * hw * cin * 9
        elif kind == 'pw':
            mac += hw * hw * cout * cin
        elif kind == 'pool':
            hw = hw // 2
    mac += hw * hw * chans[-1][2]      # GAP 累加
    mac += chans[-1][2] * fc_out       # FC
    return mac, hw


A = [('conv', 1, 8), ('dw', 8, 8), ('pw', 8, 16)]
B = [('conv', 1, 16), ('dw', 16, 16), ('pw', 16, 32), ('pool', 32, 32),
     ('dw', 32, 32), ('pw', 32, 32)]
for tag, chans, fc in (("A 最小版 64x64x1→8→8dw→16pw→FC/1", A, 1),
                       ("B 分类版 64x64x1→16→16dw→32pw→pool→32dw→32pw→FC/5", B, 5)):
    mac, hw = cnn(64, chans, fc, tag)
    print("  %-56s %9.0f MAC/次" % (tag, mac))
    for name, fs, hop in CASES:
        fps = fs / hop
        mmac = mac * fps / 1e6
        print("      %-28s 帧率 %6.2f/s → %7.1f MMAC/s  单核 %6.1f%%  单次 %6.2f ms  帧周期 %5.2f ms"
              % (name, fps, mmac, mmac / A9_NEON_MMAC * 100, ms_of(mac), hop / fs * 1000))
    print()

# ═══ 4. 汇总 ════════════════════════════════════════════════════════════════
print("=" * 92)
print("[4] A9#1 一核占用汇总（报告口径 48 kHz / hop 512，帧周期 10.67 ms）")
print("=" * 92)
fps = 48000 / 512
MAC_A = cnn(64, A, 1, '')[0]
MAC_B = cnn(64, B, 5, '')[0]
row = [("FFT 1024 实（下界）", duty_of(FLOP_REAL, fps)),
       ("FFT 1024 实（×3 现实）", duty_of(3 * FLOP_REAL, fps)),
       ("DSP 特征全表", duty_of(tot, fps)),
       ("前端 FIR 64tap@48k（连续）", 48000 * 64 / A9_NEON_MMAC_S * 100),
       ("CNN A 最小版", MAC_A * fps / A9_NEON_MMAC_S * 100),
       ("CNN B 分类版", MAC_B * fps / A9_NEON_MMAC_S * 100)]
for nm, d in row:
    print("  %-30s %7.2f%% 单核" % (nm, d))
print()
print("  组合 1（CNN=A）：%.2f%% 单核" % sum(d for n, d in row if 'CNN B' not in n))
print("  组合 2（CNN=B）：%.2f%% 单核  ← 已经放不进一个核"
      % sum(d for n, d in row if 'CNN A' not in n))
print()
print("  同一笔账按任务口径 16 kHz / hop 256（帧周期 16.0 ms）：")
fps16 = 16000 / 256
row16 = [("FFT ×1", duty_of(FLOP_REAL, fps16)), ("FFT ×3", duty_of(3 * FLOP_REAL, fps16)),
         ("DSP 特征", duty_of(tot, fps16)), ("FIR 64tap@16k", 16000 * 64 / A9_NEON_MMAC_S * 100),
         ("CNN A", MAC_A * fps16 / A9_NEON_MMAC_S * 100),
         ("CNN B", MAC_B * fps16 / A9_NEON_MMAC_S * 100)]
for nm, d in row16:
    print("    %-14s %7.2f%% 单核" % (nm, d))
print("    组合 A %.2f%%   组合 B %.2f%%"
      % (sum(d for n, d in row16 if 'CNN B' not in n), sum(d for n, d in row16 if 'CNN A' not in n)))
print()
print("  [5] 关键量级对比：")
print("      A9 抖动实测上界 %d 拍 = %.3f us" % (A9_JITTER_CYC, A9_JITTER_CYC / A9_F * 1e6))
print("      帧周期 10.67 ms = %d 拍 → 抖动占期限 %.5f%%"
      % (10.67e-3 * A9_F, A9_JITTER_CYC / (10.67e-3 * A9_F) * 100))
print("      A9 最坏中断入口 %.2f us（第三方实测）占期限 %.4f%%"
      % (A9_IRQ_ENTRY_US, A9_IRQ_ENTRY_US / 10670 * 100))
print("      → 抖动比帧期限小 4 个数量级，帧级流水里「抖动」不是分核的理由")
print()
print("  [6] PL 侧真正的逐样本闭环（这一支才是 Pl 的存在理由）：")
for n_tap, fs in ((64, 16000), (128, 16000), (64, 48000)):
    cyc = n_tap * 21.22
    t_us = cyc / PL_F * 1e6
    period = 1 / fs * 1e6
    print("      双麦 AEC/NLMS N=%3d @%5d Hz：%5.0f 拍 = %6.2f us / 样本周期 %5.2f us → PL 标量核 %5.1f%%"
          % (n_tap, fs, cyc, t_us, period, t_us / period * 100))
print("      → N=64@16k 已吃掉 PL 标量核一半；这就是「不能丢的那一段」在 PL 上，不在 A9#1。")
print()
print("  [7] 长期趋势/统计（A9#0 侧）：")
for feats in (16, 32):
    bps = feats * 4 * fps
    print("      每帧存 %2d 个 float 特征 → %6.1f B/s；每分钟 %5.1f KB" % (feats, bps, bps * 60 / 1024))
print("      SQLite/环形缓冲写 SD 的写入带宽需求 << 10 KB/s，任何 Linux 核都无压力")
