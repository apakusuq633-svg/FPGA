"""Fail-closed experiment acceptance: no automatic production promotion."""
from pathlib import Path
from collections import Counter
import csv,hashlib,json,re
R=Path(__file__).resolve().parents[1];O=R/'build/pdm_acceptance_next'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
baseline=json.loads((O/'baseline/hashes.json').read_text(encoding='utf-8-sig'))
unchanged=0;changed=[]
for row in baseline:
 name=row['Path'].replace('\\','/');same=sha(R/name).lower()==row['SHA256'].lower()
 if name.startswith('rtl/') or name.startswith('constrs/'):
  assert same,name
  if name.startswith('rtl/'):unchanged+=1
 if not same:changed.append(name)
assert unchanged==63
project=json.loads((O/'project_gate_final/acceptance.json').read_text());assert project['ps_cases']==12 and project['checks']==24
assert (O/'external_gate_negative_exit.txt').read_text(encoding='utf-8-sig').strip()=='1'
faults=json.loads((O/'gate_selftest/results.json').read_text());assert len(faults)==5 and all(x['status']=='PASS' for x in faults)
numeric=json.loads((O/'ram_numeric/results.json').read_text());assert len(numeric)==3 and all(x['status']=='PASS' for x in numeric)
standalone=json.loads((O/'ram_localizer_numeric/results.json').read_text());assert standalone['status']=='PASS' and 'OVERLAP_LOCALIZER_NUMERIC_PASS windows=4' in standalone['summary']
stats=[]
for variant in ['baseline','combined']:
 path=O/f'ram_sim_{variant}'
 summary=json.loads((path/'continuous64_summary.json').read_text());assert summary['status']=='PASS'
 model_sources=json.loads((path/'sources.json').read_text())
 for name,digest in model_sources.items():assert sha(R/name)==digest,name
 model_manifest=json.loads((path/'manifest.json').read_text())
 for name,digest in model_manifest['test_only_instrumented'].items():assert sha(path/'instrumented'/name)==digest,name
 s=summary['results'][0];assert s['status']=='PASS' and s['windows']==64 and s['raw_checks']==64*12*1024*3
 assert s['raw_drop']==s['window_drop']==s['audio_drop']==s['gsc_overflow']==0
 assert s['audio_in']==s['audio_out'] and s['max_gap']==524288 and s['strict_deadline'] and s['fixed_phase']
 stats.append(s)
for key in ['raw_checks','max_compute','max_latency','audio_in','audio_out','min_margin','max_gap']:assert stats[0][key]==stats[1][key],key
source_manifest=json.loads((O/'ram_soc_combined/source_manifest.json').read_text(encoding='utf-8-sig'))
for name,digest in source_manifest.items():assert sha(R/name)==digest,name
for name in ['rv32_srp_scan.v','rv32_overlap_localizer.v']:
 target=str((O/'ram_candidates/combined'/name).relative_to(R));assert source_manifest[target]==sha(R/target)
actual=list(csv.DictReader((O/'ram_audit/bram.csv').open()))
counts=Counter(r['primitive'] for r in actual)
tiles=counts['RAMB36E1']+counts['RAMB18E1']/2
assert tiles<111.5
route=(O/'ram_audit/route.rpt').read_text()
match=re.search(r'# of nets with routing errors\.*\s*:\s*(\d+)',route);assert match and int(match[1])==0
routeable=re.search(r'# of routable nets\.*\s*:\s*(\d+)',route)
routed=re.search(r'# of fully routed nets\.*\s*:\s*(\d+)',route)
assert routeable and routed and routeable[1]==routed[1]
drc=(O/'ram_audit/drc.rpt').read_text()
assert not re.search(r'\|\s*(?:Error|Critical Warning)\s*\|',drc),'DRC errors require review'
timing=(O/'ram_soc_combined/timing.rpt').read_text()
m=re.search(r'WNS\(ns\).*?\n\s*-.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)',timing,re.S)
assert m and float(m[1])>=0 and float(m[3])>=0 and float(m[2])==float(m[4])==0
external=json.loads((O/'ram_external/acceptance.json').read_text());assert external['checks']==24 and external['status']=='PASS_CONDITIONAL'
assert external['checkpoint_sha256']==sha(O/'ram_soc_combined/routed.dcp')
arm=json.loads((O/'project_gate_final/arm/manifest.json').read_text(encoding='utf-8-sig'));assert arm['source_sha256']==sha(R/'sw/ps_pdm.c') and arm['status']=='PASS_COMPILE_LINK_ONLY'
assert arm['elf_sha256']==sha(O/'project_gate_final/arm/ps_pdm.elf')
owned={'scripts/check_localizer12_safety.py','scripts/check_pdm_external_sta.tcl','scripts/check_ps_pdm_startup.py','scripts/create_zynq_project.tcl','scripts/pdm_external_window.tcl','sw/ps_pdm.c','docs/issues/README.md','docs/measurements.md','docs/pdm_external_window.md'}
result=dict(status='PASS_ISOLATED_EXPERIMENT',production_promotion='NOT_PERFORMED',hardware='UNVERIFIED_HARDWARE',production_RTL_unchanged=unchanged,production_XDC_unchanged=True,modified_baseline_files=changed,other_observed_workspace_changes=[x for x in changed if x not in owned],BRAM_before=111.5,BRAM_after=tiles,BRAM_saved=111.5-tiles,full_soc_WNS=float(m[1]),full_soc_WHS=float(m[3]),windows=64,raw_checks=stats[1]['raw_checks'],max_compute=stats[1]['max_compute'],max_latency=stats[1]['max_latency'],external_setup=external['setup_min_ns'],external_hold=external['hold_min_ns'])
(O/'final_acceptance.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2));print('PDM_NEXT_STAGE_EXPERIMENT_ACCEPTANCE_PASS')
