#!/usr/bin/env python3
"""Check 36-pair, 1024-grid SRP at 32/64 lags with independent integer goldens.

Covers all Q4 indices/fractions (including -1/16 wrapping into zero), delays
outside the legacy +/-16 range, signed extreme correlations, serial/fast RTL,
both tight and wider LUT transports, MMIO addressing and repeated-map clearing.
Only Python's standard library and Icarus Verilog are required.
"""
import json
from pathlib import Path
import random
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "srp_lag_ring"
PAIRS, GRIDS = 36, 1024


def emit(path, values, width):
    path.write_text("".join(f"{v & ((1 << width)-1):0{(width+3)//4}x}\n"
                            for v in values), encoding="ascii")


def vectors(rlen, idx_w, folder):
    rng = random.Random(600416 + rlen)
    correlations = [[rng.randrange(-32768, 32768) for _ in range(rlen)]
                    for _ in range(PAIRS)]
    # Deliberately make the wrap endpoints maximally different.
    for pair, row in enumerate(correlations):
        row[-1], row[0] = (-32768, 32767) if pair % 2 else (32767, -32768)
    delays, expected = [], [0] * GRIDS
    for pair in range(PAIRS):
        for grid in range(GRIDS):
            # Every signed Q4 delay in the ring appears in each pair for64.
            # The 32-ring profile repeats its complete Q4 range twice.
            tau_q4 = (grid + pair * 137) % (rlen * 16) - rlen * 8
            integer, fraction = divmod(tau_q4, 16)  # mathematical floor
            v0 = correlations[pair][integer % rlen]
            v1 = correlations[pair][(integer + 1) % rlen]
            expected[grid] += v0 + ((v1-v0) * fraction // 16)
            # Wider transports contain signed delay bits above the ring index;
            # these must never address another pair's correlation row.
            delays.append(tau_q4 & ((1 << (idx_w+4))-1))
    emit(folder / "lut.hex", delays, idx_w+4)
    emit(folder / "r.hex", [v for row in correlations for v in row], 16)
    emit(folder / "golden.hex", expected, 32)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    compiler, runner = shutil.which("iverilog"), shutil.which("vvp")
    if not compiler or not runner:
        raise SystemExit("iverilog and vvp must be on PATH")
    results, logs = [], []
    for rlen, idx_w, fast in [(32, 5, 1), (32, 5, 0),
                              (64, 6, 1), (64, 6, 0), (64, 10, 1), (64, 10, 0),
                              (32, 5, 4), (64, 6, 4), (64, 10, 4)]:
        name = f"r{rlen}_i{idx_w}_fast{fast}"
        folder = OUT / name
        folder.mkdir(exist_ok=True)
        vectors(rlen, idx_w, folder)
        exe = folder / "sim.vvp"
        cmd = [compiler, "-g2012", "-s", "tb_srp_lag_ring",
               f"-Ptb_srp_lag_ring.R_LEN={rlen}",
               f"-Ptb_srp_lag_ring.IDX_W={idx_w}",
               f"-Ptb_srp_lag_ring.FAST_SCAN={fast}", "-o", str(exe),
               str(ROOT / "rtl/srp/rv32_srp_scan.v"),
               str(ROOT / "rtl/srp/rv32_srp_regs.v"),
               str(ROOT / "tb/tb_srp_lag_ring.v")]
        subprocess.run(cmd, check=True, cwd=ROOT)
        p = subprocess.run([runner, str(exe), f"+LUT={folder / 'lut.hex'}",
                            f"+R={folder / 'r.hex'}", f"+GOLDEN={folder / 'golden.hex'}"],
                           cwd=ROOT, text=True, capture_output=True)
        (folder / "simulation.log").write_text(p.stdout + p.stderr, encoding="utf-8")
        logs.append(p.stdout + p.stderr)
        print(p.stdout, end="", flush=True)
        if p.returncode or "SRP_LAG_RING_PASS" not in p.stdout:
            raise RuntimeError(p.stderr or f"{name} failed")
        results.append({"r_len": rlen, "idx_w": idx_w, "fast_scan": fast,
                        "maps": 2, "compared_scores": 2048,
                        "start_to_done_cycles": [int(v) for v in re.findall(r"cycles=(\d+)", p.stdout)],
                        "busy_writes_rejected": True, "pass": True})
    edge_exe = OUT / "edges.vvp"
    subprocess.run([compiler, "-g2012", "-s", "tb_srp_parallel4_edges", "-o", str(edge_exe),
                    str(ROOT / "rtl/srp/rv32_srp_scan.v"),
                    str(ROOT / "tb/tb_srp_throughput.v")], check=True, cwd=ROOT)
    edge = subprocess.run([runner, str(edge_exe)], cwd=ROOT, text=True, capture_output=True)
    (OUT / "edges.log").write_text(edge.stdout + edge.stderr, encoding="utf-8")
    if edge.returncode or "SRP_PARALLEL4_EDGES_PASS" not in edge.stdout:
        raise RuntimeError(edge.stdout + edge.stderr)
    print(edge.stdout, end="", flush=True)
    logs.append(edge.stdout + edge.stderr)
    (OUT / "results.json").write_text(json.dumps({"pass": True, "cases": results,
                                                "parallel4_partial_group_single_grid_restart_abort": True},
                                               indent=2) + "\n", encoding="utf-8")
    (OUT / "all.log").write_text("".join(logs), encoding="utf-8")
    print(f"SRP_LAG_RING_ALL_PASS scores={len(results)*2048}")


if __name__ == "__main__":
    main()
