"""Collect measured results without inventing absent board timings."""
from pathlib import Path
import argparse
import csv
import hashlib
import json
import statistics

HERE = Path(__file__).resolve().parent

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--host', type=Path, default=HERE / 'ps_software/measured_20261028_host_quiet/results.json')
    p.add_argument('--full-modules', type=Path, default=HERE / 'ps_software/full_modules/measured_20261028_full_quiet/results.json')
    p.add_argument('--primitives', type=Path, default=HERE / 'rtl_primitives/measured_20261028')
    a = p.parse_args()
    rows, evidence = [], {}
    def read(path):
        path = path.resolve()
        evidence[str(path.relative_to(HERE)).replace('\\', '/')] = hashlib.sha256(path.read_bytes()).hexdigest()
        return json.loads(path.read_text(encoding='utf-8'))
    def add(test, variant, platform, mean, speedup='', samples='', p50='', p95='', maximum='', scope=''):
        rows.append(dict(test=test, variant=variant, platform=platform, mean_ms=mean,
                         speedup_vs_local_reference=speedup, samples=samples, p50_ms=p50,
                         p95_ms=p95, max_ms=maximum, scope=scope))
    srp = read(a.primitives / 'srp/results.json')
    assert srp['pass']
    for c in srp['cases']:
        if c['r_len'] == 64 and c['idx_w'] == 6:
            n = statistics.mean(c['start_to_done_cycles'])
            add('SRP_36pairs_1024grids_64lags', str(c['fast_scan']), 'RTL_cycles_at_40MHz', n/40000,
                147458/n, len(c['start_to_done_cycles']), scope='START to DONE; excludes load/readback; serial RTL reference')
    pl = read(HERE / 'pl_rtl/results.json')
    for name in ('fft', 'fir'):
        if name in pl['tests']:
            t = pl['tests'][name]
            assert t['status'] == 'PASS'
            fast = t.get('hardware_total_cycles', t.get('simd_cycles'))
            for variant, cycles in [('scalar', t['scalar_cycles']), ('accelerated', fast)]:
                add(name, variant, 'RTL_RV32_at_40MHz', cycles/40000, t['scalar_cycles']/cycles, 1, scope=t['scope'])
    t = pl['tests']['circular9']
    assert t['status'] == 'PASS'
    metrics = {
        'first_PCM_to_stable_RV_publication': [v['first_pcm_to_rv32'] for v in t['window_latency']],
        'last_PCM_to_stable_RV_publication': [v['first_pcm_to_rv32']-v['acquisition_span'] for v in t['window_latency']],
        'firmware_window_processing': [v['post_acquisition'] for v in t['window_latency']],
        'stable_publication_interval': [v['interval'] for v in t['frames'][1:]],
    }
    for name, vals in metrics.items():
        add('circular9_localization', name, 'RTL_at_40MHz', statistics.mean(vals)/40000,
            samples=len(vals), maximum=max(vals)/40000, scope='Aligned PCM injection; excludes analog/PDM front-end and PS receipt')
    scalar_path = HERE / 'circular9_scalar/rv_plain_Os/results.json'
    if scalar_path.exists():
        scalar = read(scalar_path)
        assert scalar['pass'] and scalar['entry_pc'] == 0 and scalar['text_vma'] == 0
        assert all(v['mismatched_bytes'] == 0 for v in scalar['checks_vs_host'].values())
        baseline = scalar['scalar_call_cycles']
        first = t['score_completion_boundary'][0]
        assert first['first_sample'] == 0
        accelerated = first['raw_ready_to_scores']
        scope = 'Same first window, raw resident to 1024 scores; no peak/quality/publication or PS; accelerated statistics overlap acquisition'
        for variant, cycles in [('RV32_scalar_Os', baseline), ('accelerated_first_window', accelerated)]:
            add('circular9_same_first_window_scores', variant, 'RTL_at_40MHz', cycles/40000, baseline/cycles, 1, scope=scope)
        o2_path = HERE / 'circular9_scalar/rv_plain_O2_corrected/results.json'
        if o2_path.exists():
            o2 = read(o2_path)
            assert o2['pass']
            add('circular9_scalar_compiler_sensitivity', 'RV32_scalar_O2', 'RTL_at_40MHz',
                o2['scalar_call_cycles']/40000, samples=1, scope='Auxiliary O2 scalar build; separate from matched Os primary comparison')
        scalar_host = read(HERE / 'circular9_scalar/results.json')
        assert scalar_host['pass']
        batch_means = [v['per_window_ms'] for v in scalar_host['host_wall_clock']]
        add('circular9_portable_scalar_host', 'O2_no_auto_vectorization', 'Windows_x86_native_host',
            statistics.mean(batch_means), samples=len(batch_means),
            scope='9 timed batches of 64 calls; mean of batch per-window means; no individual-window percentiles; NOT A9')
    host = read(a.host)
    assert host['passed'] and host['source_unchanged']
    for scene, variants in host['search']['summary'].items():
        for variant, v in variants.items():
            add('PS_search_' + scene, variant, 'Windows_x86_native_host', v['mean'], v['mean_speedup_vs_reference'],
                v['repeats'], v['p50'], v['p95'], v['max'], host['search']['scope'])
    for name, variants, scope in [
        ('GSC_division_arithmetic', host['division']['summary'], host['division']['scope']),
        ('envelope_frontend_evolution', host.get('envelope', {}).get('summary', {}), 'Non-equivalent frontends; NOT same-algorithm speedup'),
    ]:
        if not variants:
            continue
        baseline = next(iter(variants.values()))['mean']
        for variant, v in variants.items():
            add(name, variant, 'Windows_x86_native_host', v['mean'], baseline/v['mean'],
                v['repeats'], v['p50'], v['p95'], v['max'], scope)
    if a.full_modules.exists():
        full = read(a.full_modules)
        assert full['passed'] and full['source_unchanged']
        for variant, v in full['gsc']['summary'].items():
            add('GSC_full_32768_samples', variant, 'Windows_x86_native_host', v['mean'],
                samples=v['repeats'], p50=v['p50'], p95=v['p95'], maximum=v['max'],
                scope='Full gsc9_process; bypass and adaptation perform different work; no speedup claimed')
        v = full['separation']['summary']
        add('two_candidate_full_separation', 'production', 'Windows_x86_native_host', v['mean'],
            samples=v['repeats'], p50=v['p50'], p95=v['p95'], maximum=v['max'],
            scope=full['separation']['timing_scope'])
    result = {'scope': 'Measured component and host results; no three-architecture board speedup yet',
              'board_available': False, 'evidence_sha256': evidence, 'rows': rows,
              'pending': ['Cortex-A9 current nine-mic same-task timing',
                          'PS-controlled end-to-end scalar / PS-only / accelerated board comparison',
                          '1000-window sustained load, CPU occupancy, NEON-only comparison, physical acoustic and power measurements']}
    (HERE / 'results_summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    with (HERE / 'results_summary.csv').open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    print('Collected', len(rows), 'measured rows; evidence hashes retained.')

if __name__ == '__main__':
    main()
