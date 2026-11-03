"""Compare separately prompted ILA speech captures without DC energy bias.

Reports evidence only: proximity speech and channel energy alone cannot
qualify the still-abnormal electrical input or establish physical independence.
"""
import json
from pathlib import Path
import numpy as np
from analyze_pdm_ila import read_csv, col

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/pdm_ila_20261021'
FS = 40000000 / 1024
LABELS = ['acoustic_baseline_20261022', 'acoustic_u1_take1', 'acoustic_u2_take1']


def measure(label):
    windows = []
    for path in sorted(OUT.glob(label + '_pcm*.csv')):
        header, rows = read_csv(path)
        pi, vi, fi = [col(header, k) for k in ('pcm', 'valid', 'frame')]
        x = np.array([[(r[pi] >> (24*k)) & 0xffffff for k in range(8)]
                      for r in rows], dtype=np.int64)
        x[x >= 1 << 23] -= 1 << 24
        frame = np.array([r[fi] for r in rows], dtype=np.int64)
        assert all(r[vi] == 1 for r in rows), path
        assert np.all((np.diff(frame) & 0xffffffff) == 1), path
        w = np.hanning(len(x))
        spectrum = np.fft.rfft((x-x.mean(axis=0))*w[:, None], axis=0)
        freq = np.fft.rfftfreq(len(x), 1/FS)
        mask = (freq >= 300) & (freq <= 3500)
        # Two-sided power for interior positive-frequency bins, normalized
        # by window energy (Parseval); no DC or Nyquist bins in this band.
        rms = np.sqrt(2*np.sum(abs(spectrum[mask])**2, axis=0)/(len(x)*sum(w*w)))
        windows.append(dict(file=path.name, frames=len(x),
                            dc_mean=x.mean(axis=0).tolist(),
                            speech_band_rms=rms.tolist(),
                            speech_dbfs=(20*np.log10(np.maximum(rms, 1e-12)/8388608)).tolist()))
    assert len(windows) == 3, (label, len(windows))
    db = np.array([r['speech_dbfs'] for r in windows])
    return dict(label=label, windows=windows, median_speech_dbfs=np.median(db, axis=0).tolist())


def main():
    stages = [measure(label) for label in LABELS]
    db = np.array([s['median_speech_dbfs'] for s in stages])
    result = dict(sample_rate_hz=FS, band_hz=[300,3500],
                  capture_note='Three separate 8192-frame windows per prompt, not a continuous ten-second recording.',
                  stages=stages, speech_change_from_baseline_db=(db[1:]-db[0]).tolist(),
                  ch0_minus_ch1_db=(db[:,0]-db[:,1]).tolist(),
                  physical_dual_microphone_accepted=False,
                  limitation='Single proximity-speech trial; biased input remains unresolved; no automatic independent-microphone acceptance.')
    (OUT/'acoustic_independence_take1.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    for stage in stages:
        print(stage['label'], 'median band dBFS', [round(v,2) for v in stage['median_speech_dbfs']])
        for window in stage['windows']:
            print(' ',window['file'], 'CH0/1 dBFS', [round(v,2) for v in window['speech_dbfs'][:2]])
    print('speech delta baseline dB',np.round(db[1:]-db[0],2).tolist())
    print('CH0 minus CH1 dB',np.round(db[:,0]-db[:,1],2).tolist())
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(12,5))
    for i, name in enumerate(['Ambient','Near U1','Near U2']):
        ax.bar(np.arange(8)+(i-1)*.25, db[i]+90, bottom=-90, width=.25, label=name)
    ax.set_xticks(np.arange(8), [f'CH{k}' for k in range(8)])
    ax.set_ylabel('300-3500 Hz RMS (dBFS), median of 3 windows')
    ax.set_ylim(min(-90,float(db.min())-5),0)
    ax.set_title('Prompted proximity speech: observed energy, dual-microphone acceptance pending')
    ax.legend();ax.grid(axis='y',alpha=.25);fig.tight_layout()
    fig.savefig(OUT/'acoustic_independence_take1.png',dpi=160)
    plt.close(fig)


if __name__ == '__main__':
    main()
