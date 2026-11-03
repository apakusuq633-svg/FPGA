"""Bit-exact PDM-wire/CIC regression for selectable /16, /32 and legacy /64.

The independent oracle is a convolution of three boxcar FIRs, not the RTL
integrator/comb recurrence. No microphone noise model or board acceptance.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def convolve(a, b):
    out = [0] * (len(a) + len(b) - 1)
    for i, x in enumerate(a):
        for j, y in enumerate(b):
            out[i+j] += x*y
    return out


def vectors(path):
    accum = [0.0] * 10
    rows = []
    for n in range(65536):
        t = n/2500000.0
        # Full-scale rails, alternating zero, ramps and channel-specific tones.
        desired = [-1, 1, 0, .8*(2*((n % 2048)/2047)-1),
                   .65*math.sin(2*math.pi*2400*t),
                   .32*math.sin(2*math.pi*8000*t)+.2*math.sin(2*math.pi*1700*t),
                   .55*math.sin(2*math.pi*600*t+.7),
                   .6*math.sin(2*math.pi*6200*t+1.2),
                   .5*math.sin(2*math.pi*3300*t+2.1), 1]
        word = 0
        for ch, value in enumerate(desired):
            accum[ch] += (value+1)/2
            bit = int(accum[ch] >= 1)
            accum[ch] -= bit
            word |= bit << ch
        rows.append(f'{word:03x}\n')
    path.write_text(''.join(rows), encoding='ascii')


def check_trace(path, decim):
    kernel = convolve(convolve([1]*decim, [1]*decim), [1]*decim)
    assert sum(kernel) == decim**3
    bits, pending, valid_cycles = [], [], []
    comparisons = rails = 0
    for line in path.read_text(encoding='ascii').splitlines():
        fields = line.split()
        if fields[0] == 'BIT':
            bits.append(int(fields[3], 16))
            if int(fields[2]):
                pending.append(len(bits)-1)
        elif fields[0] == 'RAW':
            assert pending, 'PCM without a decimation event'
            end = pending.pop(0)-3  # Three registered integrator delays.
            packed = int(fields[4], 16)
            for ch in range(10):
                total = sum(w*((bits[end-i] >> ch)&1)
                            for i, w in enumerate(kernel) if end-i >= 0)
                expected = (total-decim**3//2)*(2**23//(decim**3//2))
                expected = max(-2**23, min(2**23-1, expected)) if ch < 9 else 0
                actual = (packed >> (24*ch)) & 0xffffff
                if actual & 0x800000:
                    actual -= 1 << 24
                assert actual == expected, (decim, fields[1], ch, actual, expected)
                comparisons += 1
                rails += expected in (-2**23, 2**23-1)
            if int(fields[2]):
                valid_cycles.append(int(fields[1]))
    assert len(valid_cycles) == 1024
    assert all(b-a == 16*decim for a, b in zip(valid_cycles, valid_cycles[1:]))
    assert rails > 1000 and comparisons > 10240
    return dict(comparisons=comparisons, valid_samples=len(valid_cycles),
                valid_period_cycles=16*decim,
                first_to_1024th_sample_ms=(valid_cycles[-1]-valid_cycles[0])/40000,
                window_budget_ms=1024*decim/2500, rail_comparisons=rails)


def response_db(f, decim):
    ratio=abs(math.sin(math.pi*f*decim/2500000)/(decim*math.sin(math.pi*f/2500000)))
    return 60*math.log10(ratio)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT/'build/pdm_decim16_checks')
    args=parser.parse_args()
    out=args.output.resolve();out.mkdir(parents=True, exist_ok=True)
    iverilog=shutil.which('iverilog');vvp=shutil.which('vvp')
    if not iverilog or not vvp:
        raise RuntimeError('iverilog and vvp are required')
    inputs=[ROOT/'rtl/array'/n for n in ('rv32_pdm_clkgen.v','rv32_pdm_cic.v','rv32_pdm_array_rx.v')]
    inputs.append(ROOT/'tb/tb_pdm_decim_rate.v')
    stimulus=out/'pdm.hex';vectors(stimulus)
    results={'hardware_tested':False,'pdm_clock_hz':2500000,'clock_hz':40000000,
             'oracle':'independent triple-boxcar convolution',
             'source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
             'rates':{}}
    for decim in (16,32,64):
        exe=out/f'd{decim}.vvp';trace=out/f'd{decim}.txt'
        command=[iverilog,'-g2012','-s','tb_pdm_decim_rate','-P',f'tb_pdm_decim_rate.DECIM={decim}',
                 '-o',str(exe),*map(str,inputs)]
        subprocess.run(command,cwd=ROOT,check=True)
        run=subprocess.run([vvp,str(exe),f'+INPUT={stimulus.relative_to(ROOT).as_posix()}',f'+OUTPUT={trace.relative_to(ROOT).as_posix()}'],
                           cwd=ROOT,check=True,capture_output=True,text=True,timeout=180)
        (out/f'd{decim}.log').write_text(run.stdout+run.stderr,encoding='utf-8')
        assert 'PDM_DECIM_PASS' in run.stdout
        row=check_trace(trace,decim)
        row.update(sample_rate_hz=2500000/decim,cic_at_8000_hz_db=response_db(8000,decim),
                   first_alias_lower_edge_8000_hz_db=response_db(2500000/decim-8000,decim),
                   passed=True)
        results['rates'][str(decim)]=row
        print(run.stdout.strip(),f'golden_comparisons={row["comparisons"]}',flush=True)
    (out/'results.json').write_text(json.dumps(results,indent=2)+'\n',encoding='utf-8')
    print('PDM_DECIM16_SUITE_PASS board_tested=0')


if __name__ == '__main__':
    main()
