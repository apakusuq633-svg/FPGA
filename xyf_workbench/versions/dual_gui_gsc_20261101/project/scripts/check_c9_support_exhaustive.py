from pathlib import Path
import ctypes,subprocess,json
R=Path(__file__).resolve().parents[1];O=R/'build/offline_followup_20261027';O.mkdir(parents=True,exist_ok=True)
p=O/'support_export.c';p.write_text('#include "circular9_candidates.h"\n__declspec(dllexport) unsigned component(unsigned m,unsigned n,unsigned *a,unsigned *b){return c9_support_component(m,n,a,b);}\n')
subprocess.run([r'D:\winlibs\mingw64\bin\gcc.exe','-std=c11','-shared','-O2','-Isw',str(p),'-o',str(O/'support_export.dll')],cwd=R,check=True)
f=ctypes.CDLL(str(O/'support_export.dll')).component;f.argtypes=[ctypes.c_uint32,ctypes.c_uint32,ctypes.POINTER(ctypes.c_uint32),ctypes.POINTER(ctypes.c_uint32)];f.restype=ctypes.c_uint32
checks=0
for n in range(10):
 for mask in range(256):
  a=ctypes.c_uint32();b=ctypes.c_uint32();got=f(mask,n,ctypes.byref(a),ctypes.byref(b))
  groups=[]
  if n<=8 and mask<(1<<n):
   for i in range(n):
    if mask&(1<<i):
     if not groups or i-groups[-1][-1]>2:groups.append([])
     groups[-1].append(i)
  best=max(groups,key=lambda g:(len(g),g[-1]-g[0]),default=[])
  expect=(len(best),best[0] if best else 0,best[-1] if best else 0)
  assert (got,a.value,b.value)==expect,(n,mask,got,a.value,b.value,expect)
  checks+=1
(O/'support_exhaustive.json').write_text(json.dumps({'checks':checks,'passed':True,'reference':'independent connected components of genuine1024-point windows at512-point hop','board_tested':False},indent=2));print('SUPPORT_EXHAUSTIVE_PASS',checks)
