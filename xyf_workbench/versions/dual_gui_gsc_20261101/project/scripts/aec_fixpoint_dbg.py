"""Fixed-point NLMS: is the divergence the update path's rounding bias?"""
import numpy as np
import sys
from aec_probe import rir_image, speechlike, white, FS

room = np.array([5.0, 4.0, 2.8]); src = np.array([1.0, 2.0, 1.2]); mic = np.array([3.5, 1.5, 1.2])
h = rir_image(room, src, mic, FS, max_order=12, alpha=0.60, h_len=int(0.8 * FS))
M = int(8.0 * FS)
use_speech = '--white' not in sys.argv
x = speechlike(M, seed=3) if use_speech else white(M, seed=11)
d = np.convolve(x, h)[:M] + 1e-4 * np.random.default_rng(9).standard_normal(M)

N, mu_m = 1024, 2
xs = np.clip(np.round(x * 32767), -32768, 32767).astype(np.int64)
ds = np.clip(np.round(d * 32767), -32768, 32767).astype(np.int64)


def run(rounding):
    w = np.zeros(N, dtype=np.int64); xb = np.zeros(N, dtype=np.int64); e_f = np.zeros(M)
    for n in range(M):
        xb[1:] = xb[:-1]; xb[0] = xs[n]
        yi = max(-32768, min(32767, int(np.dot(w, xb)) >> 15))
        ei = max(-32768, min(32767, int(ds[n]) - yi))
        e_f[n] = ei / 32768.0
        S1 = int(np.sum(np.abs(xb)))
        sh = max(0, 2 * max(S1, 1).bit_length() - (N.bit_length() - 1))
        k = sh + mu_m - 15
        t = ei * xb
        if k <= 0:
            upd = t << (-k)
        elif rounding == 'floor':
            upd = t >> k                      # arithmetic shift: -0.5 LSB bias per tap
        else:                                 # round half away from zero
            half = 1 << (k - 1)
            upd = np.where(t >= 0, (t + half) >> k, -(((-t) + half) >> k))
        w = np.clip(w + upd, -32768, 32767)
    return e_f, w


for rounding in ('floor', 'round'):
    e_f, w = run(rounding)
    erle = []
    for t in range(2, 8):
        a, b = t * FS, (t + 1) * FS
        erle.append(10 * np.log10(np.mean(d[a:b] ** 2) / np.mean(e_f[a:b] ** 2)))
    ht = h[:N] * 32768
    print(f"rounding={rounding:6s} per-second ERLE = " +
          " ".join(f"{v:6.2f}" for v in erle) +
          f"  mean={np.mean(erle):6.2f} dB")
    print(f"        ||w||={np.linalg.norm(w.astype(float)):9.1f}  ||h[:N]*32768||={np.linalg.norm(ht):7.1f}  "
          f"corr={np.corrcoef(w.astype(float), ht)[0,1]:+.4f}")
