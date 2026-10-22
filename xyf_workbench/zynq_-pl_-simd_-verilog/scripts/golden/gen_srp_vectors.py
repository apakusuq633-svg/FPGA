"""为 rv32_srp_scan 生成仿真向量与**逐位精确**的参照（README §39 的四层验证）。

为什么参照要从**量化后的 R** 算起
--------------------------------
RTL 收到的是 16 位整数 R，不是浮点。如果参照用浮点 R 算，那比较里就混进了
「量化误差」和「算法误差」两种东西，分不清。所以这里先把 R 量化成 int16，
**再**用同一份量化值算参照 P —— 这样 RTL 与参照之间只该有插值算术的差别。

与 RTL 严格对齐的两处：
  插值   interp = v0 + ((diff * frac) >> FRAC_W)      # >> 是向下取整，不是向零
  累加   P += interp                                   # int32，溢出按回绕

输出（写到 build/）
  <前缀>_lut.hex    N_PAIR*N_GRID 条，每条 14 位 {idx[13:4], frac[3:0]}
  <前缀>_r.hex      N_PAIR*R_LEN  条，每条 16 位有符号
  <前缀>_p_ref.hex  N_GRID 条，每条 32 位有符号
  <前缀>_meta.txt   本次用的声源真值与缩放，便于人工核对

⚠ **LUT 与 R 的条数不是同一个数**：LUT 每格点一条，R 是整条相关序列（R_LEN 条）。
  两者在 RTL 里也是分开的两个参数（rv32_srp_scan.v 的 N_GRID 与 R_LEN）——
  写成同一个数正是"4×256 档位会读到下一对的行里"那个坑的来源。

为什么参数化
------------
默认（28 对 × 32×32 × R_LEN=1024）是 tb_srp_scan 用的全尺寸口径，**输出文件名不变**。
`--pairs/--grid-w/--out-prefix` 用来生成 **SoC 里实际例化的那一档**（4 对 × 16×16），
供 tb_srp_regs 走寄存器窗口逐位比对 —— 门禁要盖的是真正上板的那份参数。
"""
import argparse
import os

import numpy as np

from array_sim import ROOM_DESK, make_case
from gcc_phat import band_mask
from mic_geometry import (FS, GRID_H, GRID_W, N_PAIR, delay_lut, pair_list,
                          quantize_lut, scan_grid, uca_positions)
from srp_phat import hann

N      = 4096
NFFT   = 1024          # 相关序列长度 = R 的行长（R_LEN），也是 τ 绕回的模
FRAC_W = 4
IDX_W  = 10
SRC    = (0.12, -0.08)
OUT    = os.path.join(os.path.dirname(__file__), "..", "..", "build")


