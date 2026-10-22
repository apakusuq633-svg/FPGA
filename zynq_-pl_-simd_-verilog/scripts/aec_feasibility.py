"""AEC verification feasibility probe. numpy only (WSL has numpy 1.21.5, no scipy).

Answers, with numbers:
  1. image-method RIR: does it run, how long, how many lines?
  2. NLMS ERLE: float vs 16-bit fixed point (exact-norm vs power-of-two norm)
  3. convergence time in samples  -> sets the RTL sim length
  4. ERLE vs N (taps) and vs filter/RIR length mismatch
  5. double talk with / without a freeze (DTD)
"""
import time
import numpy as np

FS = 16000
C = 343.0


# ---------------------------------------------------------------- RIR (image method)
def rir_image(room, src, mic, fs, max_order=10, alpha=0.30, h_len=None, c=C):
    """Allen-Berkley shoebox image-source RIR. ~30 lines. Returns (h, n0)."""
    beta = np.sqrt(1.0 - alpha)
    n = np.arange(-max_order, max_order + 1)
    per_dim = []
    for xs, L in zip(src, room):
        per_dim.append((np.concatenate([2 * n * L + xs, 2 * n * L - xs]),
                        np.concatenate([np.abs(n), np.abs(n)])))
    if h_len is None:
        h_len = int(round(0.6 * fs))          # 600 ms tail is plenty for RT60 ~ 0.3 s
    h = np.zeros(h_len)
    for ix in range(len(per_dim[0][0])):
        for iy in range(len(per_dim[1][0])):
            for iz in range(len(per_dim[2][0])):
                px = np.array([per_dim[0][0][ix], per_dim[1][0][iy], per_dim[2][0][iz]])
                order = per_dim[0][1][ix] + per_dim[1][1][iy] + per_dim[2][1][iz]
                d = np.linalg.norm(px - np.asarray(mic))
                if d < 1e-6:
                    continue
                amp = beta ** order / (4 * np.pi * d)
                idx = d / c * fs
                i0 = int(np.floor(idx))
                frac = idx - i0
                # 8-tap windowed sinc fractional delay (no scipy needed)
                if i0 < 4 or i0 > h_len - 4:
                    continue
                k = np.arange(-4, 5)
                w = np.sinc(k - frac) * np.hanning(9)
                h[i0 + k] += amp * w
    return h


def rt60_of(h, fs):
    """Schroeder backward integration, -60 dB point."""
    e = np.cumsum(h[::-1] ** 2)[::-1]
    if e[0] <= 0:
        return 0.0
    db = 10 * np.log10(np.maximum(e / e[0], 1e-30))
    below = np.argmax(db < -60)
    return (below / fs) if below > 0 else len(h) / fs


# ---------------------------------------------------------------- signals
def white(n, seed=0):
    return np.random.default_rng(seed).standard_normal(n) * 0.1


def speechlike(n, seed=1, fs=FS):
    """Band-limited (100 Hz - 3.5 kHz) 1/f^0.6 noise with a 4 Hz syllabic envelope.

    The band limit matters: an unbounded 1/f^0.6 tilt piles energy below 20 Hz,
    where a real room's |H(f)| still passes it, and inflates the simulated echo by
    ~17 dB. Real speech rolls off below ~100 Hz. The stimulus spectrum *is* the
    measurement, so it has to be stated precisely -- same reason G.168 pins down
    its test signals.
    """
    rng = np.random.default_rng(seed)
    X = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / fs)
    f[0] = f[1]
    hp = (f / 100.0) ** 2 / (1.0 + (f / 100.0) ** 2)          # -12 dB/oct below 100 Hz
    lp = 1.0 / (1.0 + (f / 3500.0) ** 4)                      # steep above 3.5 kHz
    X *= (1.0 / (f ** 0.6)) * hp * lp
    x = np.fft.irfft(X, n)
    x /= np.std(x)
    t = np.arange(n) / fs
    env = 0.55 + 0.45 * np.sin(2 * np.pi * 4.0 * t) ** 2
    return 0.1 * x * env


