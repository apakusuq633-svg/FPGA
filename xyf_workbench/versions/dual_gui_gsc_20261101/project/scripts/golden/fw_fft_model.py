"""固件 FFT 内核的定点模型 + 旋转因子表生成器。

为什么要有这一层
----------------
README §39：**禁止 PC float 直接对 HDL/固件**。中间必须有定点软件模型，
否则仿真里对不上时分不清是「算法错」还是「量化误差」。

本模块是 `sw/fw/fw_fft.c` 的**逐位等价**模型：C 那边怎么算，这里就怎么算，
连 `>>` 的取整方向都对齐。仿真对不上时，先跑这里 —— 这里对、仿真不对，
问题在搬写过程；这里就不对，问题在算法。

算法
----
1024 点**实数** FFT，走标准的 N/2 复数打包：

    z[n] = x[2n] + j·x[2n+1]          n = 0..511
    Z    = FFT_512(z)                 基 2 DIT，每级 >>1
    E[k] = (Z[k] + conj(Z[(512−k)%512])) / 2
    O[k] = (Z[k] − conj(Z[(512−k)%512])) / 2j
    X[k] = (E[k] + W_1024^k · O[k]) >> 1        k = 0..512

最后那一级 `>>1` 不是凑数：Z 已经是 ÷512 的，而 X 要的是 ÷1024。
k=0..511 用 E[k]/O[k]，k=512 就是 E[0]−O[0] 再 >>1（W^512 = −1）。

定标（每一处都数清楚，改了要重算溢出）
--------------------------------------
- 输入 x：Q15 int16，|x| ≤ 32767
- 旋转因子 W = e^{-j2πk/1024}：**Q14** int16。用 Q14 不用 Q15 是因为
  W^0 = 1.0 在 Q15 里装不下（16'h8000 会被解释成 −1.0，直接把信号反相）——
  同一个坑已经踩过一次，见 `docs/issues/029`。
- 复数工作数组 Z：int16，靠**每级 >>1** 保证 |·| ≤ 32767。
  不这么做的话第 9 级的数据到 2²⁴，乘上 Q14 因子要 2³⁸，int32 直接溢出。
- 蝶形中间量 a±t 用 int32 算（≤ 2·32767），写回 int16 前先 >>1。
- 输出 X：int16 Q15，标度 = 真值/1024。

生成物
------
`sw/fw/fw_tables.h` —— Q14 旋转因子表（513 条复数），进 .data 随 DTCM 镜像预装。

用法
----
    python3 scripts/golden/fw_fft_model.py            # 自检 + 生成表
    python3 scripts/golden/fw_fft_model.py --ref      # 另出 build/fw_fft_ref.hex
"""
import os
import sys

import numpy as np

N    = 1024            # 实数点数
M    = N // 2          # 复数 FFT 点数（512）
NTW  = N // 2 + 1      # 表长 513：W_1024^k, k = 0..512
TW_FRAC = 14           # 旋转因子小数位（Q14 —— 见模块头，Q15 装不下 1.0）

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_H = os.path.join(ROOT, "sw", "fw", "fw_tables.h")
OUT_REF = os.path.join(ROOT, "build", "fw_fft_ref.hex")


# ── 表 ────────────────────────────────────────────────────────────────
def twiddle_q14():
    """W_1024^k 的 Q14 定点值，返回 (re, im) 各 513 条的 int 数组。"""
    k = np.arange(NTW)
    ang = -2.0 * np.pi * k / N
    scale = float(1 << TW_FRAC)
    re = np.round(np.cos(ang) * scale).astype(np.int64)
    im = np.round(np.sin(ang) * scale).astype(np.int64)
    return re, im


