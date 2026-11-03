"""Analyze exported Vivado ILA samples, retaining limits of physical evidence."""
import argparse
import csv
import json
import re
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def read_csv(path):
    with path.open(encoding='utf-8-sig', newline='') as f:
        rows = list(csv.reader(f))
    header, radix = rows[:2]
    values = []
    for row in rows[2:]:
        if not row or not row[0].strip().isdigit():
            continue
        values.append([int(v.strip(), {'HEX':16, 'BIN':2, 'UNSIGNED':10,
            'SIGNED':10}.get(radix[i].strip().upper().removeprefix('RADIX - '), 16)) for i, v in enumerate(row)])
    return header, values


def col(header, key):
    found = [i for i, s in enumerate(header) if re.sub(r'_\d+$','',s.split('[')[0].split('/')[-1]) == key]
    if len(found) != 1:
        raise ValueError((key, header))
    return found[0]


def analyze(label, clock_hz=40000000):
    out = ROOT/'build/pdm_ila_20261021'
    header, rows = read_csv(out/f'{label}_raw.csv')
    # Vivado splits the raw bus at aliased nets in the exported probe metadata.
    raw = np.array([r[header.index('pdm_din_i_IBUF[3:0]')] |
        (r[header.index('raw_1[13:4]')] << 4) |
        (r[header.index('valid')] << 14) |
        (r[header.index('pdm_clk_o_OBUF')] << 15) |
        (r[header.index('raw[25:16]')] << 16) for r in rows], dtype=np.int64)
    div = raw >> 16
    din = raw & 15
    a = (raw >> 4) & 15
    b = (raw >> 8) & 15
    hold = ((raw >> 12) & 1).astype(bool)
    consume = ((raw >> 13) & 1).astype(bool)
    hold_tick = int(np.unique(div[hold] & 15).item())
    consume_tick = int(np.unique(div[consume] & 15).item())
    raw_report = dict(samples=len(raw),
        divider_errors=int(np.sum(((np.diff(div)) & 1023) != 1)),
        clock_errors=int(np.sum(((raw >> 15)&1) != ((div >> 3)&1))),
        hold_tick_errors=int(np.sum(hold != ((div & 15)==hold_tick))),
        consume_tick_errors=int(np.sum(consume != ((div & 15)==consume_tick))),
        phase_a_latch_errors=int(np.sum(a[1:][hold[:-1]] != din[:-1][hold[:-1]])),
        phase_b_input_ff_errors=int(np.sum(b[1:][consume[:-1]] != din[:-1][consume[:-1]])),
        phase_offset_ns=8e9/clock_hz, sample_after_edge_ns=(hold_tick+1)*1e9/clock_hz,
        pl_clock_hz=clock_hz, pdm_clock_hz=clock_hz/16)
    pairs = []
    for k in range(4):
        abit = (a[consume] >> k) & 1
        bbit = (din[consume] >> k) & 1
        n = min(len(abit),len(bbit))
        pairs.append(dict(line=k, a_ones=float(abit.mean()), b_ones=float(bbit.mean()),
            unequal_fraction=float(np.mean(abit[:n] != bbit[:n]))))
    raw_report['line_phases'] = pairs
    raw_report['ones_by_tick'] = [
        [float(np.mean((din[(div & 15)==tick] >> k)&1)) for tick in range(16)]
        for k in range(4)]
    raw_report['transitions_by_tick'] = [
        [int(np.sum((((din[1:] >> k) ^ (din[:-1] >> k))&1)[(div[1:]&15)==tick]))
         for tick in range(16)] for k in range(4)]
    captures = []
    arrays = []
    for path in sorted(out.glob(f'{label}_pcm*.csv')):
        header, rows = read_csv(path)
        pi, vi, fi, zi = [col(header,k) for k in ('pcm','valid','frame','frozen')]
        pcm = np.array([[(r[pi] >> (24*k)) & 0xffffff for k in range(8)] for r in rows], dtype=np.int64)
        pcm[pcm >= (1<<23)] -= (1<<24)
        arrays.append(pcm)
        frame = np.array([r[fi] for r in rows], dtype=np.int64)
        channels = []
        for k in range(8):
            x = pcm[:,k]
            channels.append(dict(channel=k, minimum=int(x.min()),maximum=int(x.max()),
                peak_to_peak=int(np.ptp(x)), mean=float(x.mean()), ac_rms=float(x.std()),
                unique=int(len(np.unique(x))), clipped=int(np.sum((x == -8388608)|(x == 8388607)))))
        captures.append(dict(file=path.name, samples=len(rows),
            invalid_rows=sum(r[vi] != 1 for r in rows),
            frame_gap_errors=int(np.sum((np.diff(frame)&0xffffffff) != 1)),
            frozen_values=sorted(set(r[zi] for r in rows)),channels=channels,
            same_line_equal_fraction=[float(np.mean(pcm[:,2*k] == pcm[:,2*k+1])) for k in range(4)],
            same_line_correlation=[float(np.corrcoef(pcm[:,2*k],pcm[:,2*k+1])[0,1]) if np.std(pcm[:,2*k]) and np.std(pcm[:,2*k+1]) else None for k in range(4)]))
    assert captures, 'No PCM captures'
    errors = sum(v for k,v in raw_report.items() if k.endswith('_errors'))
    errors += sum(c['invalid_rows']+c['frame_gap_errors'] for c in captures)
    result = dict(label=label, raw=raw_report, pcm=captures,
        digital_transport_pass=errors==0,
        physical_independent_microphones_verified=False,
        limitation='Digital capture cannot measure VCCO, analog signal integrity, or prove independent acoustic response without controlled sound.')
    (out/f'{label}_analysis.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    # Plot each physical DATA pair; all channels keep the same amplitude scale.
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(5,1,figsize=(13,7),sharex=True)
        n=min(256,len(raw));us=np.arange(n)*1e6/clock_hz
        axes[0].step(us,((raw[:n]>>15)&1),where='post',label='PDM CLK')
        axes[0].set_ylabel('CLK')
        for k in range(4):
            ax=axes[k+1]
            ax.step(us,(din[:n]>>k)&1,where='post',lw=1)
            for mask,color,name in ((hold[:n],'green','A capture'),(consume[:n],'red','B capture')):
                ix=np.flatnonzero(mask)
                ax.scatter(us[ix],(din[ix]>>k)&1,s=20,c=color,label=name)
            ax.set_ylabel(f'DATA{k}');ax.set_ylim(-.2,1.2)
        axes[-1].legend(loc='upper right');axes[-1].set_xlabel(f'Time (us), ILA {clock_hz/1e6:g} MHz')
        fig.suptitle(f'On-board raw PDM: {label}, sample after edge {raw_report["sample_after_edge_ns"]} ns')
        fig.tight_layout();fig.savefig(out/f'{label}_raw.png',dpi=150);plt.close(fig)
        fig, axes = plt.subplots(4,1,figsize=(13,10),sharex=True,sharey=True)
        data=arrays[0]
        ms=np.arange(len(data))/(clock_hz/1024)*1000
        for k,ax in enumerate(axes):
            for c in (2*k,2*k+1):
                ax.plot(ms,data[:,c],lw=.6,label=f'CH{c}')
            ax.legend(loc='upper right');ax.set_ylabel(f'DATA{k} PCM');ax.grid(alpha=.2)
        axes[-1].set_xlabel(f'Time (ms), PCM {clock_hz/1024:g} Hz')
        fig.suptitle(f'On-board ILA: {label}, independent acoustic response pending')
        fig.tight_layout();fig.savefig(out/f'{label}_pcm.png',dpi=150);plt.close(fig)
    except ImportError:
        pass
    print(json.dumps(result,indent=2))


if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('label',nargs='?',default='baseline')
    p.add_argument('--clock-hz',type=int,default=40000000)
    args=p.parse_args();analyze(args.label,args.clock_hz)
