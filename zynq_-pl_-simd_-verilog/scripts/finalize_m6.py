"""Read evidence, fail closed, and bind the M6 digital release without touching M5."""
from pathlib import Path
import argparse,collections,hashlib,json,re,subprocess
p=argparse.ArgumentParser();p.add_argument('--preflight',action='store_true');a=p.parse_args()
R=Path(__file__).resolve().parents[1];O=R/'build/m6_20261016'
V=R/'build/zynq12_integrated_plan/m6_regression_20261016';S=V/'safety'
I=R/'build/zynq12_integrated_plan/m6_impl_20261016'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def read_log(p):
    b=p.read_bytes()
    return b.decode('utf-16' if b.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8',errors='replace')
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def source_check(mapping):
    for p,h in mapping.items():assert sha(R/p)==h,('SOURCE_DRIFT',p)
def case(name):
    d=read(S/(name+'_summary.json'));assert d['status']=='PASS';return d['results'][0]
assert not (O/'acceptance.json').exists(),'Use a new release directory rather than overwrite'
q=subprocess.run(['python3','scripts/verify_integrated_release.py'],cwd=R,capture_output=True,text=True)
(O/('m5_handoff_preflight.log' if a.preflight else 'm5_handoff_verification.log')).write_text(q.stdout+q.stderr);assert q.returncode==0
before=read(O/'before_hashes.json');unchanged=[]
for row in before:
    # Snapshot contains Windows absolute paths; retain a portable local suffix.
    rel=row['Path'].replace('\\','/').split('/zynq_-pl_-simd_-verilog/',1)[1]
    assert sha(R/rel)==row['Hash'].lower(),('PREEXISTING_SOURCE_CHANGED',rel)
    unchanged.append(rel)
source_check(read(S/'sources.json'));source_check(read(O/'auxiliary/source_manifest.json'))
source_check(read(O/'implementation_sources.json'));source_check(read(O/'sync_final/sources.json'))
sync=read(O/'sync_final/results.json');assert len(sync)==6 and all(x['status']=='PASS' for x in sync)
for mode in range(4):
    text=read_log(R/f'build/m6_20261016_xsim_verified/run{mode}.log')
    assert 'PDM12_SYNC_PASS' in text and 'FATAL' not in text
aux=read(O/'auxiliary/metrics.json');assert len(aux)==19 and all(x['status']=='PASS' for x in aux)
model=read(O/'model528/metrics.json');assert model['status']=='PASS' and model['scenarios']==528
acoustic=read(O/'acoustic/results.json');assert acoustic['status']=='PASS_MODEL'
normal=case('normal1024');long_path=V/'extended4096/metrics.json'
long=None if a.preflight and not long_path.exists() else read(long_path)
for d,n in [(normal,1024)]+([(long,4096)] if long is not None else []):
    assert d['status']=='PASS' and d['windows']==n and d['raw_checks']==n*12*1024*3
    assert d['raw_drop']==d['window_drop']==d['audio_drop']==0
    assert d['max_latency']==393217 and d['max_compute']<=323463
matrix=read(S/'matrix183_summary.json');assert matrix['status']=='PASS' and len(matrix['results'])==183
counts=dict(collections.Counter(x['status'] for x in matrix['results']))
assert counts=={'PASS':128,'CORRECT_LATE':2,'EXPLICIT_LOSS':53},counts
for k in range(4):
    t=(V/f'physical{k}_rtl.log').read_text();assert 'all_scores_checked=1024' in t
dtcm=read(O/'dtcm_real/dtcm50000_summary.json')['results'][0]
assert dtcm['status']=='PASS' and dtcm['dtcm_blocked']==50000
runs=read(V/'runs.json');assert len(runs)==22 and all(x['status']=='PASS' for x in runs),(len(runs),runs[-1])
assert len(read(V/'rv32/summary.json'))==9
xsim=(R/'build/pdm12_runs/m6_soc_xsim_20261016/simulation.log').read_text(errors='replace')
assert 'LOCALIZER12_SOC_PASS windows=4' in xsim
flow=(I/'implementation.log').read_text(errors='replace');assert re.search(r'^FLOW_PASS',flow,re.M)
assert 'M6_ROUTED_AUDIT_PASS' in (O/'routed_audit.log').read_text(errors='replace')
check=(O/'routed_audit/check_timing.rpt').read_text()
assert re.search(r'There (?:are|is) 0 .*not constrained for maximum delay',check),check[-3000:]
def cdc_rows(p):
    return [' '.join(t.split()[1:]) for t in p.read_text().splitlines() if re.match(r'\s*\d+\s+CDC-',t)]
cdc=cdc_rows(O/'routed_audit/cdc.rpt');old_cdc=cdc_rows(O/'m5_routed_audit/cdc.rpt')
assert len(cdc)==12 and cdc==old_cdc,('CDC_CHANGED',cdc,old_cdc)
assert all('False Path pdm_din_i[' in t for t in cdc),cdc
timing=(I/'timing_zynq.rpt').read_text();sta={}
for label,key in [('Setup','wns_ns'),('Hold','whs_ns')]:
    m=re.search(label+r'\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+([-\d.]+)ns',timing)
    assert m and float(m[1])>=0;sta[key]=float(m[1])
sta.update(tns_ns=0,ths_ns=0)
resources={};t=(I/'util_zynq.rpt').read_text()
for label,key in [('Slice LUTs','lut'),('Slice Registers','ff'),('Block RAM Tile','bram36'),('DSPs','dsp')]:
    m=re.search(r'\|\s*'+label+r'\*?\s*\|\s*([\d.]+)',t);assert m;resources[key]=float(m[1])
old=read(R/'build/zynq12_integrated_plan/reports/final/acceptance.json')
if a.preflight:
    print('M6_PREFLIGHT_PASS long4096='+('PASS' if long is not None else 'IN_PROGRESS')+' release_not_generated=1')
    raise SystemExit(0)
data={'stage':'M6','status':'PASS_SIM_IMPL','hardware':'UNVERIFIED_HARDWARE',
 'scope':'12ch / FFT1024 / Hop512 / 66pairs / 1024grid / 40MHz',
 'production_rtl_modified':False,'preexisting_files_unchanged':len(unchanged),
 'sync':sync,'model_scenarios':528,'normal1024':normal,'long4096':long,'stress_classifications':counts,
 'auxiliary':aux,'runs':runs,'dtcm':dtcm,'timing':sta,'resources':resources,
 'cdc':{'new_paths':0,'unchanged_external_pdm_critical_paths':12,'external_timing_hardware_validated':False},
 'timing_delta_vs_m5':{k:sta[k]-old['timing'][k] for k in ('wns_ns','whs_ns')},
 'deferred':['physical part marking','12-microphone DATA/LR/CLK wiring','electrical window and startup','real acoustic accuracy']}
(O/'acceptance.json').write_text(json.dumps(data,indent=2))
paths=set()
for directory in [O,V,I,R/'build/m6_20261016_xsim_verified',R/'build/pdm12_runs/m6_soc_xsim_20261016']:
    paths.update(p for p in directory.rglob('*') if p.is_file() and p.suffix.lower() in ('.json','.log','.rpt','.md','.txt','.csv','.bit','.xsa','.elf','.hex','.jou'))
paths.update(R/p for p in ['tb/tb_pdm12_sync.v','scripts/check_pdm12_sync.py','scripts/check_pdm12_acoustic.py','scripts/check_pdm12_xsim.ps1','scripts/audit_m6_inputs.py','scripts/audit_m6_routed.tcl','scripts/finalize_m6.py','docs/M6_PDM同步审计_2026-10-16.md'])
paths.update(R/p for p in unchanged)
paths.add(R/'build/zynq12_integrated_plan/m6_impl_20261016_project/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit')
paths.add(I/'das_fir_routed.dcp')
manifest={'status':'PASS_SIM_IMPL','hardware':'UNVERIFIED_HARDWARE','files':[{'path':str(p.relative_to(R)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(paths)]}
(O/'release_manifest.json').write_text(json.dumps(manifest,indent=2))
print('M6_RELEASE_PASS',json.dumps({'timing':sta,'resources':resources,'stress':counts,'files':len(paths)}))
