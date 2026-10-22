"""DAS 波束形成器 —— 固件定点模型（README §26.1）。

    y[n] = Σ_m  w_m · x_m[n − τ_m]        w_m = 1/M（等权）

这份模型有三个身份，必须**同时**满足：

  1. **产生场景表** —— `sw/fw/fw_das_scene.h` 里的延迟表由它算出来（从真几何
     `mic_geometry.py`，不是手填）。两份东西一旦漂开，TB 会报「输出不对」而
     真正的原因是表和几何不一致。
  2. **产生期望输出** —— `build/fw_das_y.hex`，TB 逐样点比对。
  3. **是定点的唯一口径** —— C 侧必须与这里的每一条移位/取整一字不差。

── 对齐是怎么算的（这一条想清楚能省一整个延迟线）─────────────────────────
把「源 p 的到达延迟 τ_m^p」和「转向 θ̂ 的补偿 comp_m = τ_max^θ̂ − τ_m^θ̂」合起来：

    a_m[n] = s_p( n − (τ_m^p + comp_m^θ̂) )  =  s_p( n − D_m )

  * p = θ̂（目标源、对准目标）：D_m = τ_max^θ̂，**8 路是同一个常数**
    ⇒ 完全对齐，DAS 拿到 M 倍幅度
  * p = 干扰源、对准目标：D_m 各路不同 ⇒ 不对齐 ⇒ 求和时互相抵消

因为 D_m 是**常数**，固件里不需要为每路各存一条延迟线：直接从源信号一次插值
就算出了「已经对齐的」通道。DTCM 因此只剩两张 8 元素的表。

── 定点约定（C 侧照抄）────────────────────────────────────────────────────
    延迟单位 Q16 样点：D_m = round(d_m / c · fs · 65536)
    idx  = D_m >> 16                （算术右移；D_m ≥ 0 所以就是整数部分）
    fr4  = (D_m >> 12) & 0xF        （4 位小数，1/16 样点）
    样本 = v0 + ((v1 − v0) · fr4 >> 4)      v0 = s(idx), v1 = s(idx+1)
    y[n] = (Σ_m a_m[n] + M/2) / M           —— 等权求和，回 int16

⚠ `s(k)` 对 k < 0 **返回 0**（源在 k=0 才出现）。三方都必须这么写 ——
  否则「C 返回 0、Python 报错、TB 给 X」三种行为会让比对没法做。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mic_geometry import C, FS, PLANE_Z, uca_positions  # noqa: E402

N_SAMP = 512          # 一帧样点。与 PDM 采集窗口的 LEN=512 对齐（pdm_array_spec P-11）
Q = 16                # 延迟小数位
FRAC_BITS = 4         # 插值用几位小数（与 fw_srp 的 frac4 同一条约定）
IDX_W = 10            # 转向块的整数位宽（rv32_steer 的 IDX_W，见 gen_steer_vectors.py）

# 场景：与 scripts/golden/check_bf.py 同一组方位（目标/干扰），只是搬到定点
TARGET = (0.12, -0.08)
INTERF = (-0.18, 0.12)

# 三路源的幅度（int16 满幅 32767 的百分之多少）。目标与干扰**等响**（0 dB），
# 与 check_bf.py 的 MIC_SNR_INTERF = 0.0 一致 —— 那才是有事可做的那一档。
AMP_TARGET = 8000
AMP_INTERF = 8000
AMP_NOISE = 250

LCG_A = 1103515245
LCG_C = 12345


def _z(x, y):
    return np.array([x, y, PLANE_Z])


def delays_of_source(src_pos, mics):
    """源到各麦的到达延迟（样点，浮点）。"""
    d = np.linalg.norm(np.asarray(src_pos, float)[None, :] - mics, axis=1)
    return d / C * FS


def q16(tau):
    """浮点样点 -> Q16 整数数组，四舍五入（C 侧的表直接抄这里）。"""
    return np.floor(np.asarray(tau, float) * (1 << Q) + 0.5).astype(np.int64)


def pack14(t):
    """Q16 样点 → 硬件转向块的 14 位打包 {idx[9:0], frac[3:0]}。

    ⚠ 这是 rv32_steer.v 的 LUT 格式，定义在 scripts/golden/gen_steer_vectors.py
      的 pack()。两份必须一字不差 —— 固件那侧参照表和块现场报的值走**同一个**
      解包函数（fw_steer.h 的 fw_steer_unpack14），对不上的话表现是"数字不对"。
      idx 取算术右移（可负，10 位补码），frac 取被丢掉的最高 4 位。
    """
    t = int(t)
    idx = t >> Q
    frac = (t >> (Q - FRAC_BITS)) & 0xF
    return ((idx & ((1 << IDX_W) - 1)) << FRAC_BITS) | frac


def build_tables():
    """算出两张延迟表：目标源对准目标、干扰源对准目标；外加一张转向参照表。"""
    mics = uca_positions()
    t_th = delays_of_source(_z(*TARGET), mics)     # 转向（θ̂ = 目标）
    t_tg = delays_of_source(_z(*TARGET), mics)     # 目标源的到达延迟
    t_if = delays_of_source(_z(*INTERF), mics)     # 干扰源的到达延迟
    comp = t_th.max() - t_th                        # 转向补偿，恒 ≥ 0

    D_target = t_tg + comp        # 恒等于 t_th.max() —— 下面的断言就是在验这件事
    D_interf = t_if + comp
    assert np.allclose(D_target, t_th.max()), "目标源对准目标时 D_m 必须是常数"

    # 转向参照：**块自己的归一化** comp'_m = t_m − t_min（不是上面那个 t.max() − t_m）。
    # 固件的受控那趟算 D_m = 表里的 D_m + comp'_ref[m] − comp'_now[m]，
    # 两个 comp' 都从同一个函数解包 —— 口径推导见 fw_steer.h。
    # 量化方式和块一样是**截断**（pack14 里的 >>），不是 q16 的四舍五入，
    # 否则固件拿到的参照值和块能报出来的值会差 1 个 LSB。
    comp_ref = np.array([pack14(int(v)) for v in q16(t_th - t_th.min())], dtype=np.int64)

    return q16(D_target), q16(D_interf), t_th.max(), comp_ref


# ── 源信号：确定性整数，C 侧照抄 ────────────────────────────────────────────
# ⚠⚠ 这里**必须是有雪崩的 hash，不能是 LCG**。这个坑踩过：
#   一开始写的是「seed = LCG_C + k，再走 3 步 LCG」。三步 LCG 是**仿射**的
#   （s -> A³s + K），所以整体仍是 **k 的仿射函数** ⇒ s(k+1) − s(k) 是常数
#   ⇒ 生成的是**锯齿波**，相邻样点几乎相同。后果不是"看着不对"，而是
#   **干扰源的 8 路通道两两相关系数 0.97**，延迟几个样点根本解不了相关，
#   于是 DAS 求和不但没抵消干扰，还把它放大了（实测 −0.59 dB，本该 +9 dB）。
#   mix32 的三次 xor-shift + 两次乘法有雪崩效应，随机访问且逐位可复现。
MIX_A = 0x7FEB352D
MIX_B = 0x846CA68B
MASK32 = 0xFFFFFFFF


def mix32(x):
    """整数 hash（splitmix 的 32 位 finalizer）。C 侧照抄。"""
    x &= MASK32
    x ^= x >> 16
    x = (x * MIX_A) & MASK32
    x ^= x >> 15
    x = (x * MIX_B) & MASK32
    x ^= x >> 16
    return x


def src_at(kind, k):
    """第 kind 路源的第 k 个样点。k < 0 一律 0（源在 k=0 才出现）。"""
    if k < 0:
        return 0
    seed = 0x5EED_0001 if kind == "target" else 0x5EED_0002
    v = ((mix32(seed ^ (k & MASK32)) >> 16) & 0xFFFF) - 32768
    amp = AMP_TARGET if kind == "target" else AMP_INTERF
    return int(v * amp // 32768)


def noise_at(m, k):
    """第 m 个麦的噪声第 k 个样点。种子含 m ⇒ 8 路互不相关（弥散噪声）。"""
    if k < 0:
        return 0
    v = ((mix32((0x5EED_1000 + m) ^ (k & MASK32)) >> 16) & 0xFFFF) - 32768
    return int(v * AMP_NOISE // 32768)


def _interp(src_fn, D):
    """按 Q16 延迟从源信号插值出**已对齐**的一路通道。与 C 的 interp 一字不差。"""
    out = np.zeros(N_SAMP, dtype=np.int64)
    for n in range(N_SAMP):
        idx = D >> Q
        fr4 = (D >> (Q - FRAC_BITS)) & 0xF
        v0 = src_fn(n - idx)
        v1 = src_fn(n - idx - 1)
        out[n] = v0 + (((v1 - v0) * fr4) >> FRAC_BITS)   # >> 对负数是 floor（Python 与 srai 同）
    return out


def channel(kind, m, D):
    """第 m 路、已对齐到转向方向的通道样点。"""
    if kind == "noise":
        return _interp(lambda k: noise_at(m, k), D)
    return _interp(lambda k: src_at(kind, k), D)


def das_sum(delays=None):
    """DAS：8 路等权求和 -> int16。返回 (y_target, y_interf, y_noise, ch_t, ch_i, ch_n)。"""
    if delays is None:
        Dt, Di = build_tables()[:2]
    else:
        Dt, Di = delays
    ch_t = np.stack([channel("target", m, int(Dt[m])) for m in range(Dt.size)])
    ch_i = np.stack([channel("interf", m, int(Di[m])) for m in range(Di.size)])
    ch_n = np.stack([channel("noise", m, int(Dt[m])) for m in range(Dt.size)])

    def _sum(ch):
        s = ch.sum(axis=0)
        return np.floor_divide(s + ch.shape[0] // 2, ch.shape[0]).astype(np.int64)

    return _sum(ch_t), _sum(ch_i), _sum(ch_n), ch_t, ch_i, ch_n


def _checksum(v):
    c = 0
    for x in v:
        c = (c + int(x)) & 0xFFFFFFFF
    return c


def _wchecksum(v):
    """加权校验和 —— 第二个独立指纹。单个校验和理论上能碰撞（不同波形同和），
    加权之后碰撞要同时满足两个线性约束，实际上做不到。C 侧 `y * (n+1)`。"""
    c = 0
    for n, x in enumerate(v):
        c = (c + int(x) * (n + 1)) & 0xFFFFFFFF
    return c


def _powacc(v):
    """Σ (y>>3)² —— 与 C 的 powacc 一字不差（`>>` 对负数是 floor，两边一致）。"""
    return sum(((int(x) >> 3) ** 2) for x in v)


def fingerprints():
    """算出固件会写进结果块的那几个数，供 TB / 对照打印。"""
    Dt, Di = build_tables()[:2]
    y_t, y_i, y_n, ch_t, ch_i, ch_n = das_sum((Dt, Di))
    y_mix = np.clip(y_t + y_i + y_n, -32768, 32767)
    y_o = y_i + y_n
    mic_t, mic_o = ch_t[0], ch_i[0] + ch_n[0]
    return {
        "cksum": _checksum(y_mix),
        "wcksum": _wchecksum(y_mix),
        "p_target": _powacc(y_t),
        "p_other": _powacc(y_o),
        "p_mic": _powacc(mic_t),
        "p_mic_oth": _powacc(mic_o),
    }


def emit_header(path, Dt, Di, cref):
    """生成延迟表。

    ⚠ **必须纯 ASCII**：这份头文件被 riscv 交叉编译器读，而 build_fw.sh 里的
      生成器一致性检查假定了 ASCII。中文注释在 .py 里随便写，出去就换成英文。
    """
    with open(path, "w", encoding="ascii") as f:
        f.write("/* AUTO-GENERATED by scripts/golden/fw_das_model.py -- do not edit.\n"
                " * Steering delays come from the real geometry (mic_geometry.py);\n"
                " * editing by hand would drift away from it. */\n")
        f.write("#ifndef FW_DAS_SCENE_H\n#define FW_DAS_SCENE_H\n\n#include <stdint.h>\n\n")
        f.write("#define DAS_N_SAMP   %d\n" % N_SAMP)
        f.write("#define DAS_N_CH     %d\n\n" % Dt.size)
        f.write("/* Target source, steered at the target: all 8 delays are EQUAL (perfect align). */\n")
        f.write("static const uint32_t g_das_d_target[DAS_N_CH] = {\n    ")
        f.write(", ".join("0x%08Xu" % int(x) for x in Dt))
        f.write("\n};\n\n")
        f.write("/* Interferer, still steered at the target: delays differ, so the sum cancels. */\n")
        f.write("static const uint32_t g_das_d_interf[DAS_N_CH] = {\n    ")
        f.write(", ".join("0x%08Xu" % int(x) for x in Di))
        f.write("\n};\n\n")
        f.write(
            "/* Steering reference: comp'_m = t_m - t_min at the true TARGET direction,\n"
            " * in the steering block's own 14-bit packed form (idx[9:0], frac[3:0]).\n"
            " * int16 holds it (values 0..0x3FFF), so 8 channels cost 16 bytes -- DTCM has\n"
            " * exactly 16 bytes left, and this is the only shape that fits.\n"
            " * Unpacked by fw_steer_unpack14 (fw_steer.h), the SAME routine that decodes\n"
            " * what the block reports back, so the two can never disagree on format.\n"
            " *\n"
            " * Defined by exactly ONE translation unit -- fw_das.c, which sets\n"
            " * FW_DAS_SCENE_DEFINE_COMP_REF before including this header. Everything else\n"
            " * (fw_main.c, fw_steer.c) only sees the extern declaration in fw_steer.h.\n"
            " * A plain `const` array has external linkage in C, so putting the\n"
            " * initializer here unguarded makes every includer define the symbol: that is\n"
            " * a multiple-definition link error, and the `static` alternative would emit\n"
            " * one 16-byte copy per referring TU -- 16 bytes too many for the .bss gate. */\n"
            "#ifdef FW_DAS_SCENE_DEFINE_COMP_REF\n"
            "const int16_t g_steer_comp_ref[DAS_N_CH] = {\n    ")
        f.write(", ".join("0x%04x" % (int(x) & 0xFFFF) for x in cref))
        f.write("\n};\n#endif\n\n")
        f.write("#endif /* FW_DAS_SCENE_H */\n")


def emit_hex(path, vals):
    with open(path, "w", encoding="ascii") as f:
        for v in vals:
            f.write("%04x\n" % (int(v) & 0xFFFF))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", ".."))
    Dt, Di, tmax, cref = build_tables()

    emit_header(os.path.join(root, "sw", "fw", "fw_das_scene.h"), Dt, Di, cref)

    y_t, y_i, y_n, ch_t, ch_i, ch_n = das_sum((Dt, Di))
    mix = np.clip(y_t + y_i + y_n, -32768, 32767).astype(np.int64)

    os.makedirs(os.path.join(root, "build"), exist_ok=True)
    emit_hex(os.path.join(root, "build", "fw_das_y_mix.hex"), mix)
    emit_hex(os.path.join(root, "build", "fw_das_y_target.hex"), y_t)
    emit_hex(os.path.join(root, "build", "fw_das_y_other.hex"),
             np.clip(y_i + y_n, -32768, 32767))

    print("== DAS 定点模型 ==")
    print("   目标源对准目标：D_m 常数 = %d (Q16) = %.4f 样点" % (Dt[0], Dt[0] / 2**Q))
    print("   干扰源的 D_m 展开：", " ".join("%d" % (x - Di[0]) for x in Di), " (相对首路, Q16)")
    print("   对齐后 8 路是否同一条：",
          bool(np.all(ch_t[0] == ch_t[1]) and np.all(ch_t[0] == ch_t[7])))
    print("   混合输出 y_mix：前 8 =", " ".join("%d" % v for v in mix[:8]))
    print("   y_mix 校验和 = 0x%08X" % _checksum(mix))
    # 单麦基线：拿第 0 路的「目标」比第 0 路的「其余」——不做任何空间处理
    o0 = (ch_i[0] + ch_n[0]).astype(float)
    o_das = (y_i + y_n).astype(float)
    snr_mic = 10 * np.log10(np.mean(ch_t[0].astype(float) ** 2) / (np.mean(o0 ** 2) + 1e-30))
    snr_das = 10 * np.log10(np.mean(y_t.astype(float) ** 2) / (np.mean(o_das ** 2) + 1e-30))
    print("   单麦基线 %+.2f dB  ->  DAS %+.2f dB  （改善 %+.2f dB）"
          % (snr_mic, snr_das, snr_das - snr_mic))

    fp = fingerprints()
    with open(os.path.join(root, "build", "fw_das_fp.hex"), "w", encoding="ascii") as f:
        # 顺序与 fw_das.h 的 RES 下标一致，TB 按行读
        for k in ("cksum", "wcksum", "p_target", "p_other", "p_mic", "p_mic_oth"):
            f.write("%08x\n" % (fp[k] & 0xFFFFFFFF))
    print("   固件应报的指纹：ck=0x%08X wck=0x%08X" % (fp["cksum"], fp["wcksum"]))
    print("                    p_t=%d p_o=%d p_mic=%d p_mic_oth=%d"
          % (fp["p_target"], fp["p_other"], fp["p_mic"], fp["p_mic_oth"]))
    print("   （固件按 >>3 定标累加，同一口径下 SNR 可直接由 p 相除得到）")
    print("   写出：sw/fw/fw_das_scene.h  build/fw_das_y_*.hex")


if __name__ == "__main__":
    main()