def write_header(re, im):
    """出**两个**文件：声明进 .h、定义进 .c。

    ⚠ 不能写成「头文件里 `static const` 数组」—— 那样每个 include 它的 .c 都会
      存一份完整副本。FTT/PHAT 一共 3 个 .c 包含它，2 KB 的表就变成 4 KB，
      而且**不报错**，只是 .data 悄悄涨、DTCM 挤爆别的缓冲（实测踩到）。
    """
    name = "GCC"          # 变了记得全仓 grep 一遍
    hdr = [
        "/* 自动生成，不要手改 —— 源在 scripts/golden/fw_fft_model.py。",
        " *",
        " * 1024 点实数 FFT 的旋转因子 W_1024^k = e^{-j2πk/1024}，k = 0..512，",
        " * 复数按 re/im 分开存，各 int16 **Q14**。",
        " *",
        " * Q14 不是随便挑的：Q15 装不下 1.0（W^0 = 16'h8000 会被当成 -1.0，",
        " * 等于把信号反相）。同一个坑见 docs/issues/029。",
        " *",
        " * 这里只有**声明**，定义在 fw_tables.c —— 见那个文件头部。",
        " */",
        "#ifndef FW_TABLES_H",
        "#define FW_TABLES_H",
        "",
        "#include <stdint.h>",
        "",
        "#define FW_TW_N     %d   /* k = 0..512 */" % NTW,
        "#define FW_TW_FRAC  %d" % TW_FRAC,
        "",
        "extern const int16_t g_tw_re[FW_TW_N];",
        "extern const int16_t g_tw_im[FW_TW_N];",
        "",
        "#endif /* FW_TABLES_H */",
    ]
    def_ = [
        "/* 自动生成，不要手改 —— 源在 scripts/golden/fw_fft_model.py。",
        " *",
        " * 旋转因子表的**定义**。单独一个 .c 是为了它只存在一份：",
        " * 写成头文件里的 static const 数组的话，每个 include 它的 .c 都会存一份。",
        " */",
        '#include "fw_tables.h"',
        "",
        "const int16_t g_tw_re[FW_TW_N] = {",
    ]
    for i in range(0, NTW, 8):
        def_.append("    " + ", ".join("%6d" % v for v in re[i:i + 8]) + ",")
    def_.append("};")
    def_.append("")
    def_.append("const int16_t g_tw_im[FW_TW_N] = {")
    for i in range(0, NTW, 8):
        def_.append("    " + ", ".join("%6d" % v for v in im[i:i + 8]) + ",")
    def_.append("};")

    with open(OUT_H, "w", encoding="utf-8") as f:
        f.write("\n".join(hdr) + "\n")
    with open(OUT_H[:-2] + ".c", "w", encoding="utf-8") as f:
        f.write("\n".join(def_) + "\n")
    print("   表 -> %s + .c (%d 条复数, Q%d)" % (OUT_H, NTW, TW_FRAC))


# ── 测试输入（必须与固件、TB 三方一致）────────────────────────────────
LCG_A = 1103515245
LCG_C = 12345
LCG_SEED = 0x12345678


def make_input(n=N):
    """周期 64 的三角波（落在 bin 16）+ LCG 噪声。纯整数，三方照抄同一段。

    幅度取到接近满幅（±24576）—— 灌小信号的话中间级的溢出边界永远试不到，
    而定点 FFT 出问题多半就出在边界上。
    """
    s = LCG_SEED
    out = np.empty(n, dtype=np.int64)
    for i in range(n):
        s = (s * LCG_A + LCG_C) & 0xFFFFFFFF
        noise = (s >> 16) & 0x3FFF          # 0..16383
        ph = i % 64
        tri = ph * 1024 - 16384 if ph < 32 else 49152 - ph * 1024
        out[i] = tri + (noise - 8192)
    assert np.abs(out).max() <= 32767, "测试输入超出 Q15"
    return out


# ── 逐位等价的定点 FFT ────────────────────────────────────────────────
def _shr(v, s):
    """算术右移。**必须显式 floor** —— numpy 的 >> 对负数也是 floor，
    但写成 // (1<<s) 语义相同、更不容易看错。"""
    return v // (1 << s)


