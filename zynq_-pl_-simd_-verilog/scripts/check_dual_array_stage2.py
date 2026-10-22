"""Stage-two transfer and numerical gates; Vivado/SoC reports are validated separately."""
from pathlib import Path
import ctypes
import json
import os
import subprocess
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/system_optimization'

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    os.environ['PATH']='D:/winlibs/mingw64/bin'+os.pathsep+os.environ['PATH']
    logs=[]
    for name,source,marker in [('capture_pair','sw/fw/fw_capture_pair_test.c','CAPTURE_PAIR_PASS'),
                               ('raw_ps','sw/ps_raw_capture_test.c','RAW_CAPTURE_PS_PASS'),
                               ('raw_fw','sw/fw/fw_raw_capture_test.c','RAW_CAPTURE_FW_PASS')]:
        exe=OUT/(name+'_stage2.exe')
        subprocess.run(['D:/winlibs/mingw64/bin/gcc.exe','-std=c11','-O2','-Wall','-Wextra','-Werror','-Isw','-Isw/fw',source,'-o',str(exe)],cwd=ROOT,check=True)
        result=subprocess.run([str(exe)],cwd=ROOT,check=True,capture_output=True,text=True)
        assert marker in result.stdout;logs.append(result.stdout);print(result.stdout.strip())
    dll=OUT/'gcc_ring_stage2.dll'
    subprocess.run(['D:/winlibs/mingw64/bin/gcc.exe','-std=c11','-O2','-shared','-Isw/fw',
                    'sw/fw/fw_fft.c','sw/fw/fw_gcc.c','sw/fw/fw_tables.c','-o',str(dll)],cwd=ROOT,check=True)
    lib=ctypes.CDLL(str(dll));p16=ctypes.POINTER(ctypes.c_int16)
    lib.gcc_cached_pair.argtypes=[p16,p16,p16];lib.gcc_cached_ring.argtypes=[p16,p16,p16]
    rng=np.random.default_rng(20261014);ptr=lambda a:a.ctypes.data_as(p16)
    for _ in range(100):
        a,b=[rng.integers(-32768,32768,1026,dtype=np.int16) for _ in range(2)]
        complete=np.zeros(1024,dtype=np.int16);ring=complete.copy()
        lib.gcc_cached_pair(ptr(a),ptr(b),ptr(complete));lib.gcc_cached_ring(ptr(a),ptr(b),ptr(ring))
        assert np.array_equal(complete[:16],ring[:16]) and np.array_equal(complete[-16:],ring[-16:])
    result={'ring_pairs':100,'ring_samples':3200,'native_transfer_tests':logs,'bit_exact':True}
    (OUT/'stage2_native_tests.json').write_text(json.dumps(result,indent=2)+'\n')
    print('DUAL_ARRAY_STAGE2_NATIVE_PASS')

if __name__=='__main__':main()
