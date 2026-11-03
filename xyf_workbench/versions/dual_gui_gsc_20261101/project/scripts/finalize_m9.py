"""Fail-closed M9 release gate. --preflight cannot create acceptance/manifest."""
from pathlib import Path
import argparse,collections,hashlib,json,re,struct
p=argparse.ArgumentParser();p.add_argument('--preflight',action='store_true');a=p.parse_args()
R=Path(__file__).resolve().parents[1];O=R/'build/m9_merge_20261016'
V=R/'build/zynq12_integrated_plan/m9_merge_regression_20261016';S=V/'safety'
I=R/'build/zynq12_integrated_plan/m9_merge_impl_20261016'
OFF=R/'build/zynq12_integrated_plan/m9_merge_off_impl_20261016'
def read(f):return json.loads(f.read_text(encoding='utf-8-sig'))
def log(f):
 b=f.read_bytes();return b.decode('utf-16' if b.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig',errors='replace')
def sha(f):
 h=hashlib.sha256()
 with f.open('rb')as stream:
  for b in iter(lambda:stream.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
def source_check(mapping):
 for path,value in mapping.items():assert sha(R/path)==value,('SOURCE_DRIFT',path)
def metrics(directory,status):
 value=read(directory/'metrics.json');assert value['status']==status,(directory,value['status']);return value
assert not (O/'acceptance.json').exists(),'Use a new release; do not replace acceptance'
allowed={'rtl/array/rv32_gsc_tap.v','rtl/array/rv32_pdm_array_rx.v','rtl/array/rv32_pdm_clkgen.v',
 'rtl/soc/rv32_soc.v','rtl/soc/rv32_ps_top.v','constrs/ps_pl_wrapper.xdc',
 'scripts/create_zynq_project.tcl','scripts/filelist.f','scripts/golden/pdm_decim.py',
 'tb/tb_pdm_array_rx.v','tb/tb_pdm_capture.v','scripts/check_pdm12_sync.py','scripts/check_pdm12_xsim.ps1',
 'sw/ps_pdm.c','scripts/check_pdm_pins.py'}
before={row['Path'].replace('\\','/').split('/zynq_-pl_-simd_-verilog/',1)[1]:row['Hash'].lower()
        for row in read(R/'build/m9_20261016/before_hashes.json') if '__pycache__' not in row['Path']}
changed={path for path,value in before.items() if sha(R/path)!=value}
assert changed==allowed,('UNEXPECTED_PREEXISTING_CHANGES',changed^allowed)
merged=read(O/'merged_sources.json')
for path in ['scripts/create_zynq_project.tcl','scripts/filelist.f','scripts/connect_stream_dma.tcl',
             'scripts/run_zynq_flow.tcl','scripts/ps7_config.tcl']:
 assert sha(R/path)==merged[path],('BUILD_SCRIPT_CHANGED',path)
now={str(f.relative_to(R)):sha(f) for folder in ('rtl','configs','constrs') for f in (R/folder).rglob('*') if f.is_file()}
implemented=read(I/'source_manifest.json')
assert set(now)==set(implemented)
assert {path for path in now if now[path]!=implemented[path]}=={'constrs/ps_pl_wrapper.xdc'}
proof=read(O/'constraint_equivalence.json')
assert proof['status']=='EXACT_ACTIVE_PROFILE_COMMANDS_EQUAL'
assert sha(R/proof['template'])==proof['current_template_sha256']
assert sha(R/proof['generated_profile'])==proof['generated_profile_sha256']
# Re-evaluate rather than trusting the recorded PASS string.
def active_commands(path,select=False):
 result=[]
 for line in path.read_text().splitlines():
  line=line.strip()
  if not line or line.startswith('#'):continue
  m=re.search(r'pdm_din_i\[(\d+)\]',line)
  if select and m and int(m[1])>=6:continue
  result.append(line)
 return result
assert active_commands(R/proof['template'],True)==active_commands(R/proof['generated_profile'])==proof['commands']
source_check(read(S/'sources.json'));source_check(read(O/'auxiliary/source_manifest.json'))
source_check(read(O/'shared_startup_release/sources.json'))
for path in ['sync/sources.json','dma/sources.json','software_release/sources.json','app_loop_release/sources.json']:
 source_check(read(O/path))
source_check(read(R/'build/m8_20261016/c_verified/sources.json'))
source_check(read(O/'pdm_followup_sources.json'))
assert 'PASS:' in log(O/'pins.log') and 'FAIL:' not in log(O/'pins.log')
assert 'PS_PDM_STARTUP_ORDER_PASS' in log(O/'ps_startup/run_1.log')
assert 'PS_PDM_DEAD_STARTUP_BOUNDED_PASS' in log(O/'ps_startup/run_2.log')
# Old release source paths may intentionally change, but frozen evidence and
# every unrelated source must retain their hashes. Do not relabel old netlists.
m5=read(R/'build/zynq12_integrated_plan/release_manifest.json');m5_changed=[]
supporting_docs={'docs/board_io.md','docs/measurements.md','docs/pdm_array_spec.md','docs/issues/README.md'}
recorded_changes={row['path']:row for row in read(O/'m5_changed_paths.json')}
for row in m5['files']:
 f=R/row['path']
 if sha(f)!=row['sha256']:
  assert row['path'] in allowed|supporting_docs,('M5_ARTIFACT_CHANGED',row['path'])
  if row['path'] in before:assert before[row['path']]==row['sha256']
  assert recorded_changes[row['path']]['before']==row['sha256'] and recorded_changes[row['path']]['current']==sha(f)
  m5_changed.append(row['path'])
aux=read(O/'auxiliary/metrics.json');assert len(aux)==19 and all(x['status']=='PASS' for x in aux)
sync=read(O/'sync/results.json');assert len(sync)==6 and all(x['status']=='PASS' for x in sync)
shared=read(O/'shared_startup_release/results.json');assert len(shared)==11 and all(x['status']=='PASS' for x in shared)
for mode in range(4):assert 'PDM12_SYNC_PASS' in log(R/f'build/m9_merge_20261016_pdm_xsim/run{mode}.log')
xsim=log(R/'build/pdm12_runs/m9_merge_20261016_soc_xsim/simulation.log');assert 'LOCALIZER12_SOC_PASS windows=4' in xsim
model=metrics(O/'model528','PASS');assert model['scenarios']==528
cal=metrics(O/'calibrated_rtl_release','PASS');assert len(cal['cases'])==4 and all(x['all_scores_checked']==1024 for x in cal['cases'])
source_check(read(O/'calibrated_rtl_release/driver_sources.json'))
for row in cal['cases']:
 trace=log(R/row['rtl_result']['log'])
 assert f'ACOUSTIC_RESULT grid={row["rtl_grid"]} ' in trace and 'all_scores_checked=1024' in trace
dma=metrics(O/'dma','PASS_RTL');d=dma['metrics'];assert d['inputs']==d['published']+d['drops'] and d['axi_errors']==1 and d['timeouts']==3
assert metrics(O/'timestamp','PASS')['status']=='PASS'
software=metrics(O/'software_release','PASS_SOFTWARE_LOOPBACK');assert software['normal_ring_frames']==100000
assert all(software['normal_ring_stats'][k]==0 for k in ('corrupt','ownership','io','poll_timeout','duplicates','out_of_order','sample_gaps'))
application=metrics(O/'app_loop_release','PASS_APPLICATION_MOCK');assert len(application['cases'])==4
assert application['cases'][0]['frames']==application['cases'][2]['frames']==256
assert application['cases'][2]['receiver']['gsc_active_frames']==128
assert 'sent_frames=246 discarded=9 corrupt=1' in application['cases'][1]['application_summary']
assert application['cases'][3]['frames']==100000
assert application['cases'][3]['receiver']['sample_sequence_holes']==0
assert 'discarded=0 corrupt=0' in application['cases'][3]['application_summary']
isolation=read(O/'isolation/dma_isolation_metrics.json');assert isolation['status']=='PASS_SAFE_QUARANTINE'
assert isolation['normal_result']['raw_drop']==isolation['normal_result']['window_drop']==isolation['normal_result']['audio_drop']==0
assert isolation['quarantined_transactions']==1 and isolation['dma_published']==0
assert 'M9_PLATFORM_PASS' in log(O/'platform_build.log')
arm=[]
for folder,active in [('ps_default_release',False),('ps_gsc_release',True)]:
 b=O/folder;m=read(b/'build_manifest.json');assert m['status']=='PASS_BUILD_ONLY' and m['gsc_enabled']==active
 for path,value in m['source_hashes'].items():
  if path.startswith('sw/'):assert sha(R/path)==value,(folder,path)
 assert sha(I/'das_fir.xsa')==m['source_hashes']['XSA']
 data=(b/'pdm_stream.elf').read_bytes();assert data[:4]==b'\x7fELF' and struct.unpack_from('<H',data,18)[0]==40
 assert sha(b/'pdm_stream.elf')==m['source_hashes']['ELF']
 symbols=log(b/'symbols.txt');assert 'gsc12_test_' not in symbols
 arm.append(m)
def timing(directory):
 t=log(directory/'timing_zynq.rpt');sta={}
 for label,key in [('Setup','wns_ns'),('Hold','whs_ns')]:
  m=re.search(label+r'\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+([-\d.]+)ns',t)
  assert m and float(m[1])>=0,(directory,label);sta[key]=float(m[1])
 sta.update(tns_ns=0,ths_ns=0)
 u=log(directory/'util_zynq.rpt');resources={}
 for label,key in [('Slice LUTs','lut'),('Slice Registers','ff'),('Block RAM Tile','bram36'),('DSPs','dsp')]:
  m=re.search(r'\|\s*'+label+r'\*?\s*\|\s*([\d.]+)',u);assert m;resources[key]=float(m[1])
 assert re.search(r'^FLOW_PASS',log(directory/'implementation.log'),re.M)
 return dict(timing=sta,resources=resources)
implementation=timing(I)
assert 'M9_MERGED_ROUTED_AUDIT_PASS' in log(O/'routed_audit.log')
check=log(O/'routed_audit/check_timing.rpt')
for key in ('no_clock','unconstrained_internal_endpoints','no_input_delay'):
 assert re.search(r'checking '+key+r' \(0\)',check),key
assert 'All paths are Safely Timed.' in log(O/'routed_audit/cdc.rpt')
pdm=log(O/'routed_audit/pdm_interface/status.txt')
assert 'PDM_MAX_DATAPATH_PASS_CONDITIONAL_HOLD_ANALYTIC_ONLY' in pdm
assert pdm.count('phase_a_q_reg[')==6 and pdm.count('bit_q_reg/D')==6
assert 'Prop_fdce_C_Q' in log(O/'routed_audit/pdm_interface/clock_max.rpt')
assert 'M9_EXTERNAL_WINDOW_CONDITIONAL_PASS' in log(O/'external_window/console.log')
external={}
for name in ('nominal','late_setup','early_hold'):
 values={}
 for line in log(O/'external_window'/name/'summary.txt').splitlines():
  group,kind,slack=line.split();values[group+'_'+kind]=float(slack)
 assert len(values)==4
 if name=='nominal':assert min(values.values())>=0
 if name=='late_setup':assert values['A_max']<0 and values['B_max']<0
 if name=='early_hold':assert values['A_min']<0 and values['B_min']<0
 external[name]=values
runs=read(V/'runs.json');assert len(runs)==22 and all(x['status']=='PASS' for x in runs)
normal=read(S/'normal1024_summary.json')['results'][0]
matrix=read(S/'matrix183_summary.json');assert matrix['status']=='PASS' and len(matrix['results'])==183
counts=dict(collections.Counter(x['status'] for x in matrix['results']))
assert counts=={'PASS':128,'CORRECT_LATE':2,'EXPLICIT_LOSS':53},counts
old_matrix=read(R/'build/m6_20261016/acceptance.json')['stress_classifications'];assert counts==old_matrix
for k in range(4):assert 'all_scores_checked=1024' in log(V/f'physical{k}_rtl.log')
dtcm=read(V/'dtcm/dtcm50000_summary.json')['results'][0];assert dtcm['status']=='PASS' and dtcm['dtcm_blocked']==50000
pending=[];long=None;off=None
if (V/'extended4096/metrics.json').exists():
 long=read(V/'extended4096/metrics.json')
 long_manifest=read(V/'extended4096/manifest.json');source_check(long_manifest['sources'])
 assert sha(Path(long_manifest['binary_path']))==long_manifest['binary_sha256']
 assert sha(S/'fw/fw_live12.elf')==long_manifest['firmware_sha256']
else:pending.append('4096 window replay')
for value,n in [(normal,1024)]+([] if long is None else [(long,4096)]):
 assert value['status']=='PASS' and value['windows']==n and value['raw_checks']==n*12*1024*3
 assert value['raw_drop']==value['window_drop']==value['audio_drop']==0
 assert value['max_compute']<=323463 and value['max_latency']==393217
if (OFF/'implementation.log').exists() and re.search(r'^FLOW_PASS',log(OFF/'implementation.log'),re.M):
 assert now==read(OFF/'source_manifest.json');off=timing(OFF)
else:pending.append('DMA disabled implementation')
if a.preflight:
 print('M9_PREFLIGHT_CHECKED',json.dumps(dict(pending=pending,implementation=implementation,release_created=False)));raise SystemExit(0)
assert not pending,pending
report=dict(stage='M9',status='PASS_SOFTWARE_RTL_IMPL',hardware='DEFERRED_HARDWARE',
 scope=dict(channels=12,nfft=1024,hop=512,pairs=66,grid=1024,simd_lanes=8,clock_hz=40000000,part='xc7z020clg400-1'),
 user_authorized_merge=True,changed_preexisting_files=sorted(changed),protected_unchanged=len(before)-len(changed),
 m5_report_and_binary_evidence_preserved=True,m5_intentionally_changed_source_and_supporting_doc_paths=m5_changed,
 implementation=implementation,constraint_equivalence=proof,dma_disabled_implementation=off,normal1024=normal,long4096=long,
 stress_classifications=counts,model_scenarios=528,auxiliary_tests=19,pdm_shared_tests=11,pdm_raw_sync_tests=6,
 pdm_external_timing='PRODUCTION_MAX_DATAPATH_ONLY; SEPARATE_CONDITIONAL_SETUP_HOLD_MODEL; BOARD_UNVERIFIED',
 external_window=external,
 dma=dma,software=software,application=application,isolation=isolation,arm=arm,runs=runs,
 deferred=['Physical part and PDM wiring/power/startup','Measured production coordinates and calibration',
 'HP0 DDR and Cortex-A9 cache coherency on board','Actual GSC/UDP CPU throughput and congestion long run',
 'Real acoustic accuracy and noise/target quality'],board_actions='NONE')
(O/'acceptance.json').write_text(json.dumps(report,indent=2))
paths=set()
extensions={'.json','.log','.rpt','.md','.txt','.csv','.bin','.hex','.elf','.npz','.su','.ld','.h','.c','.cpp','.tcl','.ps1','.bit','.xsa','.dcp','.a','.spec','.udp','.py','.v','.vh','.xdc','.f','.s','.so','.jou'}
for base in [O,V,I,OFF,R/'build/m9_merge_20261016_pdm_xsim',R/'build/pdm12_runs/m9_merge_20261016_soc_xsim']:
 paths.update(f for f in base.rglob('*') if f.is_file() and f.suffix.lower() in extensions and '__pycache__' not in str(f))
# These are sinks of the packaging/verification commands themselves; binding an
# actively written log would create a self-referential, immediately stale hash.
paths.difference_update({O/'finalize.log',O/'handoff_verification.log'})
paths.update(R/path for path in before)
paths.update(f for folder in ('rtl','configs','constrs') for f in (R/folder).rglob('*') if f.is_file())
stage_sources=['rtl/transport/rv32_stream_dma.v','sw/pdm_stream.c','sw/pdm_stream.h','sw/ps_stream_udp.c',
 'pc/pdm_stream_receive.py','tb/tb_gsc_timestamp.v','tb/stream_dma_isolation_probe.vh',
 'scripts/connect_stream_dma.tcl','scripts/stream_dma_test.cpp','scripts/check_stream_dma.py',
 'scripts/check_gsc_timestamp.py','scripts/check_dma_isolation.py','scripts/check_pdm_stream.py',
 'scripts/build_stream_platform.tcl','scripts/generate_ps_gsc_profile.py','scripts/build_ps_stream.ps1',
 'scripts/ps_stream_mock.h','scripts/ps_stream_app_mock.c','scripts/check_ps_stream_app.py',
 'scripts/finalize_m9.py','scripts/record_m9_constraint_equivalence.py','scripts/audit_m9_workspace_drift.py','scripts/verify_stage_release.py',
 'scripts/check_pdm_shared.py','scripts/check_ps_pdm_startup.py','scripts/report_pdm_interface.tcl','scripts/check_m9_calibrated_rtl.py',
 'tb/tb_pdm_shared_startup.v']
paths.update(R/path for path in stage_sources)
paths.update(R/path for path in supporting_docs)
paths.add(R/'docs/M9_DMA_UDP实施与验收_2026-10-16.md')
paths.add(R/'docs/M9_开发记录与源码漂移阻碍_2026-10-16.md')
paths.add(S/'model/Vtb_localizer12_safety');paths.add(O/'dma/model/Vrv32_stream_dma')
paths.update(O/'app_loop_release'/row['mode'] for row in application['cases'])
for name in ('m9_merge_impl_20261016_project','m9_merge_off_impl_20261016_project'):
 paths.add(R/'build/zynq12_integrated_plan'/name/'rv32_zynq.runs/impl_1/ps_pl_wrapper.bit')
manifest=dict(status=report['status'],hardware='DEFERRED_HARDWARE',
 files=[dict(path=str(f.relative_to(R)),bytes=f.stat().st_size,sha256=sha(f)) for f in sorted(paths)])
(O/'release_manifest.json').write_text(json.dumps(manifest,indent=2))
print('M9_RELEASE_PASS',json.dumps(dict(implementation=implementation,files=len(paths),long_windows=long['windows'])))
