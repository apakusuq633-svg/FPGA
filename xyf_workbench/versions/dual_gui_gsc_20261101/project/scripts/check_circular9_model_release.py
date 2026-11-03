"""Synthetic-only checks for the model release gate, never a physical model."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import tempfile

from circular9_model_release import ROOT, inspect_model_release
sys.path.insert(0, str(ROOT/'pc'))
from circular9_dataset import CONTRACT, SEPARATION_CONTRACT, export_header, fit, validate

OUT = ROOT/'build/circular9_model_release_checks'


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def fixture(prefix):
    rows = []
    for label, center in (('normal', 0), ('fault', 10), ('interference', -10)):
        for k in range(6):
            rows.append({'feature_contract': CONTRACT, 'separation_contract': SEPARATION_CONTRACT,
                         'label': label, 'recording_id': f'SYNTHETIC_ONLY_{prefix}_{label}_{k//3}',
                         'features': [center+(k%3-1)*.1]*18, 'shaft_hz': 25, 'rms': .1,
                         'extraction': {'status': 1}, 'separation_usable_mask': [0xffffffff]*6+[1023],
                         'binding': {'track_id': 1, 'epoch': 3, 'first_sample': k*200000,
                                     'sample_count': 40000, 'flags': 15}})
    return rows


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    checks = 0
    def check(value, description):
        nonlocal checks
        checks += 1
        if not value:raise AssertionError(description)
    def rejects(function, description):
        nonlocal checks
        checks += 1
        try:function()
        except (ValueError, OSError, KeyError, TypeError):return
        raise AssertionError('accepted '+description)
    check(inspect_model_release({})['classifier_validated'] is False, 'absent model preserves guarded capture/development release')
    check(inspect_model_release({})['files'] == {} and inspect_model_release({})['model_version'] == 0, 'no model cannot fabricate artifact/version')
    rejects(lambda: inspect_model_release({'diagnostic_model_sha256': '0'*64}), 'unselected model digest')
    with tempfile.TemporaryDirectory(prefix='c9_model_SYNTHETIC_ONLY_') as name:
        directory = Path(name)
        train, holdout = fixture('train'), fixture('holdout')
        train_path, validation_path = directory/'synthetic_train.jsonl', directory/'synthetic_validation.jsonl'
        def rows_file(path, rows):path.write_text(''.join(json.dumps(row)+'\n' for row in rows), encoding='utf-8')
        rows_file(train_path, train);rows_file(validation_path, holdout)
        def artifact(training, validation, *, baseline=False, reviewed=True):
            rows_file(train_path, training)
            if validation is not None:rows_file(validation_path, validation)
            model = fit(training, baseline=baseline, version=0x54455354)
            model['validated'] = int(reviewed)
            document = {'model': model, 'train_source_path': str(train_path.resolve()),
                        'train_sha256': sha(train_path), 'train_recordings': sorted({r['recording_id'] for r in training}),
                        'status': 'VALIDATED_FOR_REVIEWED_TEST_DOMAIN' if reviewed else 'UNVALIDATED',
                        'review_id': 'SYNTHETIC_SOFTWARE_GATE_FIXTURE_ONLY' if reviewed else None,
                        'fixture': 'Synthetic software contract check only. No real microphone/model validation.'}
            if validation is not None:
                report = validate(model, training, validation)
                document.update(validation=report, validation_source_path=str(validation_path.resolve()),
                                validation_sha256=sha(validation_path),
                                validation_recordings=sorted({r['recording_id'] for r in validation}),
                                validation_passed_requested_limits=all(c['segments'] >= 3 and c['recordings'] >= 2 and c['precision'] >= .95 and c['recall'] >= .90 for c in report['classes']),
                                requested_limits={'precision': .95, 'recall': .90})
            return document
        header = directory/'SYNTHETIC_ONLY_model.h';paired = header.with_suffix('.json')
        def save(document, header_bytes=None):
            paired.write_text(json.dumps(document, allow_nan=False, indent=2)+'\n', encoding='utf-8')
            header.write_bytes(export_header(document['model']).encode('utf-8') if header_bytes is None else header_bytes)
            return {'diagnostic_model_header': str(header), 'diagnostic_model_sha256': sha(header)}
        document = artifact(train, holdout)
        build = save(document)
        accepted = inspect_model_release(build)
        check(accepted['classifier_validated'] is True and accepted['model_version'] == 0x54455354, 'positive fixture exercises a reviewed three-class release gate')
        check(accepted['review_id'] == 'SYNTHETIC_SOFTWARE_GATE_FIXTURE_ONLY', 'review identity is retained exactly')
        check(accepted['files'] == {'diagnostic_model.h': header, 'diagnostic_model.json': paired}, 'copy set is the actual paired model artifacts')
        check(accepted['model_header_sha256'] == sha(header) and accepted['model_json_sha256'] == sha(paired), 'both actual artifacts have bound digests')
        check(accepted['evidence_source_sha256'] == {str(train_path): sha(train_path), str(validation_path): sha(validation_path)}, 'actual source dataset digests form the external evidence allowlist')
        unvalidated = artifact(train, holdout, reviewed=False)
        check(inspect_model_release(save(unvalidated))['classifier_validated'] is False, 'successful unreviewed validation still cannot qualify a fault classifier')
        unvalidated = artifact(train, None, reviewed=False)
        check(inspect_model_release(save(unvalidated))['classifier_validated'] is False, 'unvalidated training-only model remains controlled debug only')
        normal_train = [r for r in train if r['label'] == 'normal']
        normal_holdout = [r for r in holdout if r['label'] == 'normal']
        baseline = artifact(normal_train, normal_holdout, baseline=True)
        state = inspect_model_release(save(baseline))
        check(not state['classifier_validated'] and state['model_kind'] == 1 and state['model_validated'], 'reviewed normal baseline can never become a fault classifier')
        document = artifact(train, holdout);build = save(document)
        original_header, original_json = header.read_bytes(), paired.read_bytes()
        paired.unlink();rejects(lambda: inspect_model_release(build), 'missing paired model JSON');paired.write_bytes(original_json)
        wrong = dict(build, diagnostic_model_sha256='0'*64);rejects(lambda: inspect_model_release(wrong), 'header not matching PS compiled digest')
        wrong = dict(build, diagnostic_model_sha256='NOT_A_SHA');rejects(lambda: inspect_model_release(wrong), 'invalid PS model SHA format')
        injected = original_header+b'/* not from exporter */\nint injected(void){return 1;}\n'
        wrong = save(document, injected);rejects(lambda: inspect_model_release(wrong), 'extra arbitrary C even when PS digest matches')
        wrong = save(document, original_header.replace(b'\n', b'\r\n'));rejects(lambda: inspect_model_release(wrong), 'noncanonical whole-header bytes')
        build = save(document)
        for key, value in [('abi', True), ('abi', 1), ('feature_contract', 0x43394631),
                           ('separation_contract', 0x43395331), ('separation_contract', 0x43395332), ('version', 0), ('version', True),
                           ('kind', 0), ('validated', True), ('classes', 2), ('mask_count', 0),
                           ('shaft_hz_min', 9), ('rms_min', 0), ('minimum_margin', 1),
                           ('center', [[0]*18]*2), ('inverse_variance', [0]*18),
                           ('allowed_masks', [[0]*7])]:
            bad = deepcopy(document);bad['model'][key] = value
            paired.write_text(json.dumps(bad)+'\n', encoding='utf-8')
            rejects(lambda: inspect_model_release(build), 'invalid model '+key)
        for mutate, label in [
            (lambda d: d.pop('train_source_path'), 'legacy missing training source path'),
            (lambda d: d.pop('validation_recordings'), 'legacy missing holdout recording IDs'),
            (lambda d: d.__setitem__('train_sha256', 'x'*64), 'invalid dataset SHA format'),
            (lambda d: d.__setitem__('validation_sha256', '0'*64), 'validation source SHA mismatch'),
            (lambda d: d.__setitem__('validation_recordings', ['invented']), 'forged validation recording IDs'),
            (lambda d: d.__setitem__('train_recordings', ['invented']), 'forged training recording IDs'),
            (lambda d: d.__setitem__('review_id', ''), 'missing explicit review ID'),
            (lambda d: d.__setitem__('status', 'UNVALIDATED'), 'inconsistent reviewed runtime/status'),
            (lambda d: d.__setitem__('validation_passed_requested_limits', False), 'forged validation pass result'),
            (lambda d: d['validation']['classes'][1].__setitem__('precision', .99), 'forged numerical validation metric'),
            (lambda d: d['requested_limits'].__setitem__('precision', .80), 'weaker-than-release precision threshold'),
            (lambda d: d['requested_limits'].__setitem__('recall', .80), 'weaker-than-release recall threshold'),
        ]:
            bad = deepcopy(document);mutate(bad);build = save(bad)
            rejects(lambda: inspect_model_release(build), label)
        build = save(document)
        train_bytes = train_path.read_bytes();train_path.write_bytes(train_bytes+b'\n')
        rejects(lambda: inspect_model_release(build), 'training dataset changed after export');train_path.write_bytes(train_bytes)
        validation_bytes = validation_path.read_bytes();validation_path.unlink()
        rejects(lambda: inspect_model_release(build), 'original validation dataset removed');validation_path.write_bytes(validation_bytes)
        overlap = deepcopy(holdout)
        overlap[0]['recording_id'] = train[0]['recording_id']
        # Known validation itself rejects the overlap; write an otherwise valid
        # artifact with actual altered source digest to exercise release checking.
        rows_file(validation_path, overlap)
        bad = deepcopy(document);bad['validation_sha256'] = sha(validation_path)
        bad['validation_recordings'] = sorted({r['recording_id'] for r in overlap})
        build = save(bad);rejects(lambda: inspect_model_release(build), 'actual original recording overlap')
        poor = deepcopy(holdout)
        for row in poor:
            if row['label'] == 'fault':row['features'] = [0]*18
        bad = artifact(train, poor)
        build = save(bad);rejects(lambda: inspect_model_release(build), 'recomputed weak actual recall/precision')
        bad = artifact(train, holdout[:3]);build = save(bad)
        rejects(lambda: inspect_model_release(build), 'insufficient independent holdout segments/recordings per class')
        document = artifact(train, holdout);build = save(document)
        text = paired.read_text(encoding='utf-8');paired.write_text('{"model":{},'+text[1:], encoding='utf-8')
        rejects(lambda: inspect_model_release(build), 'duplicate JSON keys')
        paired.write_text(text.replace('"version": 1413829460', '"version": NaN'), encoding='utf-8')
        rejects(lambda: inspect_model_release(build), 'nonfinite JSON parameter')
        paired.write_text(text, encoding='utf-8')
        check(inspect_model_release(build)['classifier_validated'], 'independent rejection cases restore the positive fixture exactly')
    evidence = {'passed': True, 'real_model_validated': False, 'hardware_tested': False,
                'fixture': 'explicit synthetic three-class/baseline feature rows and review token in disposable external directory; only release software gates tested; no production model artifact created',
                'checks': checks,
                'sources': {path: hashlib.sha256((ROOT/path).read_bytes()).hexdigest() for path in
                            ['scripts/circular9_model_release.py', 'scripts/check_circular9_model_release.py', 'pc/circular9_dataset.py']}}
    (OUT/'results.json').write_text(json.dumps(evidence, indent=2)+'\n')
    print(f'CIRCULAR9_MODEL_RELEASE_CHECK_PASS checks={checks} real_model_validated=0 production_model_created=0')


if __name__ == '__main__':main()
