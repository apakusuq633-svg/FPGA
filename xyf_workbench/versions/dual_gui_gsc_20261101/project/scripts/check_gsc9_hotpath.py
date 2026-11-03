"""Exact shared division and target-protection tests; no ARM timing claim."""
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
from check_gsc9 import frontend, trunc, clip

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/gsc9_hotpath_checks'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy();env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH']
    result = subprocess.run(['gcc', '-shared', '-O2', '-Wall', '-Wextra', '-Werror', '-DGSC9_TEST',
                             'sw/gsc9.c', '-o', str(OUT/'gsc9.dll')], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (OUT/'compile.log').write_text(result.stdout)
    if result.returncode:raise RuntimeError(result.stdout)
    dllpath = os.add_dll_directory('C:/msys64/ucrt64/bin') if hasattr(os, 'add_dll_directory') else None
    lib = C.CDLL(str(OUT/'gsc9.dll'));lib.gsc9_state_size.restype = C.c_size_t
    class Config(C.Structure):
        _fields_ = [('version', C.c_uint32), ('epoch', C.c_uint32), ('direction_id', C.c_uint16),
                    ('mu_q15', C.c_uint16), ('epsilon', C.c_uint32), ('delay_q16', C.c_uint32*9),
                    ('fir_q15', C.c_int16*32)]
    assert C.sizeof(Config) == 116, 'existing CTypes configuration ABI changed'
    lib.gsc9_test_divide_batch.argtypes = [C.POINTER(C.c_int64), C.c_uint64, C.POINTER(C.c_int64)]
    rng = random.Random(20261025)
    divisors = sorted({1, 3, (1 << 35)+(1 << 30)} | {max(1, (1 << b)+d) for b in range(36) for d in (-1, 0, 1)})
    divisors += [rng.randrange(1, (1 << 35)+(1 << 30)+1) for _ in range(32768)]
    compared = 0;bound = 1 << 44
    for d in divisors:
        numerators = [0, 1, -1, bound, -bound, d, -d, d-1, 1-d]
        for _ in range(23):
            q = rng.randrange(0, bound//d+1)
            n = min(bound, q*d+rng.choice([0, 1, d-1]))
            numerators.append(-n if rng.getrandbits(1) else n)
        input_ = (C.c_int64*32)(*numerators);output = (C.c_int64*32)()
        lib.gsc9_test_divide_batch(input_, d, output)
        expected = [trunc(n, d) for n in numerators]
        assert list(output) == expected, (d, numerators, list(output), expected)
        compared += 32
    lib.gsc9_configure.argtypes = [C.c_void_p, C.POINTER(Config)]
    lib.gsc9_process.argtypes = [C.c_void_p, C.POINTER(C.c_uint32), C.c_int, C.c_int]
    lib.gsc9_process.restype = C.c_int16
    lib.gsc9_set_target_guard.argtypes = [C.c_void_p, C.c_int]
    lib.gsc9_target_guard_status.argtypes = [C.c_void_p];lib.gsc9_target_guard_status.restype = C.c_uint32
    lib.gsc9_target_coherence_q15.argtypes = [C.c_void_p];lib.gsc9_target_coherence_q15.restype = C.c_uint32
    lib.gsc9_stat.argtypes = [C.c_void_p, C.c_uint];lib.gsc9_stat.restype = C.c_uint64
    lib.gsc9_reason.argtypes = [C.c_void_p];lib.gsc9_reason.restype = C.c_uint32
    lib.gsc9_get_weights.argtypes = [C.c_void_p, C.POINTER(C.c_int32)]
    identity = [32767]+[0]*31;delays = [0]*9
    config = Config(1, 0, 7, 8192, 1 << 20, (C.c_uint32*9)(*delays), (C.c_int16*32)(*identity))
    def state(enabled):
        s = C.create_string_buffer(lib.gsc9_state_size());assert lib.gsc9_configure(s, C.byref(config)) == 0
        lib.gsc9_set_target_guard(s, enabled);assert lib.gsc9_target_guard_status(s) == int(bool(enabled))
        return s
    def packets(raw):
        das, beam, refs = frontend(raw, delays, identity)
        words = []
        for n, row in enumerate(raw):
            w = [0]*16;w[0] = 0x47534302;w[1] = n;w[2] = 1;w[5] = 65536;w[6] = (7 << 8)|1
            w[7] = (das[n] & 65535)|((beam[n] & 65535) << 16);w[13] = 0x000a0009
            for ch, value in enumerate(row):w[8+ch//2] |= (value & 65535) << (16*(ch%2))
            words.append((C.c_uint32*16)(*w))
        return words, beam, refs
    def run(raw, enabled):
        s = state(enabled);words, beam, refs = packets(raw)
        out = [int(lib.gsc9_process(s, w, 1, 0)) for w in words]
        return s, out, beam, refs
    def gain(output, reference, first=4096):
        return 10*math.log10(sum(x*x for x in output[first:])/sum(x*x for x in reference[first:]))
    length = 12288
    target = [int(1100*math.sin(2*math.pi*3000*n/156250)) for n in range(length)]
    leak = [[int(value*(1+.12*math.cos(ch*math.pi/4) if ch < 8 else 1.02)) for ch in range(9)] for value in target]
    protected, out, beam, _ = run(leak, 1)
    ordinary, unprotected, _, _ = run(leak, 0)
    assert out[1024:] == beam[1024:], 'guarded coherent target was cancelled'
    assert lib.gsc9_stat(protected, 18) >= 1 and lib.gsc9_stat(protected, 19) > 0
    assert lib.gsc9_reason(protected) == 8 and lib.gsc9_target_guard_status(protected) == 3
    assert lib.gsc9_target_coherence_q15(protected) > 31000
    loss = gain(unprotected, beam)
    assert loss < -1, ('negative control did not contain meaningful self-cancellation', loss)
    angle = math.radians(3)
    mispointed = [[int(1000*math.sin(2*math.pi*3000*(n/156250+(.03*(math.cos(ch*math.pi/4) if ch < 8 else 0)-.03)*math.sin(angle)/343))) for ch in range(9)] for n in range(length)]
    mispoint_state, mispoint_out, mispoint_beam, _ = run(mispointed, 1)
    assert mispoint_out[1024:] == mispoint_beam[1024:] and lib.gsc9_stat(mispoint_state, 18) > 0, 'three-degree real plane-wave mismatch was cancelled'
    # Common impact envelope, deliberately leaked by calibration-style gain
    # errors. Exact matched-DAS samples imply exact envelope/impulse retention
    # relative to that baseline, not a claim about real bearing classification.
    impacts = [int(1000*(.2+math.exp(-(n % 3125)/45))*math.sin(2*math.pi*3000*n/156250)) for n in range(length)]
    impulse_raw = [[int(value*(1+.10*math.cos(ch*math.pi/4) if ch < 8 else 1.01)) for ch in range(9)] for value in impacts]
    impact_state, impact_out, impact_beam, _ = run(impulse_raw, 1)
    assert impact_out[1024:] == impact_beam[1024:] and lib.gsc9_stat(impact_state, 18) > 0
    # An ideal spatially identical target has no blocking leakage and never
    # triggers the optional protection. It remains exactly preserved.
    clean, clean_out, clean_beam, _ = run([[v]*9 for v in target], 1)
    assert clean_out == clean_beam and lib.gsc9_stat(clean, 18) == 0
    target_rows = [[int(900*math.sin(2*math.pi*3000*n/156250))]*9 for n in range(length)]
    interference = [[int((1+.6*math.cos(ch*math.pi/4) if ch < 8 else 1)*
                         (1100*math.sin(2*math.pi*2200*n/156250)+800*math.sin(2*math.pi*4700*n/156250))) for ch in range(9)] for n in range(length)]
    mixture = [[a+b for a, b in zip(t, v)] for t, v in zip(target_rows, interference)]
    learned, _, _, _ = run(mixture, 1)
    assert lib.gsc9_stat(learned, 1) > 4096, 'unrelated spatial interference cannot adapt'
    weights = (C.c_int32*32)();lib.gsc9_get_weights(learned, weights)
    assert any(weights)
    def component(raw):
        _, baseline, refs = frontend(raw, delays, identity)
        output = [clip(y-sum(weights[ch*4+t]*refs[n-4*t][ch] for ch in range(8) for t in range(4) if n >= 4*t)//32768) for n, y in enumerate(baseline)]
        return sum(y*y for y in baseline[4096:]), sum(y*y for y in output[4096:])
    ti, to = component(target_rows);ni, no = component(interference)
    sir_gain = 10*math.log10((to/no)/(ti/ni));target_gain = 10*math.log10(to/ti)
    assert sir_gain >= 3 and abs(target_gain) <= .1, (sir_gain, target_gain)
    transition, _, _, _ = run(leak[:4096]+mixture[4096:], 1)
    assert lib.gsc9_stat(transition, 18) > 0 and lib.gsc9_stat(transition, 20) > 0
    assert lib.gsc9_configure(transition, C.byref(config)) == 0 and lib.gsc9_target_guard_status(transition) == 1
    lib.gsc9_set_target_guard(transition, 0);assert lib.gsc9_target_guard_status(transition) == 0
    evidence = {'passed': True, 'hardware_tested': False, 'arm_runtime_measured': False,
                'fixture': 'independent integer frontend plus explicit synthetic target leakage/impact envelope/spatially varying interference; not real fault recordings',
                'exact_division_comparisons': compared, 'division_max_error': 0,
                'config_abi_bytes': C.sizeof(Config), 'guarded_target_gain_db': gain(out, beam),
                'three_degree_mispoint_samples_equal_matched_das': True,
                'unguarded_leak_target_gain_db': loss, 'impact_samples_equal_matched_das': True,
                'guarded_unrelated_scene_sir_gain_db': sir_gain, 'unrelated_scene_target_gain_db': target_gain,
                'guard_activation_events': int(lib.gsc9_stat(protected, 18)),
                'sources': {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in
                            ['sw/gsc9.c', 'sw/gsc9.h', 'scripts/check_gsc9_hotpath.py', 'scripts/check_gsc9.py']}}
    (OUT/'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print('GSC9_HOTPATH_PASS '+json.dumps({k: evidence[k] for k in ('exact_division_comparisons', 'unguarded_leak_target_gain_db', 'guarded_unrelated_scene_sir_gain_db')}))


if __name__ == '__main__':main()
