#!/usr/bin/env python3
"""Independent analytic AM golden, low-speed order separation and native cost checks."""
import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/circular9_envelope_checks"
FS, EFS, NS, NFFT = 39062.5, 39062.5 / 16, 2500, 4096
ORDERS = (0.3975806451612903, 2.338525527051054, 3.578225806451613, 5.421774193548387)


def waveform(carrier, mods=(), dc=0.0):
    return [dc + 0.15 * (1 + sum(depth * math.cos(2 * math.pi * hz * i / FS + phase)
                                 for hz, depth, phase in mods)) *
            math.cos(2 * math.pi * carrier * i / FS + 0.37) for i in range(40000)]


def ideal_spectrum(mods):
    # Direct DFT of the known analytic envelope, independent of production FFT/FIR.
    w = [0.5 - 0.5 * math.cos(2 * math.pi * i / (NS - 1)) for i in range(NS)]
    env = [0.15 * (1 + sum(d * math.cos(2 * math.pi * h * i / EFS + p)
                           for h, d, p in mods)) for i in range(NS)]
    total = sum(w)
    mean = sum(a * b for a, b in zip(env, w)) / total
    centered = [(a - mean) * b for a, b in zip(env, w)]
    def at(k):
        z = sum(x * complex(math.cos(-2 * math.pi * k * i / NFFT),
                            math.sin(-2 * math.pi * k * i / NFFT))
                for i, x in enumerate(centered))
        return 2 * abs(z) / total
    return at


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    gcc = shutil.which("gcc")
    if not gcc:
        raise RuntimeError("GCC required")
    legacy = OUT / "legacy_benchmark.c"
    legacy.write_text('''#include "ps_features.h"
#include "bearing_6004_2zr.h"
void c9_legacy_benchmark(const double *x,double hz,double v[18]){
 static int ready;if(!ready){fea_setup(39062.5,1400,4600);ready=1;}
 fea_frame18_orders(x,40000,hz,bearing6004_orders,v);fea_norm18(v);
}''', encoding="utf-8")
    exe = OUT / "envelope.exe"
    subprocess.run([gcc, "-std=c99", "-O2", "-Isw", "sw/circular9_envelope_test.c",
                    str(legacy), "-lm", "-o", str(exe)], cwd=ROOT, check=True)
    reports = {}
    def run(name, audio, shaft=10):
        data = array.array("d", audio)
        if sys.byteorder != "little":
            data.byteswap()
        source = OUT / (name + ".f64le")
        source.write_bytes(data.tobytes())
        r = json.loads(subprocess.check_output([str(exe), str(source), str(shaft)], cwd=ROOT))
        assert r["samples"] == 2500 and r["fft_count"] == 1 and r["fft_size"] == 4096
        assert abs(r["observation_seconds"] - 1.024) < 1e-14
        assert abs(r["bin_spacing_hz"] - 0.59604644775390625) < 1e-14
        assert r["enbw_hz"] > 1.46 and r["first_null_hz"] > 1.95
        assert all(math.isfinite(v) for v in r["features"] + r["spectrum"])
        reports[name] = {k: v for k, v in r.items() if k != "spectrum"}
        return r
    # Independent known envelopes cover min/max RPM and all mechanical feature frequencies.
    for shaft in (10, 30):
        mods = [(ORDERS[0] * shaft, .12, .2), (shaft, .04, -.3),
                (4 * ORDERS[3] * shaft, .08, .4)]
        r = run(f"am_{shaft}hz", waveform(3400, mods), shaft)
        assert r["status"] == 1
        reference = ideal_spectrum(mods)
        bins = {k for h, _, _ in mods for k in range(round(h / (EFS / NFFT)) - 2,
                                                      round(h / (EFS / NFFT)) + 3)}
        error = max(abs(r["spectrum"][k] - reference(k)) for k in bins)
        assert error < 2e-4, (shaft, error)
        reports[f"am_{shaft}hz"]["independent_am_max_amplitude_error"] = error
    # At 600rpm: FTF~3.976Hz and shaft10Hz must remain distinct, with no DC search.
    low = ORDERS[0] * 10
    ftf = run("only_ftf_600rpm", waveform(3400, [(low, .2, 0)]))
    shaft = run("only_shaft_600rpm", waveform(3400, [(10, .2, 0)]))
    def peak(r, hz):
        df = EFS / NFFT
        half_width = max(1 / 1.024, .01 * hz)
        return max(r["spectrum"][max(1, math.ceil((hz - half_width) / df)):
                                  math.floor((hz + half_width) / df) + 1])
    assert peak(ftf, low) > 100 * peak(ftf, 10)
    assert peak(shaft, 10) > 100 * peak(shaft, low)
    target = 4 * ORDERS[3] * 30
    inside = run("order_offset_inside_0p8_percent", waveform(3400, [(target * 1.008, .1, 0)]), 30)
    outside = run("order_offset_outside_2p5_percent", waveform(3400, [(target * 1.025, .1, 0)]), 30)
    assert peak(inside, target) > .01
    assert peak(outside, target) < .01 * peak(inside, target)
    for freq in (2200, 2600, 4200, 4600):
        r = run(f"carrier_edge_{freq}", waveform(freq, [(10, .1, 0)]))
        assert r["status"] == 1 and peak(r, 10) > .005
    # DC offsets must not contaminate the low-order envelope peaks.
    plain = run("dc_plain", waveform(3400, [(low, .2, 0)]))
    dc = run("dc_offset", waveform(3400, [(low, .2, 0)], dc=.4))
    assert abs(peak(plain, low) - peak(dc, low)) < 2e-5
    tone = run("unmodulated_tone", waveform(3400))
    assert tone["status"] == 3 and peak(tone, low) < 1e-5 and peak(tone, 10) < 1e-5
    silence = run("silence", [0.0] * 40000)
    assert silence["status"] == 2 and not any(silence["features"])
    constant = run("constant_dc", [.4] * 40000)
    assert constant["status"] == 2 and peak(constant, low) < 1e-10
    # Two in-band carriers beat at1900Hz; without envelope anti-alias this folds to541.4Hz.
    beating = [.1 * math.cos(2 * math.pi * 2500 * i / FS) +
               .07 * math.cos(2 * math.pi * 4400 * i / FS + .2) for i in range(40000)]
    alias = run("envelope_alias_rejection", beating, 30)
    assert peak(alias, abs(EFS - 1900)) < 1e-5
    for name, index in (("first_sample_impulse", 0), ("last_sample_impulse", 39999)):
        impulse = [0.0] * 40000
        impulse[index] = .8
        r = run(name, impulse)
        assert peak(r, low) < 2e-6
    representative = reports["am_10hz"]
    result = {"passed": True, "evidence_scope": "synthetic_analytic_am_and_native_timing_only",
              "real_machine_model_validated": False, "feature_contract": 0x43394632,
              "old_fft_count": 24, "old_fft_size": 8192,
              "new_fft_count": 1, "new_fft_size": 4096,
              "new_fir_multiplications": representative["fir_multiplications"],
              "host_speedup": representative["host_legacy_ms"] / max(representative["host_new_ms"], .001),
              "arm_timing_measured": False, "cases": reports,
              "source_sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in
                                ("sw/circular9_envelope.h", "sw/circular9_envelope_test.c",
                                 "scripts/check_circular9_envelope.py")}}
    (OUT / "results.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("CIRCULAR9_ENVELOPE_PASS full_record_1.024s low_ftf_vs_shaft host_speedup=%.2f no_ARM_timing" % result["host_speedup"])


if __name__ == "__main__":
    main()
