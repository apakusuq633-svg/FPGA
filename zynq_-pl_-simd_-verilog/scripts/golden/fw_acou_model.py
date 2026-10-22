"""声学扩展单元（rtl/acoustic/rv32_acoustic_ext.v）的逐位模型 + 测试向量。

四条指令在这个模型里各写一遍，RTL 那边必须**一字不差**地给出同样的结果。
仿真的价值在于它跑的是真 RTL；这个模型的价值在于**秒级**告诉你结果该是多少，
以及出错时立刻能分清「RTL 错」还是「参照错」。

指令（编码见 RTL 头部）
    VCMUL  Z = X · Y          逐点复数乘
    VSUB   Z = X · conj(Y)    互谱
    VPHAT  Z = Z/|Z| · 限带   白化（α-max-β-min + 4-bit 倒数 LUT）
    VRED2  rd = {ΣIm X, ΣRe X} 对偶归约

数据布局：512 条复数，每条一个 32 位字 {im[31:16], re[15:0]}，re/im 各 Q15。

生成物（build/）：
    acou_x.hex      X 的初值（512 字）
    acou_y.hex      Y 的初值（512 字）
    acou_z_vcmul.hex / acou_z_vsub.hex / acou_z_vphat.hex
    acou_red2.hex   VRED2 的期望结果（1 字）
"""
import os
import sys

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "build")

CN = 208
LCG_A, LCG_C, LCG_SEED = 1103515245, 12345, 0x2468ACE0
BAND_LO, BAND_HI = 0, 203


def q16(v):
    """折成 16 位有符号（RTL 那边函数返回 16 位，就是回绕）。"""
    return ((int(v) + 0x8000) & 0xFFFF) - 0x8000


def signed16(v):
    v = int(v) & 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def q30_to_q15(v):
    """RTL: (v + 16384) >>> 15，取低 16 位。"""
    return q16((int(v) + 16384) >> 15)


def q29_to_q15(v):
    """RTL: (v + 8192) >>> 14，取低 16 位。"""
    return q16((int(v) + 8192) >> 14)


def mag_approx(re, im):
    """α-max-β-min，无符号 16 位。与 RTL 的 mag_approx 一致。"""
    a = abs(signed16(re)) & 0xFFFF
    b = abs(signed16(im)) & 0xFFFF
    big, sml = (a, b) if a > b else (b, a)
    return (big + (sml >> 1) - (sml >> 3) + (sml >> 5) + (sml >> 7)) & 0xFFFF


LUT = [15888, 14895, 14014, 13233, 12537, 11915, 11357, 10855,
       10402, 9993, 9621, 9281, 8969, 8682, 8417, 8192]


def recip_q14(mag):
    """4 位 LUT 倒数，返回 Q14。与 RTL 的 recip_q14 一致。"""
    if mag == 0:
        return 16384
    e = 0
    for b in range(15, -1, -1):
        if (mag >> b) & 1:
            e = b
            break
    mant = (mag >> (e - 14)) if e >= 14 else (mag << (14 - e))
    idx = (mant >> 10) & 0xF
    lut = LUT[idx]
    return (lut >> (e - 14)) if e >= 14 else ((lut << (14 - e)) & 0xFFFF)


def pack(re, im):
    return ((int(im) & 0xFFFF) << 16) | (int(re) & 0xFFFF)


def unpack(w):
    return signed16(w & 0xFFFF), signed16((w >> 16) & 0xFFFF)


def cplx_op(x, y, conj):
    """RTL 的 VCMUL / VSUB 共用体：pr = ar·br − ai·bi'，pi = ar·bi' + ai·br。"""
    out = []
    for i in range(CN):
        ar, ai = unpack(x[i])
        br, bi = unpack(y[i])
        if conj:
            bi = -bi
        pr = ar * br - ai * bi
        pi = ar * bi + ai * br
        out.append(pack(q30_to_q15(pr), q30_to_q15(pi)))
    return out


def vphat(z):
    out = []
    for i in range(CN):
        re, im = unpack(z[i])
        if BAND_LO <= i <= BAND_HI:
            mag=mag_approx(re,im)
            exponent=max(0,mag.bit_length()-1)
            mant=(mag>>(exponent-14)) if exponent>=14 else mag<<(14-exponent)
            coefficient=LUT[(mant>>10)&15]
            out.append(pack(q16((re*coefficient)>>exponent),q16((im*coefficient)>>exponent)))
        else:
            out.append(0)
    return out


def vred2(x):
    sr = sum(unpack(w)[0] for w in x) & 0xFFFF
    si = sum(unpack(w)[1] for w in x) & 0xFFFF
    return pack(sr, si)


def gen_vectors():
    """与固件/TB 三方共用的伪随机向量。"""
    s = LCG_SEED
    x, y = [], []
    for i in range(CN):
        s = (s * LCG_A + LCG_C) & 0xFFFFFFFF
        x.append(pack(signed16(s >> 16), signed16(s & 0xFFFF)))
        s = (s * LCG_A + LCG_C) & 0xFFFFFFFF
        y.append(pack(signed16(s >> 16), signed16(s & 0xFFFF)))
    x[0]=pack(256,0);y[0]=pack(128,0)
    x[1]=pack(0,256);y[1]=pack(0,-32768)
    return x, y


def dump(path, words):
    with open(os.path.join(OUT, path), "w") as f:
        for w in words:
            f.write("%08x\n" % (int(w) & 0xFFFFFFFF))
    print("   -> %s (%d 字)" % (path, len(words)))


def main():
    os.makedirs(OUT, exist_ok=True)
    x, y = gen_vectors()

    z_mul = cplx_op(x, y, conj=False)
    z_sub = cplx_op(x, y, conj=True)
    z_phat = vphat(z_sub)
    red = vred2(x)

    print("=" * 72)
    print("声学扩展单元定点模型（%d 条复数，LANES=8 只影响拍数不影响结果）" % CN)
    print("=" * 72)

    # 自检：白化之后带内幅度应接近 Q14 的 1.0（16384）
    mags = []
    for i in range(BAND_LO, BAND_HI + 1):
        re, im = unpack(z_phat[i])
        mags.append(mag_approx(re, im))
    mags = np.array(mags)
    print("  白化后带内幅值: 均值 %.0f（目标 16384），范围 [%d, %d]"
          % (mags.mean(), mags.min(), mags.max()))
    assert 12000 < mags.mean() < 20000, "白化没把幅度归一化到 1.0 附近"
    print("  带外应为 0: %s" % ("是" if all(z_phat[i] == 0
                                            for i in list(range(0, BAND_LO)) +
                                            list(range(BAND_HI + 1, CN))) else "否"))
    sd = abs(mags.mean() - 16384) / 16384.0
    print("  白化标度偏差 %.2f%% —— 4-bit LUT 的代价（README §0.3.4 说够用）"
          % (sd * 100))

    print("  VRED2 期望 = %08x" % red)

    dump("acou_x.hex", x)
    dump("acou_y.hex", y)
    dump("acou_z_vcmul.hex", z_mul)
    dump("acou_z_vsub.hex", z_sub)
    dump("acou_z_vphat.hex", z_phat)
    dump("acou_red2.hex", [red])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