# ---------------------------------------------------------------- NLMS
def nlms(x, d, N, mu=0.5, eps=1e-6, fix=None, fix_m=1):
    """NLMS. fix=None -> float; fix=16 -> Q15 emulation with power-of-two norm.

    Returns e (residual), and per-sample ERLE computed on a 1024-sample window.
    """
    M = len(x)
    e = np.zeros(M)
    y = np.zeros(M)
    if fix:
        w = np.zeros(N, dtype=np.int64)
        xb = np.zeros(N, dtype=np.int64)
        xs = np.clip(np.round(x * 32767), -32768, 32767).astype(np.int64)
        ds = np.clip(np.round(d * 32767), -32768, 32767).astype(np.int64)
    else:
        w = np.zeros(N)
        xb = np.zeros(N)
    for n in range(M):
        xb[1:] = xb[:-1]
        if fix:
            xb[0] = xs[n]
        else:
            xb[0] = x[n]
        if fix:
            acc = int(np.dot(w, xb))                                    # Q30
            yi = max(-32768, min(32767, acc >> 15))                     # Q15
            ei = max(-32768, min(32767, int(ds[n]) - yi))
            e[n] = ei / 32768.0        # store in the same units as the float path
            y[n] = yi / 32768.0
            # power-of-two NLMS: ||x||^2 ~ (sum|x|)^2 / N, shift by its log2.
            # sum|x| fits in 32 bits; sum of squares does not (N=1024, Q15 -> >2^32),
            # which is exactly why RTL AECs use this "block floating point" norm.
            S1 = int(np.sum(np.abs(xb)))
            # ceil, not floor: flooring log2 costs 2 bits of gain and turns a
            # 20 dB ERLE into a divergence. This is the #1 fixed-point NLMS trap.
            sh = max(0, 2 * max(S1, 1).bit_length() - (N.bit_length() - 1))
            # w += mu*e*x*2^15 / ||x||^2   with mu = 2^-m
            k = sh + fix_m - 15
            upd = (ei * xb) >> k if k >= 0 else (ei * xb) << (-k)
            w = np.clip(w + upd, -32768, 32767)
        else:
            y[n] = np.dot(w, xb)
            e[n] = d[n] - y[n]
            nrm = np.dot(xb, xb) + eps
            w = w + mu * e[n] * xb / nrm
    return e, y, w


def erle_curve(d, e, win=1024):
    """ERLE(n) = 10log10(sum d^2 / sum e^2) over a sliding window."""
    k = np.ones(win)
    pd = np.convolve(d ** 2, k, 'valid')
    pe = np.convolve(e ** 2, k, 'valid')
    return 10 * np.log10(np.maximum(pd, 1e-30) / np.maximum(pe, 1e-30))


def erle_gated(d, e, seg, win=1024, act_db=20.0, noise_pow=None):
    """ERLE over [seg), gated on far-end activity.

    An ungated ERLE is meaningless: during a far-end silence the residual is only
    the mic noise floor while d is ~0, so the ratio goes negative. Every block
    must first be shown to *have* echo in it before its ERLE counts.
    Returns (median, p10, n_active, n_blocks).
    """
    a, b = max(0, seg[0]), seg[1]
    if b - a < win:
        return float('nan'), float('nan'), 0, 0
    d = d[a:b] - np.mean(d[a:b])
    e = e[a:b] - np.mean(e[a:b])
    n = len(d) // win
    dd = d[:n * win].reshape(n, win)
    ee = e[:n * win].reshape(n, win)
    pd = np.mean(dd ** 2, axis=1)
    pe = np.mean(ee ** 2, axis=1)
    ref = noise_pow if noise_pow is not None else np.percentile(pd, 5)
    active = pd > ref * 10 ** (act_db / 10)
    if active.sum() == 0:
        return float('nan'), float('nan'), 0, n
    v = 10 * np.log10(pd[active] / np.maximum(pe[active], 1e-30))
    return float(np.median(v)), float(np.percentile(v, 10)), int(active.sum()), n


