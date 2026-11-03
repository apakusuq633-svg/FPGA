"""Read-only gate for an explicitly compiled diagnostic model release.

Never parse/execute C. Recreate the complete header with the known repository
exporter and re-evaluate original, recording-disjoint feature datasets.
Passing this software gate does not establish physical labels or accuracy.
"""
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _integer(value, low, high):
    return type(value) is int and low <= value <= high


def _number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def _sha_string(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def _read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:raise ValueError('Duplicate model JSON key: '+key)
            result[key] = value
        return result
    def bad(value):raise ValueError('Nonfinite model JSON constant: '+value)
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=pairs, parse_constant=bad)


def _ids(values, name):
    if not isinstance(values, list) or not values or any(not isinstance(v, str) or not v.strip() for v in values) or len(set(values)) != len(values):
        raise ValueError(name+': unique explicit recording IDs required')
    return set(values)


def _model_shape(model, pipeline):
    if not isinstance(model, dict):raise ValueError('Paired JSON must contain model parameters')
    expected = {'abi': 2, 'feature_contract': 0x43394632, 'separation_contract': 0x43395333}
    if any(not _integer(model.get(k), v, v) for k, v in expected.items()):
        raise ValueError('Diagnostic model requires ABI2/C9F2/C9S3')
    if not _integer(model.get('version'), 1, 0xffffffff) or not _integer(model.get('kind'), 1, 2) or not _integer(model.get('validated'), 0, 1):
        raise ValueError('Invalid diagnostic model version/kind/validated fields')
    classes = 3 if model['kind'] == 2 else 1
    if not _integer(model.get('classes'), classes, classes) or model.get('feature_pipeline') != pipeline:
        raise ValueError('Diagnostic class count or full C9F2 feature pipeline differs')
    low, high = model.get('shaft_hz_min'), model.get('shaft_hz_max')
    if not _number(low) or not _number(high) or not 10 <= low <= high <= 30:
        raise ValueError('Diagnostic model RPM range must remain inside600..1800')
    for key, bound in (('rms_min', 0), ('minimum_margin', 1), ('anomaly_multiplier', 1)):
        if not _number(model.get(key)) or model[key] <= bound:
            raise ValueError('Invalid positive diagnostic parameter: '+key)
    for key, rows, width, positive in (('center', 3, 18, False), ('inverse_variance', 1, 18, True), ('radius', 1, 3, True)):
        value = model.get(key)
        vectors = value if rows == 3 else [value]
        if not isinstance(vectors, list) or len(vectors) != rows or any(not isinstance(v, list) or len(v) != width or any(not _number(x) or (positive and x <= 0) for x in v) for v in vectors):
            raise ValueError('Invalid diagnostic parameter shape/value: '+key)
    masks = model.get('allowed_masks')
    if not _integer(model.get('mask_count'), 1, 16) or not isinstance(masks, list) or len(masks) != model['mask_count']:
        raise ValueError('Invalid diagnostic separation mask count')
    if any(not isinstance(mask, list) or len(mask) != 7 or any(not _integer(v, 0, 0xffffffff) for v in mask) or not any(mask) or mask[6] > 1023 for mask in masks) or len({tuple(mask) for mask in masks}) != len(masks):
        raise ValueError('Invalid/duplicate diagnostic202-bin separation masks')


def _dataset(document, prefix, read_rows):
    name, digest = document.get(prefix+'_source_path'), document.get(prefix+'_sha256')
    if not isinstance(name, str) or not name or not Path(name).is_absolute() or not _sha_string(digest):
        raise ValueError(prefix+': actual absolute source path/SHA256 missing; re-export with current dataset tool')
    path = Path(name).resolve()
    if not path.is_file() or _sha(path) != digest:
        raise ValueError(prefix+': original feature dataset missing or changed')
    rows = read_rows(path)
    if _sha(path) != digest:
        raise ValueError(prefix+': feature dataset changed while being inspected')
    ids = _ids(document.get(prefix+'_recordings'), prefix+'_recordings')
    actual = {row['recording_id'] for row in rows}
    if ids != actual:raise ValueError(prefix+': recording IDs differ from actual source dataset')
    return path, rows, ids


