from pathlib import Path
import json,subprocess,hashlib
R=Path(__file__).resolve().parents[1];O=R/'build/offline_closure_20261027';O.mkdir(exist_ok=True)
exe=O/'async.exe';cc=r'D:\winlibs\mingw64\bin\gcc.exe'
subprocess.run([cc,'-std=c11','-O2','-DC9_CANDIDATES_TEST','-Wno-unused-function','-Ibuild/circular9_pipeline_checks/include','-Isw','sw/circular9_candidates.c','sw/circular9_diagnosis.c','sw/circular9_async_schedule_test.c','-pthread','-lm','-o',str(exe)],cwd=R,check=True)
input=R/'build/offline_followup_20261027/robustness/baseline_pair.pcm';cases=[]
for aux,diag in [(20000,0),(20000,100000),(20000,678000),(100000,100000),(100000,678000),(140000,0),(180000,678000),(210000,100000),(20000,3100000)]:
 out=O/f'async_{aux}_{diag}.json';p=subprocess.run([str(exe),str(input),str(out),str(aux),str(diag),'8'],cwd=R,capture_output=True,text=True);(O/f'async_{aux}_{diag}.log').write_text(p.stdout+p.stderr);assert not p.returncode,p.stdout+p.stderr
 d=json.loads(out.read_text());api=d['api'];m=api['diagnostic_scheduler'];a=api['auxiliary_search'];assert api['model_validated']==0
 assert m['cpu1_started']==m['cpu1_completed']
 if aux>200000:assert a['cpu1_late']>0 and not m['cpu1_started']
 if diag==3100000:assert m['deadline_misses']>0
 cases.append({'aux_cost_us':aux,'diag_cost_us':diag,'diagnostic':m,'auxiliary':a,'snapshot_sequence':api['sequence'],'geometry_fixture_only':True,'hardware_tested':False})
 print(p.stdout.strip(),flush=True)
(O/'async_summary.json').write_text(json.dumps({'actual_CPU0_CPU1_task_code':True,'concurrency':'deterministic CPU0 callback interleaving during declared CPU1 service costs; not OS threads or ARM timing','PCM_repeated':True,'source_pcm_sha256':hashlib.sha256(input.read_bytes()).hexdigest(),'cases':cases,'source_sha256':{n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in ['sw/circular9_async_schedule_test.c','sw/circular9_pipeline_test.c','sw/ps_circular9_tasks.h','sw/ps_circular9_aux.h']}},indent=2));print('ASYNC_SCHEDULE_MATRIX_PASS cases=9')
