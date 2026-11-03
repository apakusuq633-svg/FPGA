"""Sample-clock hop regression, independent of native wall-clock/GTIMER speed."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/circular9_schedule_checks'
def main():
 OUT.mkdir(parents=True,exist_ok=True)
 env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH']
 exe=OUT/'schedule.exe'
 subprocess.run(['gcc','-std=c11','-O2','-Wall','-Wextra','-Werror','-Isw','sw/circular9_schedule_test.c','-o',str(exe)],cwd=ROOT,env=env,check=True)
 subprocess.run([str(exe)],cwd=ROOT,check=True)
 sources=['sw/circular9_schedule.h','sw/circular9_schedule_test.c','scripts/check_circular9_schedule.py']
 result={'passed':True,'hardware_tested':False,'hop_raw_samples':80000,'hop_seconds':.512,
  'window_samples':40000,'window_rate_hz':39062.5,'observation_seconds':1.024,
  'latest_only':True,'sources':{s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}}
 (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
