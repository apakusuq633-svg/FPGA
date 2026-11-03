"""Prepare/validate human measurements; never estimate or invent calibration.

The resulting external configuration is an explicit input to
build_circular9.py --config. This utility never modifies production config,
firmware headers, hardware acceptance flags or the board itself.
"""
import argparse
from copy import deepcopy
from datetime import datetime
import hashlib
import json
from pathlib import Path

from build_circular9 import (ROOT, CAPTURE_BINDING_KEYS, calibration_binding,
                            canonical_sha256, geometry, geometry_confirmed)

CONFIRMATIONS = ('geometry_measured', 'channel_mapping_measured',
                 'clock_and_decimation_verified', 'gain_delay_measured',
                 'fit_residuals_reviewed', 'accepted_for_build')
RECORD_KEYS = {'record_version', 'source_config_sha256', 'array_id', 'operator',
               'measured_at', 'sources', 'evidence_files', 'microphones',
               'channel_to_mic', 'expected_capture_contract', 'capture_contract',
               'channel_gain_q14', 'channel_delay_samples', 'fit_residuals',
               'confirmations', 'notes'}


def file_sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def measurement_template(config, config_sha256):
    return {
        'record_version': 1, 'source_config_sha256': config_sha256,
        'array_id': None, 'operator': None, 'measured_at': None,
        'sources': {key: None for key in ('geometry', 'mapping', 'clock', 'gain', 'delay')},
        'evidence_files': [],
        'microphones': [{'mic_id': i, 'position_m': [None, None, None]} for i in range(9)],
        'channel_to_mic': [None]*9,
        'expected_capture_contract': {key: config[key] for key in CAPTURE_BINDING_KEYS},
        'capture_contract': {key: None for key in CAPTURE_BINDING_KEYS},
        'channel_gain_q14': [None]*9, 'channel_delay_samples': [None]*9,
        'fit_residuals': {'band_low_hz': None, 'band_high_hz': None,
                          'gain_rms_db': [None]*9, 'phase_rms_deg': [None]*9,
                          'delay_rms_samples': [None]*9},
        'confirmations': {key: False for key in CONFIRMATIONS},
        'notes': [
            'Unfilled values are NOT measurements. Units: metres and original156250-Hz PCM samples.',
            'View the acoustic front: +x right,+y up,+z toward source; mic8 is center and MUST be capture slot8.',
            'Map all9 live capture channels by individual microphone checks; do not infer mapping from connector labels.',
            'Gain values correct each sensor amplitude; delay values are sensor arrival offsets AFTER removing known geometric propagation. Reference channel0 delay is0.',
            'Record evidence files with path,sha256,roles; reviewed calibration requires gain,delay,fit roles.',
            'Set confirmations true ONLY after actual measurement and independent residual review. This does not mark board_tested.',
        ],
    }


