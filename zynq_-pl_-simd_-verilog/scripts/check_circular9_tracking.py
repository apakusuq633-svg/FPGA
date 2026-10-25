"""Behavioral provenance checks for short missing peaks and angular identity."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/circular9_tracking_checks'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;' + env['PATH']
    executable = OUT / 'tracking.exe'
    commands = [
        ['gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
         '-Wno-unused-const-variable', '-Isw', 'sw/circular9_candidates.c',
         'sw/circular9_tracking_test.c', '-lm', '-o', str(executable)],
        [str(executable)],
    ]
    for name, command in zip(['compile', 'native'], commands):
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUT / (name + '.log')).write_text(result.stdout)
        print(result.stdout, end='', flush=True)
        if result.returncode:
            raise RuntimeError(name + ' failed')
    line = next(s for s in result.stdout.splitlines() if s.startswith('C9_TRACKING_PASS'))
    metrics = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', line)}
    sources = ['sw/circular9_tracking.h', 'sw/circular9_tracking_test.c',
               'sw/circular9_candidates.c', 'sw/circular9_candidates.h',
               'sw/circular9_direction.h', 'scripts/check_circular9_tracking.py']
    evidence = {
        'passed': True, 'hardware_tested': False, 'ps_runtime_measured': False,
        'fixture': 'native C angular observations; explicit timestamps, missing maps, rank changes, merged peaks, counter wraps; no captured microphone audio',
        'metrics': metrics,
        'sources': {s: hashlib.sha256((ROOT / s).read_bytes()).hexdigest() for s in sources},
    }
    (OUT / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')


if __name__ == '__main__':
    main()
