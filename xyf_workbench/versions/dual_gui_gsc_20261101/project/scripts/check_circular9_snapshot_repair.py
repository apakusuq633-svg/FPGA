"""Native equivalence and no-starvation regressions; no hardware claims."""
from pathlib import Path
import subprocess,hashlib,json
R=Path(__file__).resolve().parents[1];O=R/'build/snapshot_repair_20261026/checks';O.mkdir(exist_ok=True)
cc=Path(r'D:/winlibs/mingw64/bin/gcc.exe')
sets=[('search_equivalence',['sw/circular9_search_cache_test.c'],[]),('independent_schedule',['sw/circular9_candidates.c','sw/circular9_diagnosis.c','sw/circular9_snapshot_schedule_test.c'],['-DC9_CANDIDATES_TEST','-Wno-unused-function','-pthread'])]
results=[]
for name,src,flags in sets:
 exe=O/(name+'.exe');commands=[[str(cc),'-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-const-variable','-Ibuild/circular9_pipeline_checks/include','-Isw',*flags,*src,'-lm','-o',str(exe)],[str(exe)]]
 for label,cmd in zip(['compile','run'],commands):
  p=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/(name+'_'+label+'.log')).write_text(p.stdout+p.stderr);assert p.returncode==0,p.stdout+p.stderr
  print(p.stdout,end='')
 results.append({'test':name,'passed':True})
files=['sw/circular9_search_cache_test.c','sw/circular9_snapshot_schedule_test.c','sw/circular9_candidates.c','sw/circular9_tracking.h','sw/ps_circular9_tasks.h','sw/ps_circular9_aux.h','sw/ps_circular9_api.h','sw/circular9_schedule.h']
(O/'results.json').write_text(json.dumps({'scope':'synthetic_native_only','results':results,'source_sha256':{n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in files}},indent=2))
print('SNAPSHOT_REPAIR_NATIVE_PASS')
