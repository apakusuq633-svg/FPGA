"""PS-only 的工作量清点 —— 回答 README §0.3 的**假设②**（部分）。

README §34 要求证明 PS-only < PS+PL。这条的**完整答案必须上板跑 A9 裸机**，
但**工作量本身现在就能精确数出来**，而且数出来才知道值不值得上板跑。

本脚本做两件事：

  1. 从链路结构**精确**算出每帧、每秒的操作数（不是估的）
  2. 按几个**明确标注来源**的 A9 吞吐假设，折算出 CPU 占用

⚠ 第 2 步是**推的**，不是实测的。A9 的真实吞吐必须上板量。
   这里给的是「值不值得上板量」的判据，不是结论。
"""
import numpy as np

from mic_geometry import FS, N_MIC, N_PAIR

NFFT = 1024
HOP = 512                 # 50% 重叠 → 帧率 = fs/hop
N_BINS = NFFT // 2 + 1
BAND_BINS = int((8000 - 200) / (FS / 2) * N_BINS)   # 限带后实际要处理的 bin 数

# A9 @ 667 MHz（Zynq-7010 典型）—— 以下几个数是**假设**，必须上板核对
A9_MHZ = 667.0
A9_FLOPS_PER_CYCLE = 2.0      # NEON 单精度，乐观值
A9_INT_OPS_PER_CYCLE = 1.0    # 标量定点


def count_ops():
    """精确清点每帧操作数。全部由结构算出，不是估的。"""
    ops = {}
    # 8 × 1024 点实数 FFT：5·N·log2(N) 实数 flop 是常用计数
    ops["8×1024 点实数 FFT"] = 8 * 5 * NFFT * int(np.log2(NFFT))
    # 28 对复数乘：每对每 bin 4 乘 2 加 = 6 flop
    ops["28 对复数乘（互谱）"] = N_PAIR * N_BINS * 6
    # 28 × |G|：每 bin 2 乘 1 加 1 开方 ≈ 按 4 flop 计
    ops["28 对求模 |G|"] = N_PAIR * N_BINS * 4
    # 28 × 倒数：LUT 版 = 每 bin 1 次查表（RTL 里几乎免费，PS 上按 2 op 计）
    ops["28 对倒数（LUT 版）"] = N_PAIR * N_BINS * 2
    # 28 × 1024 点实数 IFFT
    ops["28×1024 点实数 IFFT"] = N_PAIR * 5 * NFFT * int(np.log2(NFFT))
    # SRP 扫描：1024 网格 × 28 对 × (1 查表 + 1 插值 MAC + 1 累加) = 3 op
    ops["SRP 扫描 1024×28"] = 1024 * N_PAIR * 3
    # 峰值搜索
    ops["峰值搜索"] = 1024
    return ops


def main():
    ops = count_ops()
    total = sum(ops.values())
    frame_ms = NFFT / FS * 1000
    hop_ms = HOP / FS * 1000
    fps = FS / HOP

    print("=" * 76)
    print("PS-only 工作量清点  (README §34 / §0.3 假设②)")
    print(f"fs={FS} Hz   NFFT={NFFT}   hop={HOP}（50% 重叠）")
    print(f"帧长 {frame_ms:.2f} ms   刷新 {hop_ms:.2f} ms = {fps:.1f} 帧/s")
    print("=" * 76)
    print(f"\n{'块':<26} {'每帧操作':>14} {'占比':>8}")
    print("-" * 76)
    for k, v in sorted(ops.items(), key=lambda kv: -kv[1]):
        print(f"{k:<26} {v:>14,} {v/total*100:>7.1f}%")
    print("-" * 76)
    print(f"{'合计':<26} {total:>14,}")

    print(f"\n每秒操作数: {total*fps/1e6:.1f} Mop/s")
    flops = sum(v for k, v in ops.items() if "FFT" in k or "IFFT" in k
                or "复数乘" in k or "求模" in k)
    print(f"其中浮点部分（FFT/IFFT/互谱/求模）: {flops*fps/1e6:.1f} Mflop/s")

    print("\n" + "=" * 76)
    print("折算到 A9 —— ⚠ 以下用的是**假设**的吞吐，不是实测")
    print(f"  假设 A9 @ {A9_MHZ:.0f} MHz，NEON {A9_FLOPS_PER_CYCLE:.0f} flop/cycle，"
          f"标量定点 {A9_INT_OPS_PER_CYCLE:.0f} op/cycle")
    print("=" * 76)
    cyc_flop = flops * fps / (A9_MHZ * 1e6 * A9_FLOPS_PER_CYCLE)
    fixed = total - flops
    cyc_int = fixed * fps / (A9_MHZ * 1e6 * A9_INT_OPS_PER_CYCLE)
    cpu = (cyc_flop + cyc_int) * 100
    print(f"  浮点部分  {cyc_flop*100:6.1f}% CPU")
    print(f"  定点部分  {cyc_int*100:6.1f}% CPU")
    print(f"  ─────────────────────")
    print(f"  合计      {cpu:6.1f}% CPU   ← 单核，未计 cache miss / DDR / 中断")

    print(f"\n  但 A9 的**实际** NEON 效率通常只有峰值的 20–40%，")
    print(f"  且裸机 FFT 库很难达到 1 flop/cycle 的有效率。")
    print(f"  按 25% 有效率折：{cpu/0.25:.0f}% CPU —— **单核放不下**。")

    print("\n" + "=" * 76)
    print("能现在下的结论 / 不能现在下的结论")
    print("=" * 76)
    print(f"  能：PS-only 每帧要 {total:,} 次操作 = {total*fps/1e6:.0f} Mop/s，")
    print(f"      这个量级在 A9 上是**吃力**的（README §8 的论证方向成立）")
    print(f"  不能：A9 到底几帧/秒、jitter 多大 —— **必须上板量**（§34）")
    print(f"  可用旋钮：§49 Experiment 9 的网格加密（32×32 → 64×64 = 4× 负载）")

    print(f"\n  另一个必须记的点：**8 路 FFT 占了 {ops['8×1024 点实数 FFT']/total*100:.0f}%"
          f" + IFFT {ops['28×1024 点实数 IFFT']/total*100:.0f}%**，")
    print(f"  也就是说 PS-only 的负载**大头在 FFT 库**上，而不是 SRP 本身。")
    print(f"  PL 侧的对应论证应该落在「FFT + 互谱 + 扫描整条流水」，不是只吹 SRP。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