def calibrated_configuration(base, record, source_sha256, record_directory, verify_evidence=True):
    if not isinstance(record, dict) or set(record)-RECORD_KEYS:
        raise ValueError('Unsupported record keys; check measurement template/schema')
    if record.get('source_config_sha256') != source_sha256:
        raise ValueError('Record belongs to a different source configuration; regenerate/review its template')
    expected = {key: base[key] for key in CAPTURE_BINDING_KEYS}
    if record.get('expected_capture_contract', expected) != expected or record.get('capture_contract') != expected:
        raise ValueError('Fill and verify the actual capture contract; it must match the selected build configuration')
    if any(type(record['capture_contract'][key]) is not type(expected[key]) for key in expected):
        raise ValueError('Capture contract numbers must retain the explicit expected integer/rational types')
    confirmations = record.get('confirmations')
    if not isinstance(confirmations, dict) or set(confirmations) != set(CONFIRMATIONS) or any(type(value) is not bool for value in confirmations.values()):
        raise ValueError('All six explicit boolean confirmations are required')
    reviewed = all(confirmations.values())
    microphones = record.get('microphones')
    if not isinstance(microphones, list) or len(microphones) != 9:
        raise ValueError('Fill nine measured microphone positions')
    by_id = {}
    for item in microphones:
        if not isinstance(item, dict) or set(item) != {'mic_id', 'position_m'} or type(item['mic_id']) is not int or item['mic_id'] not in range(9) or item['mic_id'] in by_id:
            raise ValueError('Each physical mic_id0..8 must appear exactly once')
        by_id[item['mic_id']] = item['position_m']
    mapping = record.get('channel_to_mic')
    if not isinstance(mapping, list) or len(mapping) != 9 or any(type(m) is not int for m in mapping) or set(mapping) != set(range(9)):
        raise ValueError('Fill the measured channel_to_mic permutation0..8')
    if mapping[8] != 8:
        raise ValueError('Center mic8 must be capture slot8. Correct physical wiring first; current GSC/RTL center is fixed.')
    config = deepcopy(base)
    config['channel_to_mic'] = mapping.copy()
    config['channel_positions_m'] = [deepcopy(by_id[m]) for m in mapping]
    for key, default in (('channel_gain_q14', 16384), ('channel_delay_samples', 0)):
        values = record.get(key)
        if not isinstance(values, list) or len(values) != 9:
            raise ValueError('Nine '+key+' entries required')
        if any(value is None for value in values) and (reviewed or confirmations['gain_delay_measured']):
            raise ValueError('Measured gain/delay claim contains unfilled coefficients')
        config[key] = [default if value is None else value for value in values]
    when = record.get('measured_at')
    if when is not None:
        if not isinstance(when, str):
            raise ValueError('Measurement time must be ISO8601 with timezone')
        try:
            parsed = datetime.fromisoformat(when.replace('Z', '+00:00'))
        except ValueError as exc:
            raise ValueError('Measurement time must be ISO8601 with timezone') from exc
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError('Measurement time must include timezone')
    evidence = record.get('evidence_files')
    if not isinstance(evidence, list):
        raise ValueError('evidence_files must be an array of actual file references')
    if verify_evidence:
        for entry in evidence:
            if not isinstance(entry, dict) or not isinstance(entry.get('path'), str) or not entry['path'] or not isinstance(entry.get('sha256'), str):
                raise ValueError('Each evidence reference requires an actual path and SHA256')
            path = Path(entry['path'])
            if not path.is_absolute():path = Path(record_directory)/path
            if not path.is_file() or file_sha256(path) != entry['sha256']:
                raise ValueError('Missing/changed measurement evidence: '+str(path))
    digest = canonical_sha256(record)
    config['geometry_status'] = 'measured_confirmed' if reviewed else 'measured_unconfirmed'
    config['physical_mapping_confirmed'] = reviewed
    config['calibration_status'] = 'measured_reviewed' if reviewed else 'unmeasured'
    config['calibration_version'] = (int(digest[:8], 16) or 1) if reviewed else 0
    config['board_tested'] = False
    config['clearance_unverified'] = True
    config['geometry_measurement'] = {'record': deepcopy(record), 'record_sha256': digest,
                                    'binding_sha256': canonical_sha256(calibration_binding(config)),
                                    'evidence_root': str(Path(record_directory).resolve())}
    geometry(config)  # Same strict math/schema/lag constraints as the real build.
    assert geometry_confirmed(config) is reviewed
    return config


def write_new_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, allow_nan=False, indent=2)
        stream.write('\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('template', 'validate', 'build'):
        sub = commands.add_parser(command)
        sub.add_argument('--config', type=Path, default=ROOT/'configs/circular9_array.json')
        if command == 'template':sub.add_argument('--output', type=Path, required=True)
        else:
            sub.add_argument('--record', type=Path, required=True)
            if command == 'build':sub.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        base = json.loads(args.config.read_text(encoding='utf-8'))
        source_digest = file_sha256(args.config)
        if args.command == 'template':
            write_new_json(args.output, measurement_template(base, source_digest))
            print('CIRCULAR9_CALIBRATION_TEMPLATE_UNCONFIRMED '+str(args.output))
            return
        record = json.loads(args.record.read_text(encoding='utf-8'))
        config = calibrated_configuration(base, record, source_digest, args.record.resolve().parent)
        summary = {'calibration_status': config['calibration_status'],
                   'geometry_confirmed': geometry_confirmed(config),
                   'calibration_version': config['calibration_version'],
                   'board_tested': False, 'clearance_unverified': True,
                   'source_config_path': str(args.config.resolve()), 'source_config_sha256': source_digest,
                   'measurement_record_path': str(args.record.resolve()),
                   'measurement_record_sha256': canonical_sha256(record),
                   'binding_sha256': config['geometry_measurement']['binding_sha256']}
        if args.command == 'build':
            manifest = args.output.with_suffix('.manifest.json')
            if args.output.exists() or manifest.exists():
                raise ValueError('Choose fresh output names; calibration/config evidence will not be overwritten')
            write_new_json(args.output, config)
            summary['output_config_sha256'] = file_sha256(args.output)
            write_new_json(manifest, summary)
        print('CIRCULAR9_CALIBRATION_PASS '+json.dumps(summary, ensure_ascii=False, sort_keys=True))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        parser.exit(2, 'CIRCULAR9_CALIBRATION_REJECTED '+str(exc)+'\n')


if __name__ == '__main__':
    main()
