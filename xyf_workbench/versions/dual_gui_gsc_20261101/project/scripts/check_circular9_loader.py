"""Check fail-closed nine-channel startup on a native MMIO model."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/circular9_loader_checks'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;' + env['PATH']
    exe = OUT / ('loader.exe' if os.name == 'nt' else 'loader')
    for name, command in [('compile', ['gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                                      '-Isw', 'sw/circular9_loader_test.c', '-o', str(exe)]),
                          ('native', [str(exe)])]:
        p = subprocess.run(command, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUT / (name + '.log')).write_text(p.stdout, encoding='utf-8')
        print(p.stdout, end='', flush=True)
        if p.returncode:
            raise RuntimeError(name + ' failed')
    sources = ['sw/ps_pl_live.h', 'sw/ps_das_audio.h', 'sw/acoustic_circular9_image.h',
               'sw/circular9_profile.h', 'sw/circular9_loader_test.c', 'scripts/check_circular9_loader.py']
    (OUT / 'results.json').write_text(json.dumps(dict(passed=True, hardware_tested=False,
        fixture='native MMIO model; not ARM execution or a LUT RAM readback proof',
        negative_cases=9, sources={s: hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}), indent=2)+'\n')

if __name__ == '__main__':
    main()
