"""Synthetic output-path test, not acoustic/ARM validation."""
from pathlib import Path
import sys,ctypes as C,subprocess,json,random
sys.path.insert(0,str(Path(__file__).resolve().parent))
from check_gsc9 import frontend
R=Path(__file__).resolve().parents[1];O=R/'build/gsc_gui_output';O.mkdir(parents=True,exist_ok=True)
subprocess.run([r'D:\winlibs\mingw64\bin\gcc.exe','-shared','-O2','sw/gsc9.c','-o','build/gsc_gui_output/gsc.dll'],cwd=R,check=True)
l=C.CDLL(str(O/'gsc.dll'));l.gsc9_state_size.restype=C.c_size_t
class Config(C.Structure):_fields_=[('version',C.c_uint32),('epoch',C.c_uint32),('grid',C.c_uint16),('mu',C.c_uint16),('eps',C.c_uint32),('delays',C.c_uint32*9),('fir',C.c_int16*32)]
l.gsc9_configure.argtypes=[C.c_void_p,C.POINTER(Config)];l.gsc9_process.argtypes=[C.c_void_p,C.POINTER(C.c_uint32),C.c_int,C.c_int];l.gsc9_process.restype=C.c_int16;l.gsc9_reason.argtypes=[C.c_void_p];l.gsc9_reason.restype=C.c_uint32;l.gsc9_set_target_guard.argtypes=[C.c_void_p,C.c_int]
rng=random.Random(73);raw=[[rng.randint(-1000,1000) for _ in range(9)] for n in range(2048)];fir=[32767]+[0]*31;das,beam,_=frontend(raw,[0]*9,fir)
def state():
 s=C.create_string_buffer(l.gsc9_state_size());c=Config(1,7,500,8192,1<<20,(C.c_uint32*9)(*([0]*9)),(C.c_int16*32)(*fir));assert l.gsc9_configure(s,C.byref(c))==0;l.gsc9_set_target_guard(s,1);return s
def packet(n):
 w=[0]*16;w[0]=0x47534302;w[1]=n;w[2]=1;w[5]=65536;w[6]=(500<<8)|1;w[7]=(das[n]&65535)|((beam[n]&65535)<<16);w[13]=0x000a0009;w[14]=7
 for ch in range(9):w[8+ch//2]|=(raw[n][ch]&65535)<<(16*(ch%2))
 return w
l.gsc9_process_nominal.argtypes=[C.c_void_p,C.POINTER(C.c_uint32),C.c_int,C.c_int];l.gsc9_process_nominal.restype=C.c_int16
nom=state();ref=state()
for n in range(2048):
 w=packet(n);expected=l.gsc9_process(ref,(C.c_uint32*16)(*w),1,0);w[6]=0;w[2]=0;w[7]=0
 assert l.gsc9_process_nominal(nom,(C.c_uint32*16)(*w),1,0)==expected
assert l.gsc9_reason(nom)==0
s=state();changed=active=0
for n in range(2048):
 y=l.gsc9_process(s,(C.c_uint32*16)(*packet(n)),1,0);active+=l.gsc9_reason(s)==0;changed+=y!=beam[n]
assert active>0 and changed>0
for on,freeze in [(0,0),(1,1)]:
 s=state()
 for n in range(2048):assert l.gsc9_process(s,(C.c_uint32*16)(*packet(n)),on,freeze)==beam[n]
s=state()
for n in range(600):l.gsc9_process(s,(C.c_uint32*16)(*packet(n)),1,0)
w=packet(600);w[7]=0;l.gsc9_process(s,(C.c_uint32*16)(*w),1,0);assert l.gsc9_reason(s)==7
z={'synthetic_only':True,'active_samples':active,'output_differs_from_DAS_samples':changed,'off_and_initial_frozen_equal_DAS':True,'alignment_guard_retained':True,'PS_nominal_equals_reference_with_invalid_PL_direction':True,'board_tested':False};(O/'results.json').write_text(json.dumps(z,indent=2));print(z)
