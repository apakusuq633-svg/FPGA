# Mechanism and safety regressions, not application acceptance or board tests.
from pathlib import Path
import subprocess,json,os,sys,hashlib
R=Path(__file__).resolve().parents[1];O=R/'build/fstf_integration_20261027';O.mkdir(exist_ok=True);cc=r'D:\winlibs\mingw64\bin\gcc.exe'
for enabled in [False,True]:
 exe=O/('adapter_on.exe' if enabled else 'adapter_off.exe');flags=['-DC9_FSTF_EXPERIMENTAL=1'] if enabled else []
 subprocess.run([cc,'-std=c11','-O2','-Isw',*flags,'sw/circular9_fstf_adapter_test.c','-lm','-o',str(exe)],cwd=R,check=True);subprocess.run([str(exe)],cwd=R,check=True)
subprocess.run([sys.executable,str(R/'scripts/run_fstf_c9_e2e.py')],cwd=R,check=True)
d=json.loads((O/'e2e_results.json').read_text());assert len(d['cases'])==9
single_ok=0;dual_success=0
for c in d['cases']:
 for out in c['candidates']:
  assert out['trusted_label']=='unknown' and out['fault_direction_valid']==0
  assert out['experimental']['validated']==0
 if len(c['sources'])==1:
  assert c['snapshot_sequence']>0 and len(c['candidates'])==1 and c['candidates'][0]['experimental']['available']==1
  single_ok+=c['candidates'][0]['experimental']['label']==c['sources'][0]['label']
 else:
  assert c['known_direction_control']['known_direction_control_only']
  control=c['known_direction_control']['outputs'];assert len(control)==2 and all(v['ready'] and v['experimental_available'] for v in control)
  assert [v['experimental_label'] for v in control]==[s['label'] for s in c['sources']]
  current=[v for v in c['candidates'] if not v['stale'] and v['separation_ready']]
  dual_success+=len(current)==2 and all(any(v['nearest_truth_angle_error_deg']<12 and v['experimental']['label']==s['label'] and v['nearest_truth_label']==s['label'] for v in current) for s in c['sources'])
env=dict(os.environ,C9_FSTF_API_JSON=str(O/'single_inner.json'));subprocess.run([sys.executable,str(R/'profiles/full_gui9/check.py')],cwd=R,env=env,check=True)
files=['sw/circular9_candidates.c','sw/circular9_candidates.h','sw/ps_circular9_aux.h','configs/circular9_array.json','sw/circular9_diagnosis.c','sw/circular9_diagnosis.h','sw/fstf_c9f2_experimental_model.h','sw/ps_circular9_api.h','sw/ps_circular9_tasks.h','sw/circular9_schedule.h','sw/circular9_full_gui.js','sw/circular9_fstf_adapter_test.c','sw/circular9_fstf_e2e_test.c','scripts/run_fstf_c9_e2e.py','scripts/check_fstf_c9_experiment.py']
result={'mechanism_and_safety_tests_passed':True,'application_goal_passed':dual_success==3 and single_ok==6,'single_scene_labels_correct':int(single_ok),'single_scene_count':6,'automatic_dual_scene_successes':int(dual_success),'automatic_dual_scene_count':3,'known_direction_dual_controls_correct':3,'hardware_tested':False,'CPU_A9_timing_measured':False,'source_sha256':{n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in files}}
(O/'verification.json').write_text(json.dumps(result,indent=2));print('FSTF_EXPERIMENT_MECHANISM_PASS',json.dumps(result))
