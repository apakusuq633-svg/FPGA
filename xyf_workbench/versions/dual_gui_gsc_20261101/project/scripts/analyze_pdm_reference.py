"""Analyze the original reference acquisition plus passive trace registers."""
import argparse
import json
from pathlib import Path
import numpy as np
from analyze_pdm_ila import read_csv

OUT = Path(__file__).resolve().parents[1]/'build/pdm_ila_20261021'


def one(header, predicate):
    found = [i for i, name in enumerate(header) if predicate(name)]
    if len(found) != 1:
        raise ValueError((header, found))
    return found[0]


def analyze_raw(path):
    header, rows = read_csv(path)
    pi = one(header, lambda n: 'ref_trace' in n)
    trace = [r[pi] for r in rows]
    raw = [t & ((1 << 64)-1) for t in trace]
    cycles = [r >> 32 for r in raw]
    clocks = [r >> 4 & 1 for r in raw]
    bits = [[] for _ in range(8)]
    events = []
    checks = []
    latch_disagreements = []
    edge_intervals = np.diff([i for i in range(1,len(raw)) if clocks[i]!=clocks[i-1]])
    # Independent sinc^3 FIR for DECIM=16, registered integrator z^-3.
    kernel = np.convolve(np.convolve(np.ones(16,dtype=np.int64),np.ones(16,dtype=np.int64)),np.ones(16,dtype=np.int64))
    assert len(kernel)==46 and int(kernel.sum())==4096
    assert int(np.dot(kernel,np.tile([0,1],23)))==2048
    transitions = [[0,0] for _ in range(4)]
    for i, value in enumerate(raw):
        if i:
            changed = (value ^ raw[i-1]) & 15
            for line in range(4):
                transitions[line][clocks[i]] += (changed >> line) & 1
        # Next-cycle input FF contains the actual B bit captured on consume.
        if i and (raw[i-1] >> 6 & 1):
            events.append(i)
            for line in range(4):
                bits[2*line].append(value >> (10+line) & 1)
                bits[2*line+1].append(value >> (14+line) & 1)
            observed = value >> 14 & 15
            probed = raw[i-1] & 15
            if observed != probed:
                latch_disagreements.append(dict(row=i, observed=observed, probed=probed))
        if value >> 7 & 1 and events:
            if events[-1] != i-1:
                raise AssertionError(('PCM valid event phase',path.name,i,events[-1]))
            end = len(events)-1-3
            if end < len(kernel)-1:
                continue
            for channel in range(8):
                total = int(np.dot(kernel,np.array(bits[channel][end-len(kernel)+1:end+1][::-1],dtype=np.int64)))
                expected = max(-32768,min(32767,(total-2048)*16))
                actual = trace[i] >> (96+channel*16) & 65535
                if actual >= 32768:
                    actual -= 65536
                checks.append(dict(row=i,channel=channel,expected=expected,actual=actual,match=actual==expected))
    assert checks, ('No comparisons', path)
    return dict(file=path.name, samples=len(raw), consume_events=len(events),
        cycle_gaps=sum(((b-a)&0xffffffff)!=1 for a,b in zip(cycles,cycles[1:])),
        clock_half_period_cycles=sorted(set(map(int,edge_intervals))),
        line_phases=[dict(line=k,a_ones=float(np.mean(bits[2*k])),b_ones=float(np.mean(bits[2*k+1])),unequal_fraction=float(np.mean(np.array(bits[2*k])!=bits[2*k+1])),transitions_clock_low=transitions[k][0],transitions_clock_high=transitions[k][1]) for k in range(4)],
        input_probe_disagreements=latch_disagreements, comparisons=len(checks),
        mismatches=[c for c in checks if not c['match']],
        corrupted_output_negative_detected=(checks[0]['actual']^1)!=checks[0]['expected'])


def analyze_pcm(path):
    header, rows = read_csv(path)
    pi = one(header, lambda n:n.endswith('[127:0]'))
    fi = one(header, lambda n:'frame' in n and n.endswith('[31:0]'))
    vi = one(header, lambda n:'valid' in n)
    x = np.array([[(r[pi]>>(16*k))&65535 for k in range(8)] for r in rows],dtype=np.int64)
    x[x>=32768]-=65536
    frame = [r[fi] for r in rows]
    return dict(file=path.name,frames=len(rows),invalid=sum(r[vi]!=1 for r in rows),
        frame_gaps=sum(((b-a)&0xffffffff)!=1 for a,b in zip(frame,frame[1:])),
        channels=[dict(channel=k,mean=float(x[:,k].mean()),mean_full_scale=float(x[:,k].mean()/32768),ac_rms=float(x[:,k].std()),minimum=int(x[:,k].min()),maximum=int(x[:,k].max())) for k in range(8)],
        pair_equal_fraction=[float(np.mean(x[:,2*k]==x[:,2*k+1])) for k in range(4)])


def main():
    p=argparse.ArgumentParser();p.add_argument('label');args=p.parse_args()
    raw=[analyze_raw(f) for f in sorted(OUT.glob(args.label+'_raw*.csv'))]
    pcm=[analyze_pcm(f) for f in sorted(OUT.glob(args.label+'_pcm*.csv'))]
    assert raw and pcm
    result=dict(label=args.label,reference='Neighbor PDM_48K original acquisition RTL; screenshot identity unconfirmed',
        pdm_hz=768000,pcm_hz=48000,pcm_width=16,raw=raw,pcm=pcm,
        arithmetic_bitexact_pass=all(not r['mismatches'] and r['corrupted_output_negative_detected'] for r in raw),
        physical_dual_microphone_accepted=False)
    (OUT/(args.label+'_analysis.json')).write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('REFERENCE_ARITHMETIC',result['arithmetic_bitexact_pass'],'comparisons',sum(r['comparisons'] for r in raw))
    for r in raw: print(r['file'],'phases',r['line_phases'],'mismatches',len(r['mismatches']))
    for r in pcm: print(r['file'],'normalized means',[round(c['mean_full_scale'],4) for c in r['channels']],'pairs equal',r['pair_equal_fraction'])
    if not result['arithmetic_bitexact_pass']:raise SystemExit(1)


if __name__=='__main__':main()
