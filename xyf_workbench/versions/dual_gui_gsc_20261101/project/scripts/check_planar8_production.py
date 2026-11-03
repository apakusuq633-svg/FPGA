"""Validate optimized production scheduling, quality gates and raw-pause recovery."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import re

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/planar8_optimized'


def words(p):
    return [int(w,16) for line in p.read_text().splitlines()
            for w in line.split('//')[0].split() if not w.startswith('@')]


def main():
    manifest=json.loads((OUT/'manifest.json').read_text())
    for name,digest in manifest['source_sha256'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,'Rebuild model: '+name
    assert words(OUT/'production/itcm.hex')==words(ROOT/'build/das8/fw/itcm.hex')
    for frame in range(1,4):
        for kind in ['scores','statistics']:
            assert words(OUT/f'production/{kind}_{frame}.hex')==words(OUT/f'overlap/{kind}_{frame}.hex'),(kind,frame)
    print('PRODUCTION_NUMERIC_PARITY_PASS 3072 scores and 120 statistics words',flush=True)
    env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;'+env['PATH']
    results={}
    for name,case,windows in [('accepted_direction',3,5),('raw_resume',4,3),('silence',1,3),('clipping',2,3),('continuous32',0,32)]:
        command=[str(OUT/'model_abi0/Vtb_planar8_latency.exe'),'+PRODUCTION',
                 '+FW='+str(OUT/'production').replace('\\','/'),
                 '+PCM='+str(OUT/'pcm.hex').replace('\\','/'),
                 '+WINDOWS='+str(windows),'+CASE='+str(case)]
        with (OUT/(name+'.log')).open('w') as f:
            q=subprocess.run(command,cwd=ROOT,env=env,stdout=f,stderr=subprocess.STDOUT)
        text=(OUT/(name+'.log')).read_text()
        assert q.returncode==0 and 'PLANAR8_LATENCY_PASS' in text,text[-2000:]
        results[name]={'windows':windows,'case':case,'passed':True,
                       'log_sha256':hashlib.sha256(text.encode()).hexdigest()}
        print(name+': PASS',flush=True)
    (OUT/'production_validation.json').write_text(json.dumps({
        'tests':results,'model_manifest_sha256':hashlib.sha256((OUT/'manifest.json').read_bytes()).hexdigest(),
        'firmware_sha256':hashlib.sha256((ROOT/'build/das8/fw/itcm.hex').read_bytes()).hexdigest()
    },indent=2)+'\n')
    print('PLANAR8_PRODUCTION_PASS',flush=True)


if __name__=='__main__':main()
