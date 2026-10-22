"""Bit-exact M8 C/independent-Golden, bypass, alignment and recovery regression."""
from pathlib import Path
import argparse,ctypes,hashlib,json,subprocess,time
import numpy as np
from gsc12_golden import frontend,fixed_output
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--golden',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False);G=a.golden.resolve()
sources=[R/'sw/gsc12.c',R/'sw/gsc12.h',R/'scripts/gsc12_bench.c',R/'scripts/gsc12_golden.py',Path(__file__)]
(O/'sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
cmd=['gcc','-shared','-fPIC','-O3','-Wall','-Wextra','-Werror','-DGSC12_TEST','-fsanitize=undefined','-fno-sanitize-recover=all','sw/gsc12.c','scripts/gsc12_bench.c','-o',str(O/'gsc12.so')]
q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/'compile.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
lib=ctypes.CDLL(str(O/'gsc12.so'))
class Config(ctypes.Structure):
    _fields_=[('version',ctypes.c_uint32),('epoch',ctypes.c_uint32),('direction_id',ctypes.c_uint16),('mu_q15',ctypes.c_uint16),
              ('epsilon',ctypes.c_uint32),('delay_q16',ctypes.c_uint32*12),('fir_q15',ctypes.c_int16*32)]
assert ctypes.sizeof(Config)==128
lib.gsc12_state_size.restype=ctypes.c_size_t
lib.gsc12_reset.argtypes=[ctypes.c_void_p]
lib.gsc12_configure.argtypes=[ctypes.c_void_p,ctypes.POINTER(Config)];lib.gsc12_configure.restype=ctypes.c_int
lib.gsc12_process.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_int,ctypes.c_int];lib.gsc12_process.restype=ctypes.c_int16
lib.gsc12_run_packets.argtypes=[ctypes.c_void_p,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p]
lib.gsc12_stat.argtypes=[ctypes.c_void_p,ctypes.c_uint];lib.gsc12_stat.restype=ctypes.c_uint64
lib.gsc12_reason.argtypes=[ctypes.c_void_p];lib.gsc12_reason.restype=ctypes.c_uint32
lib.gsc12_get_weights.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
lib.gsc12_test_corrupt_weights.argtypes=[ctypes.c_void_p]
lib.gsc12_test_weight.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int32]
names=['packets','active','disabled','warmup','bad_format','sequence_errors','lost_packets','overflow_events','metadata_mismatch',
       'transitions','alignment_errors','saturations','coefficient_clips','update_frozen','divergence','restarts','reference_clips','input_clips']
def stats(s):return {name:int(lib.gsc12_stat(s,i)) for i,name in enumerate(names)}
def config(d,grid,version=17,epoch=3):
    c=Config();c.version=version;c.epoch=epoch;c.direction_id=grid;c.mu_q15=8192;c.epsilon=1<<20
    for i,v in enumerate(d['delays_q16']):c.delay_q16[i]=int(v)
    for i,v in enumerate(d['fir']):c.fir_q15[i]=int(v)
    return c
def packets(d,c,base=0):
    n=len(d['raw']);w=np.zeros((n,16),np.uint32)
    w[:,0]=0x47534301;w[:,1]=np.arange(n,dtype=np.uint32)+np.uint32(base);w[:,2]=c.version
    w[:,3]=np.uint32(base);w[:,4]=c.version;w[:,5]=int(max(c.delay_q16))+65536;w[:,6]=1|(c.direction_id<<8)
    w[:,7]=d['das'].astype(np.uint16).astype(np.uint32)|(d['beam'].astype(np.uint16).astype(np.uint32)<<16)
    raw=d['raw'].astype(np.uint16).astype(np.uint32)
    for k in range(6):w[:,8+k]=raw[:,2*k]|(raw[:,2*k+1]<<16)
    w[:,14]=c.epoch
    return w
def state(c=None):
    s=ctypes.create_string_buffer(lib.gsc12_state_size());lib.gsc12_reset(s)
    if c is not None:assert lib.gsc12_configure(s,ctypes.byref(c))==0
    return s