def main():
    t0 = time.time()
    room = np.array([5.0, 4.0, 2.8])
    src = np.array([1.0, 2.0, 1.2])
    mic = np.array([3.5, 1.5, 1.2])

    # ---- how many taps does each room actually need?
    print("[RIR ] room 5.0x4.0x2.8 m, mic-src 2.9 m")
    rirs = {}
    for alpha in (0.15, 0.30, 0.60, 0.85):
        t1 = time.time()
        h = rir_image(room, src, mic, FS, max_order=12, alpha=alpha, h_len=int(0.8 * FS))
        e_c = np.cumsum(h ** 2)
        need90 = int(np.argmax(e_c > 0.9 * e_c[-1]))
        need99 = int(np.argmax(e_c > 0.99 * e_c[-1]))
        rirs[alpha] = h
        print(f"       alpha={alpha:.2f} RT60={rt60_of(h,FS)*1000:5.0f} ms  "
              f"90% energy in {need90:5d} taps ({need90/FS*1000:4.0f} ms)  "
              f"99% in {need99:5d} taps  build={time.time()-t1:.1f}s")

    T = 8.0
    M = int(T * FS)
    x = speechlike(M, seed=3)
    rng = np.random.default_rng(9)
    noise = 1e-4 * rng.standard_normal(M)
    NPOW = float(np.var(noise))

    # ---- ERLE vs N, float vs 16-bit, for a short-RT60 and a long-RT60 room
    for alpha in (0.85, 0.60):
        h = rirs[alpha]
        d_clean = np.convolve(x, h)[:M]
        d = d_clean + noise
        print(f"[SIG ] alpha={alpha} RT60={rt60_of(h,FS)*1000:.0f} ms  x_rms={np.std(x):.4f} "
              f"echo_rms={np.std(d_clean):.4f} noise_rms={np.std(noise):.2e} "
              f"echo/noise={20*np.log10(np.std(d_clean)/np.std(noise)):.1f} dB")
        for N in (256, 512, 1024, 2048):
            for fix in (None, 16):
                t1 = time.time()
                e, y, w = nlms(x, d, N, mu=0.5, fix=fix)
                # convergence timeline: ERLE over each trailing 0.25 s, gated
                pts = [erle_gated(d, e, (int((ts - 0.25) * FS), int(ts * FS)), noise_pow=NPOW)[0]
                       for ts in (0.25, 0.5, 1.0, 2.0)]
                med, p10, na, nb = erle_gated(d, e, (int(6.0 * FS), int(8.0 * FS)),
                                              noise_pow=NPOW)
                tag = 'float' if fix is None else 'Q15/2^k'
                print(f"[ERLE] N={N:5d} {tag:8s} 250ms={pts[0]:6.2f} 500ms={pts[1]:6.2f} "
                      f"1s={pts[2]:6.2f} 2s={pts[3]:6.2f} ss_med={med:6.2f} ss_p10={p10:6.2f} "
                      f"dB (active {na}/{nb}) sim={time.time()-t1:.1f}s")

    # ---- white far-end (what a TB would actually use: deterministic, seedable)
    xw = white(M, seed=11)
    print("[WHITE far-end, alpha=0.60, RT60=317ms]")
    h = rirs[0.60]
    dw = np.convolve(xw, h)[:M] + noise
    for N in (256, 1024):
        for fix in (None, 16):
            e, y, w = nlms(xw, dw, N, mu=0.5, fix=fix)
            med, p10, na, nb = erle_gated(dw, e, (int(6.0 * FS), int(8.0 * FS)), noise_pow=NPOW)
            pts = [erle_gated(dw, e, (int((ts - 0.25) * FS), int(ts * FS)), noise_pow=NPOW)[0]
                   for ts in (0.05, 0.1, 0.25, 0.5)]
            tag = 'float' if fix is None else 'Q15/2^k'
            print(f"       N={N:5d} {tag:8s} 50ms={pts[0]:6.2f} 100ms={pts[1]:6.2f} "
                  f"250ms={pts[2]:6.2f} 500ms={pts[3]:6.2f} ss_med={med:6.2f} "
                  f"ss_p10={p10:6.2f} dB (active {na}/{nb})")

    # ---- filter shorter than the RIR
    h = rirs[0.30]
    d_clean = np.convolve(x, h)[:M]
    print("[MISM] filter N=1024, RIR truncated to L (alpha=0.30):")
    for L in (256, 512, 1024, 2048, 4096):
        hL = h[:L]
        dL = np.convolve(x, hL)[:M] + noise
        e, y, w = nlms(x, dL, 1024, mu=0.5)
        med, p10, na, nb = erle_gated(dL, e, (int(6.0 * FS), int(8.0 * FS)), noise_pow=NPOW)
        kept = np.sum(hL ** 2) / np.sum(h ** 2)
        print(f"       L={L:5d} ({L/FS*1000:5.0f} ms)  ss_med={med:6.2f} dB  "
              f"energy kept={kept*100:5.1f}%  ceiling=10log10(1/(1-kept))={10*np.log10(1/(1-kept)):5.2f} dB")

    # ---- double talk
    N = 1024
    v = speechlike(M, seed=77) * 0.7
    dt = d_clean + noise + v
    e_free, _, w_free = nlms(x, dt, N, mu=0.5)      # no DTD: adapts through the burst
    e_dtd, _, w_dtd = nlms(x, d, N, mu=0.5)         # frozen for the whole run
    print(f"[DTTK] ERL = {20*np.log10(np.std(d_clean)/np.std(v)):.1f} dB "
          f"(near-end 1.5 s burst at t=3.0 s)")
    pre = erle_gated(dt, e_free, (int(2.0 * FS), int(3.0 * FS)), noise_pow=NPOW)[0]
    post = erle_gated(dt, e_free, (int(5.0 * FS), int(6.0 * FS)), noise_pow=NPOW)[0]
    print(f"       single-talk ERLE before burst free={pre:6.2f} dB (filter has converged)")
    # during the burst the residual is dominated by near-end v, so ERLE is NOT the metric;
    # the honest one is how far the weights drifted:
    print(f"       ||w_free-w_frozen||/||w_frozen|| after the burst = "
          f"{np.linalg.norm(w_free-w_dtd)/np.linalg.norm(w_dtd)*100:5.1f}%")
    # convergence of the *filter itself*: project w_free onto w_frozen
    h_est = w_dtd / 32767.0 if False else w_dtd
    h_true = rirs[0.30][:N]
    print(f"       misadjustment after burst, ||w_free[:N]-h||/||h|| = "
          f"{np.linalg.norm(w_free[:N]-h_true)/np.linalg.norm(h_true)*100:5.1f}%"
          f"   (frozen: {np.linalg.norm(w_dtd-h_true)/np.linalg.norm(h_true)*100:5.1f}%)")
    print(f"       seg after burst (t=5..6 s) free={post:6.2f} dB")

    print(f"[TIME] total {time.time()-t0:.1f} s")


if __name__ == '__main__':
    main()
