"""Fail-closed release evidence; no bitstream selection, board download or Flash writes."""
from pathlib import Path
import hashlib,json,re,subprocess,shutil
R=Path(__file__).resolve().parents[1];O=R/'build/localizer12_safety';I=O/'final_implementation'
subprocess.run(['python3','scripts/report_localizer12_safety.py'],cwd=R,check=True)
e=json.loads((O/'safety_evidence.json').read_text())
assert e['original_artifacts_unchanged'] and e['routed_source_current'] and e['simulation_sources_match_implementation']
assert e['flow_pass'] and e['timing']['wns_ns']>=0 and e['timing']['whs_ns']>=0 and e['timing']['tns_ns']==0 and e['timing']['ths_ns']==0
for n in [256,1024]:
 x=e[f'normal_fft_0_w0_o0_n{n}_s20261015_b0.log']
 assert x['completed'] and x['windows']==n and x['max_latency']==393217
 assert x['result_gaps']=={'524288':n-1} and x['min_point_margin']>0
for name in ['matrix','boundaries','realtime_boundaries']:
 x=json.loads((O/'release'/(name+'_summary.json')).read_text());assert x['status']=='PASS'
 assert all(r['status'] in ['PASS','CORRECT_LATE','EXPLICIT_LOSS'] for r in x['results'])
brackets=json.loads((O/'release/realtime_boundary_brackets.json').read_text())
assert len(brackets)==18
assert all(b['first_not_fixed_phase']==b['last_fixed_phase']+1 for b in brackets.values())
life=json.loads((O/'release/boundary_brackets.json').read_text())
assert len(life)==18 and all(b['first_explicit_loss']==b['last_pass']+1 for b in life.values())
cases=e['release']['cases']
for group,b in brackets.items():
 kind,phase=group.split('/')
 for key,wanted in [('last_fixed_phase',True),('first_not_fixed_phase',False)]:
  matched=[r for r in cases if r['kind']==kind and r['phase']==phase and r['duration']==b[key] and r.get('target')==2 and r.get('offset')==0]
  assert matched and all(r.get('fixed_phase',False)==wanted for r in matched),(group,key,b[key])
units=json.loads((O/'final_units/summary.json').read_text());assert len(units)==3 and all(r['status']=='PASS' for r in units)
for path,marker in [('release_regression.log','RV32_MEM_REGRESSION_PASS'),('release_mem.log','MEM_ACCESS_BASELINE_PASS cases=76'),('release_mmio.log','MEM_ACCESS_BASELINE_PASS cases=8'),('release_xsim_driver.log','LOCALIZER12_XSIM_PASS')]:
 b=(O/path).read_bytes();log=b.decode('utf-16' if b.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8',errors='replace')
 assert marker in log,(path,marker)
assert 'OK' in (O/'release_checker.log').read_text(errors='replace')
probe=e['dtcm_probe']['cases'];assert len(probe)==7 and all(r['status'] in ('PASS','EXPLICIT_LOSS') and r['dtcm_accepts']>0 for r in probe)
assert all(r['dtcm_blocked']>0 for r in probe if r['kind']=='mem')
subprocess.run(['python3','scripts/summarize_localizer12.py',str(O/'release_periodic256'),'--implementation',str(I)],cwd=R,check=True)
paths=dict(bit=O/'final_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit',xsa=I/'das_fir.xsa',dcp=I/'das_fir_routed.dcp',
           continuous_test_elf=O/'release/fw/fw_live12.elf',continuous_itcm=O/'release/fw/itcm.hex',
           timing=I/'timing_zynq.rpt',utilization=I/'util_zynq.rpt',rtl_manifest=I/'source_manifest.json',
           safety_evidence=O/'safety_evidence.json',periodic_strict=O/'release_periodic256/strict_summary.json')
paths.update(report=R/'docs/localizer12_realtime_safety_report.md',stress_csv=O/'stress_results.csv',
             raw_trace=O/'raw_trace_annotated.csv',raw_lifecycle=O/'raw_channel_pass_lifecycle.csv',
             boundary_brackets=O/'release/boundary_brackets.json',realtime_boundary_brackets=O/'release/realtime_boundary_brackets.json')
paths.update(simulation_sources=O/'release/sources.json',simulation_manifest=O/'release/manifest.json',dtcm_manifest=O/'dtcm_probe/manifest.json')
inputs=O/'release_inputs';inputs.mkdir(exist_ok=True)
for name,source in [('fft_tw.hex',R/'build/fft_tw.hex'),('test_lut.hex',R/'build/strict_overlap/vectors/lut.hex'),('hann.hex',R/'rtl/rom/pdm_hann_q14.hex')]:
 target=inputs/name;shutil.copy2(source,target);paths['input_'+name]=target
artifacts={k:dict(path=str(p.relative_to(R)),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size) for k,p in paths.items()}
scripts=list((R/'scripts').glob('*localizer12*'))+[R/'scripts/build_live12.py',R/'scripts/report_localizer_physical.tcl']
result=dict(status='SOC_DATA_SAFETY_AND_40MHZ_STA_PASS_TEST_GEOMETRY_ONLY',board='NOT_RUN',physical_geometry='NOT_VALIDATED',
            source_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),uncommitted=True,
            clock_hz=40000000,channels=12,fft_points=1024,hop=512,raw_capacity=2048,gcc_pairs=66,srp_grid=1024,
            firmware_window_limit=0,firmware_mode='CONTINUOUS_TEST_ONLY_GEOMETRY_DISABLED',
            artifacts=artifacts,scripts={str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest() for p in scripts if p.is_file()})
(O/'release_manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print('LOCALIZER12_SAFETY_PACKAGE_PASS')
