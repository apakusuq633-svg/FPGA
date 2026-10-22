"""Check saved convergence evidence and preservation of the production RTL baseline."""
from pathlib import Path
import csv, hashlib, json, re

R = Path(__file__).resolve().parents[1]
O = R / 'build/pdm_convergence'
baseline = json.loads((O/'baseline/hashes.json').read_text(encoding='utf-8-sig'))
changed = []
rtl_count = 0
for entry in baseline:
    name = entry['Path'].replace('\\', '/')
    actual = hashlib.sha256((R/name).read_bytes()).hexdigest()
    if actual.lower() != entry['SHA256'].lower():
        changed.append(name)
    if name.startswith('rtl/'):
        assert actual.lower() == entry['SHA256'].lower(), name
        rtl_count += 1
prior = json.loads((R/'build/pdm_shared_remediation/regression/source_manifest.json').read_text())
prior_rtl = 0
for name, digest in prior.items():
    if name.startswith('rtl/'):
        assert hashlib.sha256((R/name).read_bytes()).hexdigest().lower() == digest.lower(), name
        prior_rtl += 1

sta = {}
for scenario in ['nominal125', 'late_setup_negative', 'early_hold_negative']:
    rows = list(csv.DictReader((O/'external_final'/scenario/'paths.csv').open()))
    assert len(rows) == 24
    for group in ['A', 'B']:
        for kind in ['max', 'min']:
            selected = [r for r in rows if r['group']==group and r['kind']==kind]
            assert len(selected) == 6
            for row in selected:
                assert not row['exception'], row
                assert float(row['requirement']) == (125 if kind=='max' else -75)
                assert float(row['source_clock_delay']) > 0
                assert float(row['capture_clock_delay']) > 0
                negative = (scenario=='late_setup_negative' and kind=='max') or (scenario=='early_hold_negative' and kind=='min')
                assert (float(row['slack']) < 0) == negative, row
    sta[scenario] = (O/'external_final'/scenario/'summary.txt').read_text().splitlines()

phases = {}
for ns in [125, 150, 175]:
    path = O/'phase_impl'/str(ns)
    rows = list(csv.DictReader((path/'external_window/paths.csv').open()))
    assert len(rows)==24 and all(float(r['slack'])>0 for r in rows)
    assert all(float(r['requirement'])==(ns if r['kind']=='max' else ns-200) for r in rows)
    report = (path/'internal_timing.rpt').read_text()
    match = re.search(r'WNS\(ns\).*?\n\s*-.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)',report,re.S)
    assert match and float(match[1])>0 and float(match[3])>0 and float(match[2])==float(match[4])==0
    phases[str(ns)]={'external':(path/'external_window/summary.txt').read_text().splitlines(), 'internal_WNS':float(match[1]),'internal_WHS':float(match[3])}

function=json.loads((O/'function_final/results.json').read_text())
startup=json.loads((O/'startup_regression/results.json').read_text())
assert len(function)==14 and all(r['status']=='PASS' for r in function)
assert len(startup)==11 and all(r['status']=='PASS' for r in startup)
axi=(O/'ps_axi_final.log').read_text()
assert 'PDM_PS_FIRSTFRAME_PASS epochs=3 words=288' in axi and 'PDM_INTEGRATION_PASS' in axi
before=json.loads((O/'ps_c_before/results.json').read_text())
after=json.loads((O/'ps_c_final/results.json').read_text())
assert before[-1]['returncode']==2 and 'early_measure=1' in before[-1]['summary']
assert all(r['returncode']==r['expected']==0 for r in after)
assert 'PS_PDM_DEAD_STARTUP_BOUNDED_PASS' in after[-1]['summary']
m6=json.loads((O/'m6_diagnostic/results.json').read_text())
assert len(m6)==6 and all(r['status']=='PASS' for r in m6)
assert 'M6_XSIM_PASS' in (O/'m6_xsim_retry.log').read_text(encoding='utf-16')
for mode in range(4):
    log=(O/'m6_xsim'/f'run{mode}.log').read_text(encoding='utf-16')
    assert 'PDM12_SYNC_PASS' in log and 'FATAL' not in log
for logfile, marker in [('external_final.log','PDM_EXTERNAL_STA_ANALYSIS_DONE'),('phase_impl.log','PDM_PHASE_COMPARISON_DONE'),('probe_retry.log','PDM_CONVERGENCE_PROBE_DONE')]:
    assert marker in (O/logfile).read_text(errors='replace')
resources=json.loads((O/'resources/attribution.json').read_text())
assert sum(r['BRAM36_equiv'] for r in resources['owners'])==111.5
result={'status':'PASS_SOFTWARE_CONDITIONAL_STA','hardware':'UNVERIFIED_HARDWARE', 'unchanged_baseline_RTL_files':rtl_count,'unchanged_prior_RTL_files':prior_rtl,'modified_baseline_files':changed,'full_soc_external':sta,'isolated_phases':phases,'functional_cases':14,'startup_cases':11,'M6_digital_cases':6,'M6_native_xsim_cases':4,'AXI_epochs':3,'PS_C_before_rejected':True,'PS_C_after_normal_and_dead_pass':True,'BRAM36_equiv':111.5}
(O/'acceptance.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
print('PDM_CONVERGENCE_ACCEPTANCE_PASS')
