"""Bit-exact CRC validation and native benchmark; never claims ARM throughput."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import zlib

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/pdm_crc32_checks'
OUT.mkdir(parents=True,exist_ok=True)
suffix='.dll' if os.name=='nt' else '.so'
dll=OUT/('crc'+suffix)
base=['gcc','-O2','-std=c11','-Wall','-Wextra','-Werror','sw/pdm_stream.c','sw/pdm_crc32_test.c']
subprocess.run(base+['-shared','-fPIC','-o',str(dll)],cwd=ROOT,check=True)
lib=ctypes.CDLL(str(dll))
functions=[getattr(lib,name) for name in ['pdm_crc32','crc32_bitwise_reference','crc32_nibble_reference']]
for function in functions:
    function.argtypes=[ctypes.c_void_p,ctypes.c_size_t];function.restype=ctypes.c_uint32
rng=random.Random(20261023)
vectors=[b'',b'123456789',bytes(range(256)),bytes(4096),b'\xff'*4096]
vectors += [bytes([i]) for i in range(256)]
vectors += [rng.randbytes(n) for n in [1,7,15,16,31,32,63,64,119,120,127,128,255,256,1024,1104,1120,4096]]
vectors += [rng.randbytes(rng.randrange(8193)) for _ in range(2000)]
for index,data in enumerate(vectors):
    padding=index%16
    buffer=ctypes.create_string_buffer(bytes(padding)+data)
    address=ctypes.addressof(buffer)+padding
    expected=zlib.crc32(data)
    for function in functions:
        assert function(address,len(data))==expected,(index,len(data),function.__name__)
exe=OUT/('benchmark.exe' if os.name=='nt' else 'benchmark')
subprocess.run(base+['-o',str(exe)],cwd=ROOT,check=True)
raw=subprocess.check_output([str(exe)],cwd=ROOT,text=True)
runs=json.loads(raw);(OUT/'benchmark_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
summaries=[]
for length in (120,1120,4096):
    median={name:statistics.median(r['host_clock_seconds'] for r in runs if r['bytes']==length and r['implementation']==name)
            for name in ('bitwise_reference','previous_nibble','byte_table')}
    summaries.append({'bytes':length,'median_host_clock_seconds':median,
       'speedup_vs_previous_nibble':median['previous_nibble']/median['byte_table'],
       'speedup_vs_bitwise':median['bitwise_reference']/median['byte_table']})
result={'status':'PASS_NATIVE','vectors_checked_against_zlib':len(vectors),
        'check_123456789':'0xcbf43926','table_bytes':1024,'arm_throughput_measured':False,
        'benchmark':summaries,'source_sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest()
        for p in ['sw/pdm_stream.c','sw/pdm_crc32_test.c','scripts/check_pdm_crc32.py']}}
(OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('PDM_CRC32_PASS '+json.dumps(result))