def build_vectors(n_pair=None, grid_w=None, out_prefix="srp"):
    pts, xs, ys = scan_grid(grid_w, grid_w) if grid_w else scan_grid()
    mics = uca_positions()
    pairs = pair_list(len(mics))
    if n_pair:
        # 固件用的是前 N 对（(0,1),(0,2),…，顺序由 mic_geometry.pair_list 定，
        # fw_main.c 的 pi4_l/pj4_l 与它同序）—— 取前 N 对即与固件对齐。
        pairs = pairs[:n_pair]
    n_pair = len(pairs)
    n_grid = len(pts)
    r_len  = NFFT                      # R 行长恒为相关序列长度
    tau = delay_lut(pts, mics, pairs, NFFT)
    idx, frac = quantize_lut(tau, NFFT)

    # ── R：与 golden 的 SRP 同一条链，但把 PHAT 之后的互谱量化成定点 ──
    case = make_case(SRC, n=N, snr_db=20.0, seed=7, room=ROOM_DESK, order=1)
    x = case["data"] * hann(N)[None, :]
    X = np.fft.rfft(x, NFFT, axis=1)
    f = np.fft.rfftfreq(NFFT, 1 / FS)
    m = ((f >= 200.0) & (f <= 8000.0)).astype(float)[None, :]

    Psi = np.empty((n_pair, X.shape[1]), dtype=complex)
    for k, (i, j) in enumerate(pairs):
        G = X[i] * np.conj(X[j])
        # 幅值用 RTL 那套 α-max-β-min 近似，不是真开方 —— 参照必须走同一条路
        a, b = np.abs(G.real), np.abs(G.imag)
        mx, mn = np.maximum(a, b), np.minimum(a, b)
        mag = mx + mn * 0.5 - mn * 0.125 + mn * 0.03125 + mn * 0.0078125
        Psi[k] = G / (mag + 1e-12) * m[0]

    R = np.fft.irfft(Psi, NFFT, axis=1)            # (n_pair, r_len) 单位幅度
    # 量化成 int16：满幅映射到 32767
    scale = 32767.0 / np.abs(R).max()
    Rq = np.clip(np.round(R * scale), -32768, 32767).astype(np.int32)

    # ── 参照 P：完全按 RTL 的算术走 ──
    # ⚠ fr 必须**用与 LUT 完全相同的量化**，不能在这里重新 int(frac)。
    #   第一版这里漏了，写出 int(frac)=0，于是参照是"关掉插值"的版本，
    #   而 LUT 也是 0 —— **两边一起错，TB 照样通过**。
    #   抓出它的是第 4 段反证（关掉插值后 P 几乎没变，说明插值根本没在工作）。
    PG = n_grid
    fr_q = np.minimum(np.round(frac * (1 << FRAC_W)).astype(np.int64),
                      (1 << FRAC_W) - 1)           # (PG, n_pair) 与 LUT 同源
    ref = np.zeros(PG, dtype=np.int64)
    for k in range(n_pair):
        rk = Rq[k]
        for g in range(PG):
            i0 = int(idx[g, k]); fr = int(fr_q[g, k])
            # 绕回按 **r_len**（= 相关序列长度 = RTL 里 R 的行长），不是 n_grid。
            # 写成 n_grid 会在小网格档位上偷偷改变语义 —— 而这一行正是
            # "R_LEN 必须独立于 N_GRID"那个坑的参照侧。
            v0 = int(rk[i0]); v1 = int(rk[(i0 + 1) % r_len])
            interp = v0 + ((v1 - v0) * fr >> FRAC_W)
            ref[g] += interp
    ref32 = ref.astype(np.int32)                   # 回绕，与 RTL 一致

    gw = grid_w if grid_w else GRID_W

    def out(name):
        return os.path.join(OUT, f"{out_prefix}_{name}")

    os.makedirs(OUT, exist_ok=True)
    with open(out("lut.hex"), "w") as fh:
        for k in range(n_pair):
            for g in range(PG):
                # ⚠ frac 是 [0,1) 的**浮点**，必须乘 2^FRAC_W 再取整。
                #   写成 int(frac) 会把它截成 0 —— LUT 里一个小数位都没有，
                #   插值静默失效，而 TB 仍会"通过"（两边一起错）。踩过一次。
                fq = int(fr_q[g, k])
                packed = (int(idx[g, k]) << FRAC_W) | fq
                fh.write(f"{packed:04x}\n")
    with open(out("r.hex"), "w") as fh:
        for k in range(n_pair):
            for g in range(r_len):
                fh.write(f"{int(Rq[k, g]) & 0xffff:04x}\n")
    with open(out("p_ref.hex"), "w") as fh:
        for g in range(PG):
            fh.write(f"{int(ref32[g]) & 0xffffffff:08x}\n")
    with open(out("meta.txt"), "w", encoding="utf-8") as fh:
        fh.write(f"src={SRC}\nscale={scale:.6f}\n")
        fh.write(f"n_pair={n_pair}\nn_grid={n_grid}\nr_len={r_len}\ngrid_w={gw}\n")
        fh.write(f"R range=[{Rq.min()},{Rq.max()}]\n")
        fh.write(f"P ref range=[{ref32.min()},{ref32.max()}]\n")
        argmax = int(np.argmax(ref32))
        fh.write(f"P argmax grid={argmax} -> x={xs[argmax % gw]*1000:.1f}mm "
                 f"y={ys[argmax // gw]*1000:.1f}mm\n")

    print(f"LUT    {n_pair*PG} 条")
    print(f"R      {n_pair*r_len} 条，范围 [{Rq.min()}, {Rq.max()}]")
    print(f"P 参照 {PG} 条，范围 [{ref32.min()}, {ref32.max()}]")
    print(f"参照峰值格号 {argmax}  →  x={xs[argmax % gw]*1000:.1f} mm  "
          f"y={ys[argmax // gw]*1000:.1f} mm")
    return ref32


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pairs", type=int, default=None,
                    help="用前 N 对麦克风（默认全部 28 对）")
    ap.add_argument("--grid-w", type=int, default=None,
                    help="扫描网格边长（默认 32 → 32×32=1024 格）")
    ap.add_argument("--out-prefix", default="srp",
                    help="输出文件名前缀，默认 srp（tb_srp_scan 用的那一套）")
    a = ap.parse_args()
    build_vectors(n_pair=a.pairs, grid_w=a.grid_w, out_prefix=a.out_prefix)
