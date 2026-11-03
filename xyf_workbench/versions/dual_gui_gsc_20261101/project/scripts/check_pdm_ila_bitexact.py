"""Check on-board CIC outputs with an independent finite convolution.

No integrators, comb state, or modular accumulator arithmetic are reused.
Discard the initial unknown-history region and use the exact captured CIC bits.
"""
import argparse
import json
from pathlib import Path
import numpy as np
from analyze_pdm_ila import read_csv, col

ROOT = Path(__file__).resolve().parents[1]
H = np.convolve(np.convolve(np.ones(64,dtype=np.int64),np.ones(64,dtype=np.int64)),np.ones(64,dtype=np.int64))


def pcm_from_bits(bits, consume_index):
    # Registered cascaded integrators and pre-update decimation give z^-3.
    end = consume_index - 3
    if end < len(H)-1:
        return None
    total = int(np.dot(H, np.asarray(bits[end-len(H)+1:end+1][::-1],dtype=np.int64)))
    return max(-8388608,min(8388607,(total-131072)*64))


def check_file(path):
    header, rows = read_csv(path)
    ri=header.index('raw_1[13:4]'); di=header.index('raw[25:16]')
    vi=col(header,'valid'); pi=col(header,'pcm'); fi=col(header,'frame')
    events=[]; bits=[[] for _ in range(8)]; checks=[]
    for row_index,row in enumerate(rows):
        # At tick 15 the CIC integrates the bit_q captured at tick 14.
        # raw_1[13:4] low nibble = A held bits, next nibble = B bit_q.
        if (row[di]&15)==15:
            event=len(events);events.append(row_index)
            for k in range(4):
                bits[2*k].append((row[ri]>>k)&1)
                bits[2*k+1].append((row[ri]>>(k+4))&1)
        if row[vi] == 1:
            if not events:
                continue  # Capture can begin on valid before any input history.
            if events[-1] != row_index-1:
                raise AssertionError(('Unexpected valid/capture phase',path.name,row_index))
            for ch in range(8):
                expected=pcm_from_bits(bits[ch],len(events)-1)
                if expected is None:
                    continue
                observed=(row[pi]>>(24*ch))&0xffffff
                if observed >= 1<<23:observed-=1<<24
                checks.append(dict(row=row_index,frame=row[fi],channel=ch,
                    expected=expected,observed=observed,match=expected==observed))
    if len(checks)<24:raise AssertionError(('Insufficient independent comparisons',path.name,len(checks)))
    mismatches=[c for c in checks if not c['match']]
    # A deliberate one-LSB corruption must be rejected by the same equality criterion.
    negative_detected=(checks[0]['observed']^1) != checks[0]['expected']
    return dict(file=path.name, comparisons=len(checks), mismatches=mismatches,
                negative_control_detected=negative_detected, checks=checks)


def main():
    p=argparse.ArgumentParser();p.add_argument('label');a=p.parse_args()
    out=ROOT/'build/pdm_ila_20261021'
    assert len(H)==190 and int(H.sum())==262144
    assert pcm_from_bits([0]*256,255)==-8388608
    assert pcm_from_bits([1]*256,255)==8388607
    assert pcm_from_bits([0,1]*128,255)==0
    files=sorted(out.glob(a.label+'_raw*.csv'))
    assert files, 'No simultaneous raw+PCM captures'
    results=[check_file(f) for f in files]
    passed=all(not r['mismatches'] and r['negative_control_detected'] for r in results)
    result=dict(label=a.label,method='three length-64 boxcars convolved, length 190; captured input bits; z^-3',
                pass_bitexact=passed,comparisons=sum(r['comparisons'] for r in results),results=results)
    (out/(a.label+'_bitexact.json')).write_text(json.dumps(result,indent=2))
    print('PDM_ILA_BITEXACT_'+('PASS' if passed else 'FAIL'),result['comparisons'])
    for r in results:
        print(r['file'],r['comparisons'],'mismatches',len(r['mismatches']),'negative_control',r['negative_control_detected'])
        if r['mismatches']:print(r['mismatches'][:4])
    if not passed:raise SystemExit(1)


if __name__=='__main__':main()