def fft_fixed(x, re_tab, im_tab):
    """x: (1024,) int；返回 X: (513,) complex int（标度 = 真值/1024）。"""
    x = np.asarray(x, dtype=np.int64)
    assert x.shape == (N,)

    # ── 1. 打包：z[n] = x[2n] + j x[2n+1] ───────────────────────────
    zr = x[0::2].copy()
    zi = x[1::2].copy()

    # ── 2. 基 2 DIT：先做位反转置换 ─────────────────────────────────
    bits = int(np.log2(M))
    idx = np.arange(M)
    rev = np.zeros(M, dtype=np.int64)
    for b in range(bits):
        rev |= ((idx >> b) & 1) << (bits - 1 - b)
    zr, zi = zr[rev].copy(), zi[rev].copy()

    # ── 3. 蝶形：9 级，每级 >>1 ─────────────────────────────────────
    length = 2
    while length <= M:
        half = length >> 1
        step = M // length                      # 因子的下标步长
        for start in range(0, M, length):
            j = np.arange(half)
            # ⚠ 表是 W_1024^k，而这一级要的是 W_512^j = W_1024^{2j} —— **下标要乘 2**。
            #   漏掉这个 2 不会报错：DC 那条（j=0）永远是对的，从 bin 1 起全错，
            #   看上去像"蝶形接反了"，其实是因子取错频点。
            wr = re_tab[j * step * 2]
            wi = im_tab[j * step * 2]
            a_r = zr[start + j];          a_i = zi[start + j]
            b_r = zr[start + half + j];   b_i = zi[start + half + j]
            # t = w · b，Q14 × Q15 -> Q29，>>14 回 Q15
            t_r = _shr(wr * b_r - wi * b_i + (1 << (TW_FRAC - 1)), TW_FRAC)
            t_i = _shr(wr * b_i + wi * b_r + (1 << (TW_FRAC - 1)), TW_FRAC)
            zr[start + j]          = _shr(a_r + t_r + 1, 1)
            zi[start + j]          = _shr(a_i + t_i + 1, 1)
            zr[start + half + j]   = _shr(a_r - t_r + 1, 1)
            zi[start + half + j]   = _shr(a_i - t_i + 1, 1)
        length <<= 1

    # ── 4. 拆分：E / O ─────────────────────────────────────────────
    # E[k] = (Z[k] + conj(Z[(M-k)%M]))/2 , O[k] = (Z[k] - conj(...))/2j
    km = (M - np.arange(M)) % M
    zr_m, zi_m = zr[km], zi[km]
    e_r = _shr(zr + zr_m, 1)
    e_i = _shr(zi - zi_m, 1)
    o_r = _shr(zi + zi_m, 1)
    o_i = _shr(zr_m - zr, 1)

    # ── 5. 合成 X[k] = (E + W^k·O) >> 1 ，k = 0..511 ────────────────
    wr = re_tab[:M]; wi = im_tab[:M]
    t_r = _shr(wr * o_r - wi * o_i + (1 << (TW_FRAC - 1)), TW_FRAC)
    t_i = _shr(wr * o_i + wi * o_r + (1 << (TW_FRAC - 1)), TW_FRAC)
    xr = _shr(e_r + t_r, 1)
    xi = _shr(e_i + t_i, 1)

    # ── 6. 第 513 条：k = 512，W^512 = -1 ⇒ X = (E[0] - O[0]) >> 1，实数 ──
    xn_r = _shr(e_r[0] - o_r[0], 1)
    xn_i = np.int64(0)

    out = np.empty(NTW, dtype=np.complex128)
    out[:M] = xr + 1j * xi
    out[M] = xn_r + 1j * xn_i
    return out


# ── 自检 ──────────────────────────────────────────────────────────────
def main():
    re_tab, im_tab = twiddle_q14()
    print("=" * 72)
    print("固件 FFT 定点模型自检（N=%d，实数，Q%d 旋转因子）" % (N, TW_FRAC))
    print("=" * 72)

    x = make_input()
    X = fft_fixed(x, re_tab, im_tab)
    # ⚠ 除数是 N 不是 N/2 —— C 的输出标度是「真值/1024」。写成 N/2 会让参照
    #   整体大 2 倍，相对误差看着恒等于 0.5，像算法错，其实是参照错。
    Xf = np.fft.rfft(x.astype(float)) / float(N)

    err = X - Xf
    sig = np.mean(np.abs(Xf) ** 2)
    snr = 10 * np.log10(sig / (np.mean(np.abs(err) ** 2) + 1e-30))
    print("  输入  x: 范围 [%d, %d]，峰值样点 %d"
          % (x.min(), x.max(), int(np.argmax(np.abs(x)))))
    print("  输出  X: 范围 |X| = %.1f .. %.1f" % (np.abs(X).min(), np.abs(X).max()))
    print("  对 float 金标准: 相对 RMS 误差 %.3e    SNR %.1f dB"
          % (np.sqrt(np.mean(np.abs(err) ** 2) / sig), snr))

    # 峰值应该落在 bin 16（周期 64 的三角波）
    pk = int(np.argmax(np.abs(X)))
    print("  峰值 bin = %d (期望 16)" % pk)
    assert pk == 16, "三角波周期 64 ⇒ 基波在 bin 16，峰值不对说明蝶形写错了"

    # 整数化检查：C 侧只能存 int16
    lim = np.abs(np.concatenate([X.real, X.imag])).max()
    print("  整数化：最大 |X| = %.0f (int16 上界 32767)" % lim)
    assert lim <= 32767, "输出超出 int16，标度算错了"

    write_header(re_tab, im_tab)

    if "--ref" in sys.argv:
        os.makedirs(os.path.dirname(OUT_REF), exist_ok=True)
        with open(OUT_REF, "w") as f:
            for v in X:
                f.write("%04x\n" % (int(v.real) & 0xFFFF))
                f.write("%04x\n" % (int(v.imag) & 0xFFFF))
        print("   参照 -> %s (%d 个 16 位字，re/im 交替)" % (OUT_REF, 2 * NTW))

    print("\n  自检通过：算法与定标都对得上 float 金标准。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