def run(s,w,enabled=1,freeze=0):
    w=np.ascontiguousarray(w,dtype=np.uint32);out=np.zeros(len(w),np.int16);model=np.zeros(len(w),np.uint32)
    start=time.perf_counter();lib.gsc12_run_packets(s,w.ctypes.data,len(w),enabled,freeze,out.ctypes.data,model.ctypes.data)
    return out,model,time.perf_counter()-start
def weights(s):
    w=np.zeros((11,4),np.int32);lib.gsc12_get_weights(s,w.ctypes.data);return w
golden=json.loads((G/'metrics.json').read_text());assert golden['status']=='PASS'
results=[]
for k,row in enumerate(golden['cases']):
    d=np.load(G/f'case{k}.npz',allow_pickle=False);c=config(d,row['grid']);w=packets(d,c)
    s=state(c);out,model,elapsed=run(s,w)
    bad=np.flatnonzero(out!=d['expected'])
    assert not len(bad),(k,int(bad[0]),int(out[bad[0]]),int(d['expected'][bad[0]]),stats(s))
    assert np.array_equal(model,w[:,7]),('beam reconstruction mismatch',k)
    assert np.array_equal(weights(s),d['weights']),('coefficient mismatch',k)
    st=stats(s);assert st['active']==len(w)-128 and st['warmup']==128 and st['alignment_errors']==st['divergence']==0
    out.tofile(O/f'case{k}_c_output.bin')
    results.append({'case':k,'samples':len(w),'bit_exact':True,'host_samples_per_second':len(w)/elapsed,'stats':st,'acoustics':row})
    off=state(c);bypass,_,_=run(off,w,enabled=0);assert np.array_equal(bypass,d['beam']) and stats(off)['disabled']==len(w)
    frozen=state(c);noadapt,_,_=run(frozen,w,freeze=1);assert np.array_equal(noadapt,d['beam']) and np.all(weights(frozen)==0)
    print({'case':k,'status':'PASS','samples':len(w),'host_samples_per_second':len(w)/elapsed},flush=True)
# Structural/fault tests use the same complete packet contract and never alter PL.
d=np.load(G/'case0.npz',allow_pickle=False);c=config(d,585);w=packets(d,c)
faults=[]
for name in ['bad_magic','reserved_flags','version','epoch','direction','group_delay','future_effective','untrusted','transition','sequence_gap','duplicate','overflow','bad_das','bad_fir']:
    s=state(c);run(s,w[:300]);one=w[300].copy()
    if name=='bad_magic':one[0]=0
    elif name=='reserved_flags':one[6]|=1<<31
    elif name=='version':one[2]+=1
    elif name=='epoch':one[14]+=1
    elif name=='direction':one[6]^=1<<8
    elif name=='group_delay':one[5]+=4096
    elif name=='future_effective':one[3]=one[1]+1
    elif name=='untrusted':one[6]&=np.uint32(0xfffffffe)
    elif name=='transition':one[6]|=2
    elif name=='sequence_gap':one[1]+=2
    elif name=='duplicate':one[1]-=1
    elif name=='overflow':one[15]+=1
    elif name=='bad_das':one[7]^=1
    else:one[7]^=1<<16
    y=lib.gsc12_process(s,one.ctypes.data,1,0)
    assert y==int(np.array([one[7]>>16],np.uint16).view(np.int16)[0])
    assert lib.gsc12_reason(s)!=0,name
    before=stats(s);following=w[301:601].copy()
    # Repair transport counters explicitly; expect a counted second gap where
    # the fault itself changed sample_seq/overflow, followed by bounded warmup.
    out,_,_=run(s,following)
    assert stats(s)['active']>before['active'],('no recovery',name,stats(s))
    faults.append({'name':name,'status':'PASS','stats':stats(s)})
