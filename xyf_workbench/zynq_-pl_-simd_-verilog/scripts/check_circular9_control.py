"""Exercise actual RTL fine-vector transactions and synchronized tachometer."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/circular9_control_checks'
def main():
 OUT.mkdir(parents=True,exist_ok=True)
 env=os.environ.copy()
 for p in ('C:/msys64/ucrt64/bin','C:/msys64/usr/bin'):
  if Path(p).is_dir():env['PATH']=p+os.pathsep+env['PATH']
 env.setdefault('MAKE','mingw32-make' if os.name=='nt' else 'make')
 if os.name=='nt' and Path('C:/msys64/ucrt64/share/verilator').is_dir():
  env.setdefault('VERILATOR_ROOT','C:/msys64/ucrt64/share/verilator')
 model=OUT/'obj'
 verilator=shutil.which('verilator')
 if verilator:
  perl=shutil.which('perl') or 'perl'
  prefix=[perl,verilator]
 else:
  verilator=shutil.which('verilator_bin')
  if not verilator:raise SystemExit('verilator not found: add it to PATH')
  prefix=[verilator]
 exe=model/('Vtb_circular9_control.exe' if os.name=='nt' else 'Vtb_circular9_control')
 commands=[('compile',prefix+['--binary','--timing','-Wno-fatal','-j','4','-CFLAGS','-D_GLIBCXX_USE_CXX11_ABI=0','-LDFLAGS','-static-libstdc++ -static-libgcc','--top-module','tb_circular9_control','--Mdir',str(model),'rtl/array/rv32_circular9_control.v','tb/tb_circular9_control.v']),('rtl',[str(exe)])]
 for name,command in commands:
  p=subprocess.run(command,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  (OUT/(name+'.log')).write_text(p.stdout,encoding='utf-8')
  if p.returncode:raise RuntimeError(name+' failed\n'+p.stdout[-4000:])
  print(name+': PASS',flush=True)
 if 'CIRCULAR9_CONTROL_RTL_PASS' not in p.stdout:raise RuntimeError('Missing RTL pass marker')
 sources=['rtl/array/rv32_circular9_control.v','rtl/soc/rv32_soc.v','scripts/filelist.f','constrs/ps_pl_wrapper.xdc','tb/tb_circular9_control.v','scripts/check_circular9_control.py']
 (OUT/'results.json').write_text(json.dumps(dict(passed=True,hardware_tested=False,fixture='actual RTL clocked at40MHz; simulated600/1200rpm edges and fault transactions',sources={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}),indent=2)+'\n')
 print('CIRCULAR9_CONTROL_PASS hardware=UNVERIFIED')
if __name__=='__main__':main()
