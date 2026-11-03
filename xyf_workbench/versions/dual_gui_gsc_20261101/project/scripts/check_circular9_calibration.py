"""Offline geometry/calibration contracts with named synthetic-only evidence.

Never runs a firmware generator or modifies production configuration/headers.
"""
from copy import deepcopy
import hashlib
import itertools
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile

from build_circular9 import (ROOT, CAPTURE_BINDING_KEYS, calibration_parameters,
                            geometry, geometry_confirmed, plane_wave_delays,
                            verify_calibration_evidence)
from circular9_calibration import (calibrated_configuration, file_sha256,
                                   measurement_template)

OUT = ROOT/'build/circular9_calibration_checks'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    base = json.loads((ROOT/'configs/circular9_array.json').read_text(encoding='utf-8'))
    checks = 0
    def check(value, message):
        nonlocal checks
        checks += 1
        if not value:raise AssertionError(message)
    def rejects(function, message):
        nonlocal checks
        checks += 1
        try:function()
        except (ValueError, TypeError):return
        raise AssertionError('accepted '+message)
    baseline = geometry(base)
    check(not geometry_confirmed(base), 'nominal production configuration remains unconfirmed')
    gains, delays = calibration_parameters(base)
    check(gains == [16384]*9 and delays == [0]*9, 'missing unmeasured coefficients preserve default unity/zero')
    with tempfile.TemporaryDirectory(prefix='c9_synthetic_calibration_') as folder:
        directory = Path(folder)
        config_path = directory/'base.json'
        config_path.write_text(json.dumps(base, indent=2)+'\n', encoding='utf-8')
        source_sha = file_sha256(config_path)
        blank = measurement_template(base, source_sha)
        check(all(value is None for mic in blank['microphones'] for value in mic['position_m']), 'template never invents measured coordinates')
        check(all(value is None for value in blank['channel_gain_q14']+blank['channel_delay_samples']), 'template never invents sensor correction measurements')
        check(not any(blank['confirmations'].values()), 'template is explicitly unconfirmed')
        rejects(lambda: calibrated_configuration(base, blank, source_sha, directory), 'empty template')
        record = deepcopy(blank)
        physical = deepcopy(base['channel_positions_m'])
        physical[0][0] += .0001
        physical[1][1] -= .00015
        record['microphones'] = [{'mic_id': i, 'position_m': physical[i]} for i in range(9)]
        record['channel_to_mic'] = [2, 0, 1, 7, 6, 3, 5, 4, 8]
        record['capture_contract'] = {key: base[key] for key in CAPTURE_BINDING_KEYS}
        draft = calibrated_configuration(base, record, source_sha, directory)
        check(not geometry_confirmed(draft) and draft['calibration_version'] == 0 and draft['calibration_status'] == 'unmeasured', 'complete unreviewed geometry stays protected')
        check(draft['channel_positions_m'][0] == physical[2] and draft['channel_positions_m'][1] == physical[0], 'physical mic coordinates are permuted into real capture order')
        check(draft['channel_positions_m'][8] == physical[8] and draft['board_tested'] is False and draft['clearance_unverified'] is True, 'draft cannot claim board or package-clearance acceptance')
        evidence = directory/'SYNTHETIC_ONLY_gain_delay_fit.txt'
        evidence.write_text('Synthetic calibration contract fixture only. No microphone was measured.\n', encoding='ascii')
        record['array_id'] = 'SYNTHETIC_TEST_ONLY'
        record['operator'] = 'offline-test-fixture'
        record['measured_at'] = '2026-10-25T12:00:00+08:00'
        record['sources'] = {key: 'SYNTHETIC TEST DATA ONLY' for key in record['sources']}
        record['evidence_files'] = [{'path': evidence.name, 'sha256': file_sha256(evidence), 'roles': ['gain', 'delay', 'fit']}]
        record['channel_gain_q14'] = [16384, 17000, 16000, 16500, 15000, 17500, 16400, 16300, 15500]
        record['channel_delay_samples'] = [0, .25, -.125, .5, .125, -.25, 0, .375, .0625]
        record['fit_residuals'] = {'band_low_hz': 300, 'band_high_hz': 8000,
                                  'gain_rms_db': [.05]*9, 'phase_rms_deg': [1.0]*9,
                                  'delay_rms_samples': [.03]*9}
        record['confirmations'] = {key: True for key in record['confirmations']}
        measured = calibrated_configuration(base, record, source_sha, directory)
        check(geometry_confirmed(measured) and measured['calibration_version'] != 0 and measured['calibration_status'] == 'measured_reviewed', 'synthetic reviewed record exercises complete provenance path')
        check(measured['board_tested'] is False and measured['clearance_unverified'] is True, 'review never marks board tested or clearance confirmed')
        check(verify_calibration_evidence(measured) == {str(evidence.resolve()): file_sha256(evidence)}, 'actual build evidence allowlist uses absolute paths and actual file digests')
        srp, steer, pairs = geometry(measured)
        # Independent per-channel propagation + sensor arrival offset oracle.
        # No calls to plane_wave_delays are used to calculate expected values.
        comparisons = 0
        for g in (0, 31, 264, 496, 511, 512, 527, 759, 992, 1023):
            az = math.radians(-90+180*((g%32)+.5)/32)
            el = math.radians(-90+180*((g//32)+.5)/32)
            u = (math.sin(az)*math.cos(el), math.sin(el), math.cos(az)*math.cos(el))
            want = [-sum(p[k]*u[k] for k in range(3))*base['sample_rate_hz']/base['sound_speed_m_s']+record['channel_delay_samples'][i]
                    for i, p in enumerate(measured['channel_positions_m'])]
            got = plane_wave_delays(measured, math.degrees(az), math.degrees(el))
            check(all(abs(a-b) < 1e-11 for a, b in zip(want, got)), 'plane-wave API includes the relative sensor delay exactly once')
            for k, (a, b) in enumerate(pairs):
                q = srp[k*1024+g]
                q = q-1024 if q >= 512 else q
                check(q == math.floor((want[a]-want[b])*16), 'SRP Q4 pair difference follows measured capture order and delay sign')
                comparisons += 1
            for ch in range(9):
                q = steer[ch*1024+g]
                q = q-16384 if q & 8192 else q
                check(q == math.floor((want[0]-want[ch])*16), 'steering reference difference follows the same total arrival model')
                comparisons += 1
        check((srp, steer) != baseline[:2], 'real coordinate/mapping/delay changes alter both generated LUTs')
        # A30-mm acoustic ring is valid even when the old nominal PCB radius
        # is also30mm; package/edge clearance remains a separate unknown.
        edge = deepcopy(base)
        edge['ring_radius_m'] = edge['pcb_radius_m'] = .03
        edge['channel_positions_m'] = [[.03*math.cos(i*math.pi/4), .03*math.sin(i*math.pi/4), 0] for i in range(8)]+[[0, 0, 0]]
        check(len(geometry(edge)[0]) == 36864, '30mm acoustic ring is not rejected by historical PCB-radius equality')
        for key, value in [('channel_gain_q14', [32768]*9), ('channel_gain_q14', [8191]*9),
                           ('channel_delay_samples', [0, 4.001]+[0]*7),
                           ('channel_delay_samples', [.125]+[0]*8),
                           ('channel_to_mic', [0]*9), ('channel_to_mic', [True]+list(range(1, 9))),
                           ('channel_to_mic', list(range(7))+[8, 7]),
                           ('channel_positions_m', [[0, 0, 0]]*9),
                           ('sound_speed_m_s', float('nan')), ('pcb_radius_m', float('inf')),
                           ('sample_rate_den', True)]:
            bad = deepcopy(base);bad[key] = value
            rejects(lambda bad=bad: geometry(bad), 'invalid '+key)
        for mutation, name in [
            (lambda c: c['channel_positions_m'][0].__setitem__(0, float('nan')), 'NaN position'),
            (lambda c: c['channel_positions_m'][0].__setitem__(2, .002), 'nonplanar microphone'),
            (lambda c: c['channel_positions_m'][0].__setitem__(0, .08), 'out-of-board position'),
            (lambda c: c.__setitem__('channel_positions_m', [[.025*math.cos(i*math.pi/4), .001*math.sin(i*math.pi/4), 0] for i in range(8)]+[[0, 0, 0]]), 'almost collinear aperture'),
            (lambda c: c.__setitem__('geometry_status', 'measured_confirmed'), 'unbound geometry confirmation'),
            (lambda c: c.__setitem__('calibration_version', 1), 'unbound acoustic calibration version')]:
            bad = deepcopy(base);mutation(bad);rejects(lambda bad=bad: geometry(bad), name)
        for mutation, name in [
            (lambda r: r['microphones'][0].__setitem__('mic_id', 1), 'duplicate physical ID'),
            (lambda r: r.__setitem__('channel_to_mic', list(range(7))+[8, 7]), 'center channel move'),
            (lambda r: r['capture_contract'].__setitem__('pdm_decimation', 32), 'different actual decimation'),
            (lambda r: r.__setitem__('source_config_sha256', '0'*64), 'wrong source config'),
            (lambda r: r.__setitem__('measured_at', '2026-10-25T12:00:00'), 'timezone-free record'),
            (lambda r: r['sources'].__setitem__('delay', None), 'missing delay source'),
            (lambda r: r['evidence_files'][0].__setitem__('sha256', '0'*64), 'changed evidence'),
            (lambda r: r['evidence_files'][0].__setitem__('path', 'missing.csv'), 'missing evidence'),
            (lambda r: r['evidence_files'][0].__setitem__('roles', ['gain', 'delay']), 'unreferenced residual fit'),
            (lambda r: r['fit_residuals'].__setitem__('band_low_hz', 1000), 'incomplete calibration frequency band'),
            (lambda r: r['fit_residuals']['phase_rms_deg'].__setitem__(4, 10.01), 'large phase residual'),
            (lambda r: r['fit_residuals']['gain_rms_db'].__setitem__(3, .51), 'large gain residual'),
            (lambda r: r['fit_residuals']['delay_rms_samples'].__setitem__(2, .251), 'large delay residual'),
            (lambda r: r['channel_gain_q14'].__setitem__(1, None), 'unfilled confirmed coefficient')]:
            bad = deepcopy(record);mutation(bad)
            rejects(lambda bad=bad: calibrated_configuration(base, bad, source_sha, directory), name)
        for key, value in [('channel_positions_m', deepcopy(base['channel_positions_m'])),
                           ('channel_delay_samples', [0]*9), ('channel_gain_q14', [16384]*9),
                           ('sound_speed_m_s', 340), ('calibration_version', 1)]:
            bad = deepcopy(measured);bad[key] = value
            rejects(lambda bad=bad: geometry(bad), 'tampered reviewed '+key)
        template_path = directory/'new_template.json'
        record_path = directory/'record.json'
        record_path.write_text(json.dumps(record, indent=2)+'\n', encoding='utf-8')
        output_path = directory/'calibrated.json'
        commands = [
            ['scripts/circular9_calibration.py', 'template', '--config', str(config_path), '--output', str(template_path)],
            ['scripts/circular9_calibration.py', 'validate', '--config', str(config_path), '--record', str(record_path)],
            ['scripts/circular9_calibration.py', 'build', '--config', str(config_path), '--record', str(record_path), '--output', str(output_path)],
            ['scripts/build_circular9.py', '--config', str(output_path), '--validate-only'],
        ]
        for i, command in enumerate(commands):
            result = subprocess.run([sys.executable]+command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (OUT/f'cli_{i}.log').write_text(result.stdout)
            check(result.returncode == 0, 'explicit external config CLI: '+result.stdout)
        original_evidence = evidence.read_bytes()
        evidence.write_bytes(original_evidence+b'changed after calibration review\n')
        result = subprocess.run([sys.executable]+commands[3], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUT/'cli_changed_evidence.log').write_text(result.stdout)
        check(result.returncode != 0, 'formal build validation rejects evidence changed after the CLI produced a confirmed config')
        evidence.write_bytes(original_evidence)
        evidence.unlink()
        result = subprocess.run([sys.executable]+commands[3], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUT/'cli_missing_evidence.log').write_text(result.stdout)
        check(result.returncode != 0, 'formal build validation rejects evidence removed after confirmed config creation')
        evidence.write_bytes(original_evidence)
        check(not output_path.is_relative_to(ROOT), '--config formal input tested outside repository')
        output = json.loads(output_path.read_text(encoding='utf-8'))
        check(output['calibration_version'] == measured['calibration_version'] and output['board_tested'] is False, 'external calibrated config retains provenance without board acceptance')
        check(file_sha256(config_path) == source_sha, 'source configuration was not modified')
        manifest = json.loads(output_path.with_suffix('.manifest.json').read_text(encoding='utf-8'))
        check(manifest['output_config_sha256'] == file_sha256(output_path), 'external output manifest binds exact config bytes')
        result = subprocess.run([sys.executable]+commands[2], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        check(result.returncode != 0, 'CLI cannot overwrite previous config/evidence')
    sources = ['scripts/build_circular9.py', 'scripts/circular9_calibration.py',
               'scripts/check_circular9_calibration.py', 'configs/circular9_array.json']
    evidence = {'passed': True, 'hardware_tested': False, 'real_calibration_measured': False,
                'fixture': 'synthetic geometry/sensor correction and explicit synthetic file references in disposable external directory; no production firmware generation',
                'checks': checks, 'independent_lut_comparisons': comparisons,
                'sources': {s: hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}}
    (OUT/'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print(f'CIRCULAR9_CALIBRATION_CHECK_PASS checks={checks} independent_lut_comparisons={comparisons} real_measurements=0 generated_production_firmware=0')


if __name__ == '__main__':main()
