"""Controller-only reset/enable and counter rollover; engine handshakes are stubs."""
from pathlib import Path
import argparse,subprocess,json
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--before',action='store_true');a=p.parse_args()
O=R/'build/localizer12_safety'/('before_units' if a.before else 'final_units');O.mkdir(exist_ok=True)
rtl=R/'build/localizer12_safety/before/rtl/array/rv32_overlap_localizer.v' if a.before else R/'rtl/array/rv32_overlap_localizer.v'
results=[]
for name in ['rollover','sessions','collision']:
 top='tb_localizer12_'+name
 q=subprocess.run(['iverilog','-g2012','-Irtl','-s',top,'-o',str(O/(name+'.vvp')),str(rtl),str(R/'tb'/(top+'.v'))],cwd=R,capture_output=True,text=True)
 (O/(name+'_compile.log')).write_text(q.stdout+q.stderr);assert q.returncode==0
 with (O/(name+'.log')).open('w') as f:q=subprocess.run(['vvp',str(O/(name+'.vvp'))],cwd=R,stdout=f,stderr=subprocess.STDOUT)
 log=(O/(name+'.log')).read_text();passed=q.returncode==0 and ('LOCALIZER_'+name.upper()+'_PASS') in log
 results.append(dict(test=name,status='PASS' if passed else 'FAIL',expected='FAIL' if a.before else 'PASS',exit_code=q.returncode))
 print(name,results[-1]['status'],flush=True)
(O/'summary.json').write_text(json.dumps(results,indent=2))
assert all((r['status']=='FAIL')==a.before for r in results)
print('LOCALIZER_SAFETY_UNITS_'+('BASELINE_FAILURE_REPRODUCED' if a.before else 'PASS'))
