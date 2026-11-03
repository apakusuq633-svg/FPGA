"""Check real coordinates and correlation-ring coverage before building spatial LUTs."""
from pathlib import Path
import argparse
import itertools
import json
import math
import numpy as np


def analyze(path):
    cfg = json.loads(path.read_text(encoding='utf-8'))
    if cfg['channels']==12:
        from pdm12_geometry import validate
        gate=validate(cfg)
        return {'config':str(path),**gate,'coordinate_unit':cfg.get('coordinate_unit'),
                'physical_mapping_confirmed':cfg.get('physical_mapping_confirmed',False)}
    coordinates = cfg.get('channel_positions_m')
    if coordinates is None:
        return {'config': str(path), 'geometry_available': False,
                'channels': cfg['channels'], 'expected_pairs': cfg['channels']*(cfg['channels']-1)//2,
                'reason': 'Real XYZ and channel mapping required; no fictitious coordinates generated.'}
    p = np.asarray(coordinates, dtype=float)
    n = cfg['channels']
    assert p.shape in [(n, 2), (n, 3)] and np.all(np.isfinite(p))
    if p.shape[1] == 2:
        p = np.c_[p, np.zeros(n)]
    lengths = [float(np.linalg.norm(p[a]-p[b])) for a, b in itertools.combinations(range(n), 2)]
    assert min(lengths) > 0, 'Coincident microphones'
    fs = cfg['sample_rate_hz']
    c = cfg.get('sound_speed_m_s', 343.0)
    maxlag = max(lengths)*fs/c
    required = 1 << math.ceil(math.log2(2*(math.floor(maxlag)+2)))
    rank = int(np.linalg.matrix_rank(p-p.mean(axis=0)))
    return {'config': str(path), 'geometry_available': True, 'channels': n,
            'pairs': len(lengths), 'coordinate_rank': rank,
            'minimum_baseline_mm': min(lengths)*1000, 'maximum_baseline_mm': max(lengths)*1000,
            'all_directions_max_abs_lag_samples': maxlag,
            'minimum_safe_power2_correlation_ring': required,
            'configured_ring': cfg['r_len'], 'ring_covers_all_directions': cfg['r_len'] >= required,
            'centered_geometry_singular_values_m': np.linalg.svd(p-p.mean(axis=0), compute_uv=False).tolist(),
            'planar_mirror_ambiguity': rank == 2,
            'assumptions': 'Coordinate units meters; sound speed from config; interpolation neighbor has one-sample margin.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('config', type=Path, nargs='+')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = [analyze(path.resolve()) for path in args.config]
    text = json.dumps(result, indent=2)+'\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding='utf-8')
    print(text)


if __name__ == '__main__':
    main()
