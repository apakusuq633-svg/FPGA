import os
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/circular9_stream_checks';OUT.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;C:/msys64/usr/bin;'+env['PATH']
exe=OUT/'stream.exe';packet=OUT/'packet.bin'
subprocess.run(['gcc','-O2','-Wall','-Wextra','-Werror','-Wno-unused-function',
 'sw/circular9_stream_test.c','sw/circular9_audio.c','sw/circular9_stream.c','sw/pdm_stream.c','sw/gsc9.c','-o',str(exe)],cwd=ROOT,env=env,check=True)
subprocess.run([str(exe),str(packet)],cwd=ROOT,env=env,check=True)
sys.path.insert(0,str(ROOT/'pc'))
from circular9_receive import decode
data=packet.read_bytes();header,rows=decode(data)
assert len(rows)==2 and rows[0]['raw']==(123,)*9 and rows[1]['output']==122
for i in range(len(data)):
    bad=bytearray(data);bad[i]^=1
    try:decode(bad)
    except ValueError:pass
    else:raise AssertionError(f'corruption accepted at {i}')
print('CIRCULAR9_PC_PROTOCOL_PASS corruptions=332 hardware=UNVERIFIED')
