"""Native SPSC capture ownership and actual three-source spatial separation."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/circular9_candidates_checks'

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['PATH'] = 'C:/msys64/ucrt64/bin;C:/msys64/usr/bin;' + env['PATH']
    commands = [
        ['gcc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-DC9_CANDIDATES_TEST', '-Isw',
         'sw/circular9_candidates.c', 'sw/circular9_candidates_test.c', '-pthread', '-lm',
         '-o', str(OUT/'candidates.exe')],
        [str(OUT/'candidates.exe')],
    ]
    for name, command in zip(['compile', 'native'], commands):
        result = subprocess.run(command, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUT/(name+'.log')).write_text(result.stdout)
        print(result.stdout, end='', flush=True)
        if result.returncode:
            raise RuntimeError(name + ' failed')
    log = (OUT/'native.log').read_text()
    assert 'CIRCULAR9_CANDIDATES_PASS' in log
    metrics = {}
    for label in ['HISTORY_PASS', 'REFINEMENT_PASS', 'SEPARATION_PASS',
                  'MISMATCH_PASS', 'OFFGRID_PASS', 'SENSOR_NOISE_PASS',
                  'MARGINAL_QUALITY', 'CARRIER_GUARD', 'COVARIANCE_PASS',
                  'DELAYS_PASS', 'MULTIBAND_PASS', 'MULTIBAND_REVERB_PASS',
                  'EMPIRICAL_NOISE_PASS', 'TARGET_PROTECTION_PASS']:
        line = next(line for line in log.splitlines() if line.startswith(label))
        metrics[label] = {k:float(v) for k,v in re.findall(r'(\w+)=(-?\d+(?:\.\d+)?)',line)}
    sources = ['sw/circular9_candidates.c', 'sw/circular9_candidates.h',
               'sw/circular9_candidates_test.c', 'sw/circular9_direction.h',
               'sw/circular9_decimator.h', 'sw/circular9_diagnosis.h']
    contract = (ROOT/'sw/circular9_diagnosis.h').read_text()
    carrier = [int(re.search(r'#define C9_DIAG_CARRIER_' + edge + r'_HZ (\d+)u', contract)[1])
               for edge in ['LOW','HIGH']]
    assert carrier == [2200,4600]
    evidence = {'passed':True, 'hardware_tested':False, 'ps_runtime_measured':False,
        'classifier_validated':False, 'separation_contract':'C9S3',
        'diagnostic_carrier_hz':carrier,
        'history_frames':1048576,'history_reserved_bytes':32*1024*1024,
        'multiband_hz':[[600,2200],[2200,4600],[4600,8000]],
        'spectral_feedback':{'raw_frames':16640,'validity_after_end_samples':31250,
                             'minimum_consecutive_supported_stft_frames':3,
                             'physical_fault_classification':False},
        'empirical_covariance':{'stft_observations':8,'target_subspace_max_rank':5,
                                'shrinkage':.25,'minimum_residual_to_total_power':.001,
                                'loading_mixes':[8,2,0]},
        'carrier_quality':{'minimum_coverage':.95,'maximum_contiguous_missing_bins':3},
        'physical_angle_accuracy_claimed':False,
        'fixture':'actual mixed-snapshot covariance fit with frozen-weight source contributions; independent continuous plane-wave delays; weak target18.06dB below loudest; no physical hardware claim',
        'metrics':metrics, 'sources':{s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}}
    evidence['search_directions'] = [
        {k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)}
        for line in log.splitlines() if line.startswith('SEARCH_DIRECTION ')]
    (OUT/'results.json').write_text(json.dumps(evidence,indent=2)+'\n')

if __name__ == '__main__':
    main()
