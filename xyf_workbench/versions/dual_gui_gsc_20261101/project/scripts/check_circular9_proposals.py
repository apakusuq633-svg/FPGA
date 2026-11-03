"""Weak-source temporal proposals, with real instantaneous support guards."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/circular9_proposals_checks'
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH']
    commands=[['gcc','-std=c11','-O2','-Wall','-Wextra','-Werror','-Isw','sw/circular9_candidates.c','sw/circular9_proposals_test.c','-o',str(OUT/'proposals.exe')],[str(OUT/'proposals.exe')]]
    for name,command in zip(('compile','native'),commands):
        p=subprocess.run(command,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (OUT/(name+'.log')).write_text(p.stdout);print(p.stdout,end='',flush=True)
        if p.returncode:raise RuntimeError(name+' failed')
    sources=['sw/circular9_proposals.h','sw/circular9_proposals_test.c','sw/circular9_candidates.h','sw/circular9_candidates.c','sw/circular9_direction.h',__file__]
    sources=[Path(p) if Path(p).is_absolute() else ROOT/p for p in sources]
    result={'passed':True,'hardware_tested':False,'ps_runtime_measured':False,'fixture':'synthetic committed SRP maps; no mechanical diagnosis validation','source_sha256':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