s=state(c);wrap=packets(d,c,0xffffff00);out,_,_=run(s,wrap[:512]);assert np.array_equal(out,d['expected'][:512]) and stats(s)['sequence_errors']==0
faults.append({'name':'sequence_wrap','status':'PASS','stats':stats(s)})
s=state(c);run(s,w[:300]);lib.gsc12_test_corrupt_weights(s)
y=lib.gsc12_process(s,w[300].ctypes.data,1,0)
assert y==int(d['beam'][300]) and stats(s)['divergence']==1 and np.all(weights(s)==0)
run(s,w[301:601]);assert stats(s)['active']>300-128
faults.append({'name':'coefficient_corruption','status':'PASS','stats':stats(s)})
s=state(c);run(s,w[:500]);held=weights(s).copy()
out,_,_=run(s,w[500:800],freeze=1)
assert np.array_equal(weights(s),held)
assert np.array_equal(out,fixed_output(d['beam'],d['refs'],held)[500:800])
faults.append({'name':'freeze_trained_weights','status':'PASS','stats':stats(s)})
s=state(c);run(s,w[:500]);run(s,w[500:501],enabled=0)
out,_,_=run(s,w[501:502],enabled=1);assert out[0]==d['beam'][501]
faults.append({'name':'disable_reenable','status':'PASS','stats':stats(s)})
s=state(c);run(s,w[:500]);new_config=config(d,585,version=0,epoch=4)
assert lib.gsc12_configure(s,ctypes.byref(new_config))==0
new_packets=packets(d,new_config)[600:1000].copy();new_packets[:,3]=600
out,_,_=run(s,new_packets);assert np.array_equal(out[:128],d['beam'][600:728])
assert stats(s)['alignment_errors']==0 and stats(s)['restarts']==2
faults.append({'name':'epoch_reconfigure_version_wrap','status':'PASS','stats':stats(s)})
# Saturation is exercised with a valid, deliberately high-gain FIR profile and
# a test-only in-range coefficient injection. Test hooks are absent in ARM build.
strong_raw=np.zeros((512,12),np.int16);strong_raw[:,0]=32767
strong_delay=np.full(12,(60<<16)+(15<<12),np.uint32);strong_fir=np.full(32,32767,np.int16)
sdas,sbeam,srefs=frontend(strong_raw,strong_delay,strong_fir,integrate_refs=True)
strong={'raw':strong_raw,'delays_q16':strong_delay,'fir':strong_fir,'das':sdas,'beam':sbeam}
sc=config(strong,585);sw=packets(strong,sc);s=state(sc);out,model,_=run(s,sw[:300])
assert np.array_equal(model,sw[:300,7]) and stats(s)['reference_clips']>0 and stats(s)['input_clips']>0
lib.gsc12_test_weight(s,0,-32768);out,_,_=run(s,sw[300:301])
assert out[0]==32767 and stats(s)['saturations']>0 and stats(s)['update_frozen']>0
faults.append({'name':'maximum_delay_strong_interference_saturation','status':'PASS','stats':stats(s)})
s=state(c);run(s,w[:300]);saved=bytes(s)
for field,value in [('direction_id',1024),('mu_q15',0),('mu_q15',16385),('epsilon',0)]:
    bad=Config.from_buffer_copy(bytes(c));setattr(bad,field,value)
    assert lib.gsc12_configure(s,ctypes.byref(bad))!=0 and bytes(s)==saved
bad=Config.from_buffer_copy(bytes(c));bad.delay_q16[0]=61<<16
assert lib.gsc12_configure(s,ctypes.byref(bad))!=0 and bytes(s)==saved
bad=Config.from_buffer_copy(bytes(c))
for i in range(32):bad.fir_q15[i]=0
assert lib.gsc12_configure(s,ctypes.byref(bad))!=0 and bytes(s)==saved
for compiler,flags,name in [('riscv64-unknown-elf-gcc',['-march=rv32im','-mabi=ilp32'],'rv32')]:
    cmd=[compiler,*flags,'-O2','-ffreestanding','-Wall','-Wextra','-Werror','-c','sw/gsc12.c','-o',str(O/(name+'.o'))]
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/(name+'_compile.log')).write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
report={'status':'PASS_SOFTWARE','hardware':'DEFERRED_HARDWARE','state_bytes':int(lib.gsc12_state_size()),'cases':results,'faults':faults,
 'scope':'12 channels / 11 blocking references / 4 taps per reference / fixed point Q15',
 'host_throughput_is_not_cortex_a9_throughput':True}
(O/'metrics.json').write_text(json.dumps(report,indent=2));print('GSC12_C_GOLDEN_PASS')
