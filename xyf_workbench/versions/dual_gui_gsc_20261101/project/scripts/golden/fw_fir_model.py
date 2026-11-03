"""Design and independently evaluate the fixed output FIR (39.0625 kHz)."""
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
TAPS = 32
FS = 39062.5
N = 512


def coefficients():
    t = np.arange(TAPS) - (TAPS - 1) / 2
    h = 2 * 10000 / FS * np.sinc(2 * 10000 / FS * t) * np.hamming(TAPS)
    h /= h.sum()
    q = np.rint(h * 32768).astype(int)
    q[TAPS // 2 - 1] += (32768 - int(q.sum())) // 2
    q[TAPS // 2] += 32768 - int(q.sum())
    return q.tolist()


def sample(n):
    v = ((n + 1) * 1103515245 + 12345) & 0xffffffff
    return ((v >> 16) & 65535) - 32768


def outputs(h):
    x = [sample(n) for n in range(N)]
    return [max(-32768, min(32767, sum(h[k] * x[n-k]
            for k in range(min(n + 1, TAPS))) >> 15)) for n in range(N)]


def main():
    h = coefficients()
    y = outputs(h)
    freq = np.linspace(0, FS / 2, 32769)
    response = np.exp(-2j * np.pi * freq[:, None] / FS * np.arange(TAPS)) @ (np.array(h) / 32768)
    db = 20 * np.log10(np.maximum(abs(response), 1e-15))
    ripple = float(np.ptp(db[(freq >= 200) & (freq <= 8000)]))
    rejection = float(-db[freq >= 12000].max())
    if ripple > 1 or rejection < 40 or sum(abs(v) for v in h) * 32768 >= 2**31:
        raise SystemExit(f'FIR_DESIGN_FAIL ripple={ripple} rejection={rejection}')
    header = '#ifndef FW_FIR_COEFF_H\n#define FW_FIR_COEFF_H\n#include <stdint.h>\n'
    header += '#define FW_FIR_TAPS 32\nstatic const int16_t fw_fir_coeff[32] = {\n'
    header += ', '.join(map(str, h)) + '\n};\n#endif\n'
    (ROOT / 'sw/fw/fw_fir_coeff.h').write_text(header, encoding='ascii')
    (ROOT / 'build').mkdir(exist_ok=True)
    fp = [sum(y) & 0xffffffff, sum((i+1)*v for i, v in enumerate(y)) & 0xffffffff]
    (ROOT / 'build/fw_fir_fp.hex').write_text(''.join(f'{v:08x}\n' for v in fp))
    (ROOT / 'build/fw_fir_y.hex').write_text(''.join(f'{v & 65535:04x}\n' for v in y))
    (ROOT / 'build/fw_fir_coeff.hex').write_text(''.join(f'{v & 65535:04x}\n' for v in h))
    (ROOT / 'build/fir_response.txt').write_text(f'fs={FS} taps={TAPS} passband=200..8000 stopband=12000..19531.25\nripple_db={ripple:.6f} rejection_db={rejection:.6f}\n')
    print(f'FIR_DESIGN_PASS taps={TAPS} ripple_db={ripple:.6f} rejection_db={rejection:.6f} fp={fp}')


if __name__ == '__main__':
    main()
