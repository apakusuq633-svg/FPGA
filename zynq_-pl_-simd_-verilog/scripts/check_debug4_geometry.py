"""Cross-check generated LUT layout against the native firmware distance kernel."""
from pathlib import Path
import json,os,subprocess
import numpy as np
from check_location_robustness import profile
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das4'

def main():
    compiler=Path('D:/winlibs/mingw64/bin/gcc.exe')
    os.environ['PATH']=str(compiler.parent)+os.pathsep+os.environ['PATH']
    exe=OUT/'geometry_host.exe'
    subprocess.run([str(compiler),'-std=c11','-O2','-Wall','-Wextra','-Werror','-Isw/fw','-Ibuild/das4/fw',
      '-DFW_MIC_GEOMETRY_HEADER="fw_debug4_geometry.h"','sw/fw/fw_srp.c','sw/fw/fw_tables.c',
      'scripts/golden/debug4_geometry_host.c','-o',str(exe)],cwd=ROOT,check=True)
    subprocess.run([str(exe)],cwd=ROOT,check=True)
    actual=np.array([int(v,16) for v in (OUT/'fw/steer_lut.hex').read_text().splitlines()])
    expected=np.fromfile(OUT/'steer_tau_host.bin',dtype='<u2')
    assert np.array_equal(actual,expected),'Microphone-major steering layout differs from firmware geometry'
    _,_,_,srp,_=profile(4)
    native=np.fromfile(OUT/'srp_tau_host.bin',dtype='<u2')&16383
    assert np.array_equal(srp.reshape(-1),native),'SRP geometry differs from firmware distance kernel'
    q=actual.reshape(8,256)[:,197];q=np.where(q>=8192,q-16384,q);q-=q.min()
    (OUT/'geometry_validation.json').write_text(json.dumps({'cells':256,'channels':8,'wrong_cells':0,
      'grid197_active4_comp_q4':q[:4].tolist(),'native_distance_kernel':True},indent=2)+'\n')
    print('DEBUG4_GEOMETRY_PASS cells=256 microphones=8 inactive_cloned=4 grid197_comp_q4='+str(q[:4].tolist()))

if __name__=='__main__':main()