def inspect_model_release(ps_build):
    """Return bound model artifacts and actual feature-source digest allowlist.

    No model is a valid guarded development release. Unvalidated/baseline
    models remain usable for controlled debugging and never qualify faults.
    Inconsistent/missing paired artifacts are release errors, not defaults.
    """
    if not isinstance(ps_build, dict):raise ValueError('PS build manifest must be an object')
    selected = ps_build.get('diagnostic_model_header')
    if not selected:
        if ps_build.get('diagnostic_model_sha256'):
            raise ValueError('PS build declares model hash without selected header')
        return {'classifier_validated': False, 'model_version': 0, 'model_kind': 0,
                'model_validated': False, 'review_id': '', 'status': 'NO_MODEL',
                'files': {}, 'evidence_source_sha256': {},
                'model_header_sha256': '', 'model_json_sha256': ''}
    if not isinstance(selected, str):raise ValueError('Selected model header must be a path')
    header = Path(selected)
    if not header.is_absolute():header = ROOT/header
    header = header.resolve();paired = header.with_suffix('.json')
    if header.suffix.lower() != '.h' or not header.is_file() or not paired.is_file():
        raise ValueError('Selected model needs actual paired .h/.json artifacts; re-export instead of inventing parameters')
    expected_sha = ps_build.get('diagnostic_model_sha256')
    if not _sha_string(expected_sha) or _sha(header) != expected_sha:
        raise ValueError('Selected diagnostic header differs from PS build SHA256')
    paired_digest = _sha(paired)
    document = _read_json(paired)
    if _sha(paired) != paired_digest:raise ValueError('Paired model JSON changed during inspection')
    if not isinstance(document, dict):raise ValueError('Paired model artifact must be an object')
    # Import only the known repository exporter; no input names executable code.
    pc = str(ROOT/'pc')
    if pc not in sys.path:sys.path.insert(0, pc)
    from circular9_dataset import FEATURE_PIPELINE, export_header, read_rows, validate
    model = document.get('model');_model_shape(model, FEATURE_PIPELINE)
    if header.read_bytes() != export_header(model).encode('utf-8'):
        raise ValueError('Complete model header differs from known exporter output')
    train_path, train, train_ids = _dataset(document, 'train', read_rows)
    labels = ('normal', 'fault', 'interference') if model['kind'] == 2 else ('normal',)
    if model['kind'] == 1 and any(r['label'] != 'normal' for r in train):
        raise ValueError('Normal baseline contains non-normal training labels')
    for label in labels:
        rows = [r for r in train if r['label'] == label]
        if len(rows) < 3 or len({r['recording_id'] for r in rows}) < 2:
            raise ValueError('Each trained class requires>=3segments from>=2recordings')
    actual_masks = {tuple(r['separation_usable_mask']) for r in train}
    if actual_masks != {tuple(mask) for mask in model['allowed_masks']}:
        raise ValueError('Model separation mask domain differs from training data')
    if min(r['shaft_hz'] for r in train) != model['shaft_hz_min'] or max(r['shaft_hz'] for r in train) != model['shaft_hz_max']:
        raise ValueError('Model RPM domain differs from training data')
    evidence = {str(train_path): document['train_sha256']}
    report = document.get('validation');actual_report=None;validation_ids=set()
    if report is not None:
        validation_path, holdout, validation_ids = _dataset(document, 'validation', read_rows)
        if train_ids & validation_ids:raise ValueError('Training/validation original recording IDs overlap')
        # fit() uses tuples; recover that representation after strict JSON shape
        # validation so known validate() checks actual masks, not list/tuple type.
        native_model = deepcopy(model);native_model['allowed_masks'] = [tuple(mask) for mask in model['allowed_masks']]
        actual_report = validate(native_model, train, holdout)
        if report != actual_report:
            raise ValueError('Declared independent validation differs from recomputed actual source evidence')
        evidence[str(validation_path)] = document['validation_sha256']
        limits = document.get('requested_limits')
        if not isinstance(limits, dict) or any(not _number(limits.get(key)) or not 0 < limits[key] <= 1 for key in ('precision', 'recall')):
            raise ValueError('Explicit precision/recall validation limits required')
        passed = all(m['segments'] >= 3 and m['recordings'] >= 2 and m['precision'] >= limits['precision'] and m['recall'] >= limits['recall'] for m in actual_report['classes'])
        if type(document.get('validation_passed_requested_limits')) is not bool or document['validation_passed_requested_limits'] != passed:
            raise ValueError('Validation pass claim differs from recomputed requested limits')
    reviewed = model['validated'] == 1
    review_id = document.get('review_id')
    if reviewed:
        if document.get('status') != 'VALIDATED_FOR_REVIEWED_TEST_DOMAIN' or not isinstance(review_id, str) or not review_id.strip() or actual_report is None:
            raise ValueError('Validated model requires actual independent validation and explicit review ID')
        limits = document['requested_limits']
        if limits['precision'] < .95 or limits['recall'] < .90 or document['validation_passed_requested_limits'] is not True:
            raise ValueError('Reviewed release requires precision>=.95 and recall>=.90 thresholds')
        if any(m['segments'] < 3 or m['recordings'] < 2 or m['precision'] < .95 or m['recall'] < .90 for m in actual_report['classes']):
            raise ValueError('Reviewed independent recordings do not meet release accuracy/count limits')
    elif document.get('status') != 'UNVALIDATED':
        raise ValueError('Unvalidated runtime model cannot claim reviewed artifact status')
    if _sha(header) != expected_sha or _sha(paired) != paired_digest or any(_sha(Path(path)) != digest for path, digest in evidence.items()):
        raise ValueError('Model artifacts or feature-source evidence changed during inspection')
    return {'classifier_validated': reviewed and model['kind'] == 2,
            'model_version': model['version'], 'model_kind': model['kind'],
            'model_validated': reviewed, 'review_id': review_id.strip() if reviewed else '',
            'status': 'REVIEWED_CLASSIFIER' if reviewed and model['kind'] == 2 else 'REVIEWED_BASELINE' if reviewed else 'UNVALIDATED_DEBUG_MODEL',
            'model_header_sha256': expected_sha, 'model_json_sha256': paired_digest,
            'files': {'diagnostic_model.h': header, 'diagnostic_model.json': paired},
            'evidence_source_sha256': evidence,
            'train_recordings': sorted(train_ids), 'validation_recordings': sorted(validation_ids),
            'validation': actual_report}
