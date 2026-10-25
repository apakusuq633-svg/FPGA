"""Real CPU0 fine/tacho control and real fine-cache/GSC with named device doubles."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/circular9_ps_control_checks'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'results.json').unlink(missing_ok=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;' + env['PATH']
    commands = [
        ['gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
         '-Wno-unused-const-variable', '-Isw', 'sw/circular9_control_test.c',
         'sw/circular9_candidates.c', 'sw/circular9_audio.c', 'sw/gsc9.c',
         '-lm', '-o', str(OUT / 'control.exe')],
        [str(OUT / 'control.exe')],
    ]
    for name, command in zip(('compile', 'native'), commands):
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUT / (name + '.log')).write_text(result.stdout)
        print(result.stdout, end='', flush=True)
        if result.returncode:
            raise RuntimeError(name + ' failed')
    line = next(s for s in (OUT / 'native.log').read_text().splitlines()
                if s.startswith('CIRCULAR9_PS_CONTROL_PASS'))
    metrics = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
    assert metrics['interpolation_vectors'] == 3072
    assert metrics['alignment_samples'] == 4096
    assert metrics['negative_routes'] >= 16
    sources = ['scripts/check_circular9_ps_control.py', 'sw/circular9_control_test.c',
               'sw/ps_circular9_control.h', 'sw/circular9_candidates.c',
               'sw/circular9_candidates.h', 'sw/circular9_diagnosis.h', 'sw/circular9_direction.h',
               'sw/circular9_audio.c', 'sw/circular9_audio.h', 'sw/gsc9.c', 'sw/gsc9.h',
               'sw/circular9_profile.h', 'sw/circular9_http_args.h', 'sw/acoustic_circular9_image.h',
               'sw/circular9_decimator.h', 'sw/ps_das_audio.h', 'sw/das_audio_contract.h']
    result = {
        'passed': True, 'hardware_tested': False, 'ps_runtime_measured': False,
        'physical_calibration_measured': False,
        'fixture': ('Real CPU0 indexed control and fine-cache/audio/GSC code; named native MMIO '
                    'protocol model and history-metadata double; synthetic channel permutation '
                    'and sensor delays added to the current production LUT; independent long-double '
                    'interpolation oracle and direct raw-to-DAS/FIR finite sums; no RTL execution '
                    'or physical tacho/calibration evidence in this proof.'),
        'metrics': metrics,
        'sources': {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                    for name in sources},
    }
    (OUT / 'results.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
