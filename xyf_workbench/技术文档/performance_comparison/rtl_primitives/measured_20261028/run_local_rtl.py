"""Run existing local-only RTL checks; keep proof outside production sources."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import subprocess
import sys
import time

WORKSPACE = Path(__file__).resolve().parents[2]
ROOT = WORKSPACE / 'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog'
OUT = Path(__file__).resolve().parent
KINDS = {
    'srp': ('scripts/check_srp_lag_ring.py', [
        'rtl/srp/rv32_srp_scan.v', 'rtl/srp/rv32_srp_regs.v',
        'tb/tb_srp_lag_ring.v', 'tb/tb_srp_throughput.v'],
        'build/srp_lag_ring'),
    'fft': ('scripts/check_fft_sparse.py', [
        'rtl/acoustic/rv32_fft_bfly.v', 'rtl/acoustic/rv32_fft_addr.v',
        'tb/tb_fft_sparse.v', 'sw/fw/fw_fft.c', 'sw/fw/fw_fft.h',
        'sw/fw/fw_tables.c', 'sw/fw/fw_tables.h', 'sw/fw/fw_plat.h',
        'sw/fw/fw_cycle_profile.h'], 'build/fft_sparse'),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    kind = sys.argv[1]
    script, extra, product = KINDS[kind]
    sources = [script] + extra
    before = {name: sha(ROOT / name) for name in sources}
    env = os.environ.copy()
    env['PATH'] = r'C:\msys64\ucrt64\bin;C:\msys64\usr\bin;' + env.get('PATH', '')
    env['PYTHONUTF8'] = '1'
    command = [sys.executable, str(ROOT / script)]
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    begin = time.perf_counter()
    failure = None
    try:
        run = subprocess.run(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, encoding='utf-8',
                             errors='replace', timeout=180)
        stdout, stderr, code = run.stdout, run.stderr, run.returncode
    except subprocess.TimeoutExpired as error:
        stdout = error.stdout or ''
        stderr = error.stderr or ''
        if isinstance(stdout, bytes): stdout = stdout.decode('utf-8', 'replace')
        if isinstance(stderr, bytes): stderr = stderr.decode('utf-8', 'replace')
        code, failure = 124, '180 second timeout; this item stopped'
    (OUT / (kind + '_stdout.log')).write_text(stdout, encoding='utf-8')
    (OUT / (kind + '_stderr.log')).write_text(stderr, encoding='utf-8')
    after = {name: sha(ROOT / name) for name in sources}
    files = {p.relative_to(ROOT).as_posix(): {'bytes': p.stat().st_size, 'sha256': sha(p)}
             for p in sorted((ROOT / product).rglob('*')) if p.is_file()}
    proof = {
        'kind': kind, 'started_utc': start,
        'finished_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'host_elapsed_s': time.perf_counter() - begin,
        'command': command, 'working_directory': str(ROOT),
        'path_prefix_child_only': r'C:\msys64\ucrt64\bin;C:\msys64\usr\bin',
        'python_executable': sys.executable,
        'source_sha256_before': before, 'source_sha256_after': after,
        'source_hash_unchanged': before == after,
        'returncode': code, 'failure': failure,
        'hardware_accessed': False, 'synthesis_run': False,
        'measurement_type': 'local RTL simulation cycles; host duration is not A9 performance',
        'stdout_sha256': sha(OUT / (kind + '_stdout.log')),
        'stderr_sha256': sha(OUT / (kind + '_stderr.log')),
        'products': files,
    }
    (OUT / (kind + '_provenance.json')).write_text(json.dumps(proof, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'kind': kind, 'returncode': code,
                      'host_elapsed_s': proof['host_elapsed_s'],
                      'source_hash_unchanged': before == after,
                      'products': len(files), 'stdout_tail': stdout[-2200:],
                      'stderr_tail': stderr[-1000:]}))
    return code or (0 if before == after else 125)


if __name__ == '__main__':
    raise SystemExit(main())
