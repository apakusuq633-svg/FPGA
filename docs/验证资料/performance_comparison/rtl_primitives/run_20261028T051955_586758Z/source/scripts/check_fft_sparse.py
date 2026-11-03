#!/usr/bin/env python3
"""Sparse inverse FFT vs full input and scalar firmware, without NumPy.

All generated inputs, scalar goldens, ROM and logs stay below build/fft_sparse.
The test does not modify FFT RTL or shared generated firmware tables.
"""
import ctypes
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "fft_sparse"
CASES, STRIDE = 12, 513


def words(values):
    return [(values[k] & 65535) | ((values[k+1] & 65535) << 16)
            for k in range(0, len(values), 2)]


def emit(path, values):
    path.write_text("".join(f"{value:08x}\n" for value in values), encoding="ascii")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    gcc, iverilog, vvp = (shutil.which(name) for name in ("gcc", "iverilog", "vvp"))
    if not all((gcc, iverilog, vvp)):
        raise SystemExit("gcc, iverilog and vvp must be on PATH")
    library = OUT / ("golden.dll" if os.name == "nt" else "golden.so")
    subprocess.run([gcc, "-O2", "-shared", "-fPIC", "-fwrapv", "-DFW_ACCEL=0",
                    "-I", str(ROOT / "sw/fw"), str(ROOT / "sw/fw/fw_fft.c"),
                    str(ROOT / "sw/fw/fw_tables.c"), "-o", str(library)], check=True, cwd=ROOT)
    model = ctypes.CDLL(str(library))
    input_type, output_type = ctypes.c_int16 * 1026, ctypes.c_int16 * 1026
    model.fft_init()
    model.fft1024.argtypes = [ctypes.POINTER(ctypes.c_int16), ctypes.POINTER(ctypes.c_int16)]
    model.ifft512_real.argtypes = model.fft1024.argtypes
    # Reuse the exact compiled scalar Q14 constants, independent of float math.
    re_table = (ctypes.c_int16 * 513).in_dll(model, "g_tw_re")
    im_table = (ctypes.c_int16 * 513).in_dll(model, "g_tw_im")
    emit(OUT / "twiddle.hex", [(re_table[i] & 65535) | ((im_table[i] & 65535) << 16)
                              for i in range(512)])
    rng = random.Random(0x60041664)
    vector_words, golden_words = [], []
    for case in range(CASES):
        mode = case % 3
        count = 1024 if mode == 2 else 1026
        samples = [rng.randrange(-32768, 32768) for _ in range(count)]
        # Exercise signed extremes and both ends of the loaded band explicitly.
        for index in (4, 5, 6, 7, 128, 129, 130, 131):
            samples[index] = -32768 if (index+case) % 2 else 32767
        if mode == 0:
            samples[:4] = [0] * 4
            samples[132:] = [0] * (len(samples)-132)
        elif mode == 1:
            samples[0:2] = [-32768 if case % 2 else 32767, 0]
            samples[1024:1026] = [32767 if case % 2 else -32768, 0]
        else:
            samples[0:4] = [-32768, 32767, 32767, -32768]
        source = input_type(*samples)
        expected = output_type()
        if mode == 2:
            model.fft1024(source, expected)
            result = words(expected)
        else:
            model.ifft512_real(source, expected)
            result = words(expected[:1024])
        packed = words(samples)
        vector_words.extend(packed + [0] * (STRIDE-len(packed)))
        golden_words.extend(result + [0] * (STRIDE-len(result)))
    emit(OUT / "input.hex", vector_words)
    emit(OUT / "golden.hex", golden_words)
    exe = OUT / "sim.vvp"
    # Macro quotes are part of the Icarus argument, not shell quoting.
    rom_define = '-DFFT_TW_FILE="' + (OUT / "twiddle.hex").as_posix() + '"'
    subprocess.run([iverilog, "-g2012", "-s", "tb_fft_sparse", rom_define,
                    "-o", str(exe), str(ROOT / "rtl/acoustic/rv32_fft_bfly.v"),
                    str(ROOT / "rtl/acoustic/rv32_fft_addr.v"),
                    str(ROOT / "tb/tb_fft_sparse.v")], check=True, cwd=ROOT)
    run = subprocess.run([vvp, str(exe), f"+INPUT={OUT / 'input.hex'}",
                          f"+GOLDEN={OUT / 'golden.hex'}"], cwd=ROOT, capture_output=True, text=True)
    (OUT / "simulation.log").write_text(run.stdout + run.stderr, encoding="utf-8")
    print(run.stdout, end="", flush=True)
    if run.returncode or "FFT_SPARSE_PASS" not in run.stdout:
        raise RuntimeError(run.stderr or "FFT sparse regression failed")
    negative = subprocess.run([vvp, str(exe), f"+INPUT={OUT / 'input.hex'}",
                               f"+GOLDEN={OUT / 'golden.hex'}", "+DISABLE_SPARSE"],
                              cwd=ROOT, capture_output=True, text=True)
    (OUT / "negative_disable_sparse.log").write_text(negative.stdout + negative.stderr, encoding="utf-8")
    if negative.returncode == 0 or "sparse/full case=0" not in negative.stdout:
        raise RuntimeError("Negative control failed to detect stale out-of-band RAM")
    print("FFT_SPARSE_NEGATIVE_CONTROL_PASS disabled_mask_detected=1")
    rows = [{"case": int(case), "mode": int(mode), "words": int(count), "run_cycles": int(cycles)}
            for case, mode, count, cycles in re.findall(
                r"case=(\d+) mode=(\d+) words=(\d+) run_cycles=(\d+)", run.stdout)]
    (OUT / "results.json").write_text(json.dumps({"pass": True, "cases": rows,
                                                  "disabled_sparse_negative_control_detected": True,
                                                  "golden": "scalar sw/fw/fw_fft.c"}, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
