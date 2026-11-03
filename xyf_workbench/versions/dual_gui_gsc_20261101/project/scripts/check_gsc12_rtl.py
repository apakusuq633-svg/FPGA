"""Actual RTL packets -> independent Python frontend/NLMS and portable C adapter."""
from pathlib import Path
import argparse,ctypes,json,subprocess
import numpy as np
from gsc12_golden import frontend,nlms
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--library',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
rng=np.random.default_rng(9173);raw=rng.integers(-6000,6001,(256,12),dtype=np.int16)
raw[100:104]=32767;raw[104:108]=-32768
delay=np.array([(ch*5<<16)+((ch*7)%16<<12) for ch in range(12)],np.uint32)
fir=np.array([int(t,16) for t in (R/'build/fw_fir_coeff.hex').read_text().split()],np.uint16).view(np.int16)
np.savetxt(O/'pcm.hex',raw.reshape(-1).astype(np.uint16),fmt='%04x')
np.savetxt(O/'delay.hex',delay,fmt='%08x');np.savetxt(O/'fir.hex',fir.astype(np.uint16),fmt='%04x')
text=(R/'tb/tb_gsc12_frontend.v').read_text().replace('VECTOR_DIR',O.as_posix()).replace('OUTPUT_FILE',(O/'packets.hex').as_posix())
(O/'tb.v').write_text(text)
cmd=['iverilog','-g2012','-Irtl','-s','tb_gsc12_frontend','-o',str(O/'sim'),*map(str,(R/'rtl').rglob('*.v')),str(O/'tb.v')]
q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/'compile.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
q=subprocess.run(['vvp',str(O/'sim')],cwd=R,capture_output=True,text=True);(O/'run.log').write_text(q.stdout+q.stderr)
assert q.returncode==0 and 'GSC12_FRONTEND_RTL_PASS' in q.stdout,q.stdout+q.stderr
packet_bytes=b''.join(int(line,16).to_bytes(64,'little') for line in (O/'packets.hex').read_text().split())
w=np.frombuffer(packet_bytes,dtype='<u4').reshape(-1,16).copy();assert len(w)==256
das,beam,refs=frontend(raw,delay,fir,integrate_refs=True)
expected_word=das.astype(np.uint16).astype(np.uint32)|(beam.astype(np.uint16).astype(np.uint32)<<16)
assert np.array_equal(w[:,7],expected_word),'actual RTL DAS/FIR differs from independent frontend'
assert np.array_equal(w[:,1],np.arange(256)) and np.all(w[:,0]==0x47534301)
assert np.all(w[:,2]==1) and np.all(w[:,3]==0) and np.all(w[:,5]==int(delay.max())+65536)
assert np.all(w[:,6]==(7<<8|1)) and np.all(w[:,14:]==0)
for ch in range(12):assert np.array_equal((w[:,8+ch//2]>>(16*(ch%2))).astype(np.uint16),raw[:,ch].astype(np.uint16))
lib=ctypes.CDLL(str(a.library.resolve()));lib.gsc12_state_size.restype=ctypes.c_size_t
class Config(ctypes.Structure):
 _fields_=[('version',ctypes.c_uint32),('epoch',ctypes.c_uint32),('direction_id',ctypes.c_uint16),('mu_q15',ctypes.c_uint16),('epsilon',ctypes.c_uint32),('delay_q16',ctypes.c_uint32*12),('fir_q15',ctypes.c_int16*32)]
c=Config();c.version=1;c.direction_id=7;c.mu_q15=8192;c.epsilon=1<<20
for i,v in enumerate(delay):c.delay_q16[i]=int(v)
for i,v in enumerate(fir):c.fir_q15[i]=int(v)
s=ctypes.create_string_buffer(lib.gsc12_state_size());lib.gsc12_reset.argtypes=[ctypes.c_void_p];lib.gsc12_reset(s)
lib.gsc12_configure.argtypes=[ctypes.c_void_p,ctypes.POINTER(Config)];assert lib.gsc12_configure(s,ctypes.byref(c))==0
lib.gsc12_run_packets.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p]
out=np.zeros(256,np.int16);model=np.zeros(256,np.uint32)
lib.gsc12_run_packets(s,w.ctypes.data,256,1,0,out.ctypes.data,model.ctypes.data)
assert np.array_equal(model,w[:,7]),'C beam reconstruction differs from actual RTL'
expected,weights,stats=nlms(beam,refs)
assert np.array_equal(out,expected),('C adaptive output differs from independent Golden',np.flatnonzero(out!=expected)[:10].tolist())
out.tofile(O/'gsc_output.bin')
(O/'metrics.json').write_text(json.dumps({'status':'PASS','packets':256,'real_das_simd_tap':True,
 'model_matches_all_rtl_beams':True,'gsc_matches_integer_golden':True,'hardware':'DEFERRED_HARDWARE'},indent=2))
print(q.stdout.strip());print('GSC12_RTL_C_ALIGNMENT_PASS')
