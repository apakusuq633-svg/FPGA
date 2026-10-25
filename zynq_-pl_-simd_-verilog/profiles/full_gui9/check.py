"""Focused GUI/monitor verification. No hardware and no RTL simulation."""
from pathlib import Path
import hashlib,json,os,subprocess,sys
P=Path(__file__).resolve().parent
R=P.parents[1]
O=R/'build/gui9_checks';O.mkdir(parents=True,exist_ok=True)
GCC=Path(r'D:\winlibs\mingw64\bin\gcc.exe')
NODE=Path(r'C:\Users\21914\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe')
results=[]
def run(name,args,env=None):
 p=subprocess.run([str(x) for x in args],cwd=R,capture_output=True,text=True,encoding='utf-8',errors='replace',env=env)
 (O/(name+'.log')).write_text(p.stdout+p.stderr,encoding='utf-8')
 if p.returncode:raise RuntimeError(name+': '+p.stdout+p.stderr)
 results.append({'name':name,'status':'PASS'});print(name,'PASS')
for name in ['health','api']:
 exe=O/(name+'_test.exe')
 run(name+'_compile',[GCC,'-std=c11','-Wall','-Wextra','-Werror','-Wno-misleading-indentation','-O2','-I'+str(R),P/'tests'/(name+'_test.c'),'-o',exe])
 run(name,[exe])
run('page_compile',[GCC,'-std=c11','-I'+str(R/'sw'),'-I'+str(R/'sw/cstub'),P/'tests/page_dump.c','-o',O/'page_dump.exe'])
run('page_extract',[O/'page_dump.exe',O/'compiled_gui.html'])
html=(O/'compiled_gui.html').read_text(encoding='utf-8')
assert len(html.encode())<60000 and 'id="archive_load"' in html and 'id="pair_run"' in html
(P/'tests/full_gui.html').write_text(html,encoding='utf-8',newline='\n')
run('browser_dom',[NODE,P/'tests/gui_test.js'])
env=dict(os.environ,PYTHONPATH=str(P))
run('archive',[sys.executable,P/'tests/archive_test.py'],env)
run('diagnosis_compile',[GCC,'-std=c11','-Wall','-Wextra','-Wno-missing-field-initializers','-O2','-I'+str(R/'sw'),R/'sw/circular9_diagnosis_test.c',R/'sw/circular9_diagnosis.c','-lm','-o',O/'diagnosis_test.exe'])
run('diagnosis',[O/'diagnosis_test.exe'])
summary={'scope':'offline native C, mocked browser DOM and SQLite; no board measurements','results':results,'page_bytes':len(html.encode()),'protected_rtl_modified':False,'physical_board_tested':False,'source_sha256':{p.relative_to(R).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in list((R/'sw').glob('*gui*'))+list((R/'sw').glob('*health*')) if p.is_file()}}
(O/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
print('GUI9_FOCUSED_CHECKS_PASS')
