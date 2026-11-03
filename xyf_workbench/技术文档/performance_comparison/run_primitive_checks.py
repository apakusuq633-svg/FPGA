"""Reproduce SRP / FFT module checks in isolated, timestamped output folders."""
from pathlib import Path
import argparse
import contextlib
import datetime as dt
import hashlib
import importlib.util
import json
import os
import shutil
import sys

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / 'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog'
CASES = {
    'srp': ('check_srp_lag_ring.py', [
        'rtl/srp/rv32_srp_scan.v', 'rtl/srp/rv32_srp_regs.v',
        'tb/tb_srp_lag_ring.v', 'tb/tb_srp_throughput.v']),
    'fft': ('check_fft_sparse.py', [
        'rtl/acoustic/rv32_fft_bfly.v', 'rtl/acoustic/rv32_fft_addr.v',
        'tb/tb_fft_sparse.v', 'sw/fw/fw_fft.c', 'sw/fw/fw_fft.h',
        'sw/fw/fw_tables.c', 'sw/fw/fw_tables.h', 'sw/fw/fw_plat.h',
        'sw/fw/fw_cycle_profile.h']),
}

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--kind', choices=['srp', 'fft', 'all'], default='all')
    a = p.parse_args()
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out = HERE / 'rtl_primitives' / ('run_' + stamp)
    out.mkdir(parents=True)
    os.environ['PATH'] = r'C:\msys64\ucrt64\bin;C:\msys64\usr\bin;' + os.environ.get('PATH', '')
    cookie = os.add_dll_directory(r'C:\msys64\ucrt64\bin') if hasattr(os, 'add_dll_directory') else None
    kinds = list(CASES) if a.kind == 'all' else [a.kind]
    proof = {'scope': 'RTL module cycles; no A9 / board timing', 'tests': {}, 'output': str(out)}
    for kind in kinds:
        script, files = CASES[kind]
        names = ['scripts/' + script] + files
        before = {n: sha(SOURCE / n) for n in names}
        for name in names:
            target = out / 'source' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, target)
        spec = importlib.util.spec_from_file_location('isolated_' + kind, SOURCE / 'scripts' / script)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.OUT = out / kind
        with (out / (kind + '_stdout.log')).open('w', encoding='utf-8') as stdout:
            with contextlib.redirect_stdout(stdout):
                module.main()
        after = {n: sha(SOURCE / n) for n in names}
        assert before == after, 'production source changed'
        result = json.loads((module.OUT / 'results.json').read_text(encoding='utf-8'))
        proof['tests'][kind] = {'source_sha256': before, 'source_unchanged': True, 'result': result}
        print(kind + ': PASS; ' + str(module.OUT / 'results.json'), flush=True)
    proof['artifacts'] = {str(f.relative_to(out)).replace('\\', '/'): sha(f)
                          for f in out.rglob('*') if f.is_file()}
    (out / 'provenance.json').write_text(json.dumps(proof, indent=2) + '\n', encoding='utf-8')
    print('Evidence: ' + str(out))

if __name__ == '__main__':
    main()
