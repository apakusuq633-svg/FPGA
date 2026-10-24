"""PS ownership/cache model -> actual C ring/UDP -> Python receiver + UDP loopback."""
from pathlib import Path
import argparse,ctypes,hashlib,json,os,random,socket,struct,subprocess,sys,zlib
R=Path(__file__).resolve().parents[1];sys.path.insert(0,str(R/'pc'))
from pdm_stream_receive import decode,Statistics
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
p.add_argument('--synthetic-fixture',action='store_true',help='Explicit transport-only vectors; does NOT validate RTL or GSC arithmetic')
a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
sources=[R/'sw/pdm_stream.c',R/'sw/pdm_stream.h',R/'pc/pdm_stream_receive.py',Path(__file__)]
(O/'sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources},indent=2))
sanitizer=[] if os.name=='nt' else ['-fsanitize=undefined','-fno-sanitize-recover=all']
cmd=['gcc','-shared','-fPIC','-O2','-Wall','-Wextra','-Werror',*sanitizer,'sw/pdm_stream.c','-o',str(O/'pdm_stream.so')]
q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/'compile.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
lib=ctypes.CDLL(str(O/'pdm_stream.so'))
READ=ctypes.CFUNCTYPE(ctypes.c_uint32,ctypes.c_void_p,ctypes.c_uint32)
WRITE=ctypes.CFUNCTYPE(ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32)
CACHE=ctypes.CFUNCTYPE(None,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_size_t)
BARRIER=ctypes.CFUNCTYPE(None,ctypes.c_void_p)
MAP=ctypes.CFUNCTYPE(ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_size_t)
class IO(ctypes.Structure):_fields_=[('context',ctypes.c_void_p),('read',READ),('write',WRITE),('invalidate',CACHE),('flush',CACHE),('barrier',BARRIER),('map',MAP)]
class Meta(ctypes.Structure):_fields_=[('stream_id',ctypes.c_uint32),('packet',ctypes.c_uint32),('calibration',ctypes.c_uint32),('drops',ctypes.c_uint32),('flags',ctypes.c_uint16)]
lib.pdm_stream_ring_size.restype=ctypes.c_size_t
lib.pdm_ring_open.argtypes=[ctypes.c_void_p,ctypes.POINTER(IO),ctypes.c_uint32,ctypes.c_uint,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint32,ctypes.c_uint]
lib.pdm_ring_open.restype=ctypes.c_int;lib.pdm_ring_next.argtypes=[ctypes.c_void_p,ctypes.c_void_p];lib.pdm_ring_next.restype=ctypes.c_int
lib.pdm_ring_recover.argtypes=[ctypes.c_void_p,ctypes.c_uint];lib.pdm_ring_recover.restype=ctypes.c_int
lib.pdm_ring_stat.argtypes=[ctypes.c_void_p,ctypes.c_uint];lib.pdm_ring_stat.restype=ctypes.c_uint64
lib.pdm_ring_stream_id.argtypes=[ctypes.c_void_p];lib.pdm_ring_stream_id.restype=ctypes.c_uint32
lib.pdm_udp_encode.argtypes=[ctypes.POINTER(Meta),ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p,ctypes.c_uint,ctypes.c_void_p,ctypes.c_size_t];lib.pdm_udp_encode.restype=ctypes.c_size_t
lib.pdm_crc32.argtypes=[ctypes.c_void_p,ctypes.c_size_t];lib.pdm_crc32.restype=ctypes.c_uint32
if a.synthetic_fixture:
    templates=[];gsc_values=[]
    for i in range(256):
        w=[0]*16;w[0]=0x47534301;w[1]=i;w[2]=1;w[5]=65536;w[6]=1
        beam=i-128;w[7]=(beam&65535)|((beam&65535)<<16)
        for ch in range(12):w[8+ch//2]|=((i*13+ch*71)%2000-1000&65535)<<(16*(ch&1))
        templates.append(struct.pack('<16I',*w));gsc_values.append(beam if i<128 else beam//2)
else:
    templates=[int(t,16).to_bytes(64,'little') for t in (R/'build/m8_20261016/rtl_packets/packets.hex').read_text().split()]
    raw_gsc=(R/'build/m8_20261016/rtl_packets/gsc_output.bin').read_bytes()
    gsc_values=list(struct.unpack('<%dh'%(len(raw_gsc)//2),raw_gsc))
names=['frames','corrupt','ownership','io','poll_timeout','duplicates','out_of_order','sample_gaps','source_restarts','timestamp_rollbacks','recoveries']
def stats(r):return {n:int(lib.pdm_ring_stat(r,i)) for i,n in enumerate(names)}
def slot(owner,n,cal=2,seq=None,stamp=None):
    data=bytearray(128);data[:64]=templates[n%256]
    seq=(0xffffff00+n)&0xffffffff if seq is None else seq
    stamp=n*1024+17 if stamp is None else stamp
    struct.pack_into('<I',data,4,seq);struct.pack_into('<I',data,12,0xffffff00 if seq>=0xffffff00 else 0)
    struct.pack_into('<Q6I',data,64,stamp,owner,0,0x394d4450,128,cal,0x0010000c)
    struct.pack_into('<II',data,120,zlib.crc32(data[:120]),~owner&0xffffffff)
    return bytes(data)
class CacheModel:
    def __init__(self,n):
        self.reg={0:0x394d4450,4:0,8:0,12:4,16:0,20:0,24:0,40:64,68:2}
        self.remaining=n;self.index=0;self.ddr=bytearray(2048);self.cache=ctypes.create_string_buffer(2048)
        ctypes.memset(self.cache,0xcc,2048)
        self.barriers=0;self.invalidations=0;self.flushes=0;self.map_barrier=-1;self.inv_barrier=-1
        self.busy=0;self.fault=False;self.bad_map=False;self.fail_release=False;self.violations=[];self.writes=[]
        self.bad_crc=set();self.duplicates=set();self.out_of_order=set();self.restart_at=None;self.bad_owner=set();self.bad_cal=set()
        self.functions=[READ(self.read),WRITE(self.write),CACHE(self.invalidate),CACHE(self.flush),BARRIER(self.barrier),MAP(self.map)]
        self.io=IO(None,*self.functions)
    def publish(self):
        for _ in range(3):
            used=(self.reg[20]-self.reg[16])&0xffffffff
            if not self.reg[4] or self.fault or not self.remaining or used>=16:return
            owner=self.reg[20];n=self.index;seq=(0xffffff00+n)&0xffffffff;stamp=n*1024+17
            if n in self.duplicates:seq=(seq-1)&0xffffffff;stamp-=1024
            if n in self.out_of_order:seq=(seq-2)&0xffffffff
            if self.restart_at is not None and n>=self.restart_at:seq=n-self.restart_at;stamp=(n-self.restart_at)*1024+17
            record=bytearray(slot(owner,n,3 if n in self.bad_cal else 2,seq,stamp))
            if n in self.bad_owner:
                struct.pack_into('<I',record,72,(owner+1)&0xffffffff);struct.pack_into('<I',record,124,~(owner+1)&0xffffffff)
                struct.pack_into('<I',record,120,zlib.crc32(record[:120]))
            if n in self.bad_crc:record[40]^=1
            offset=(owner&15)*128;self.ddr[offset:offset+128]=record
            self.reg[20]=(owner+1)&0xffffffff;self.remaining-=1;self.index+=1
    def read(self,ctx,offset):
        if offset==20:self.publish()
        if offset==0x24:
            busy=self.busy>0
            if busy:self.busy-=1
            return (3 if busy else 0)|(16 if self.fault else 0)|(8 if self.reg[4] else 0)
        return self.reg.get(offset,0)
    def write(self,ctx,offset,value):
        self.writes.append((offset,value))
        if offset==4:
            if value&6 and (self.reg[4] or self.busy):return -1
            self.reg[4]=value&1
            if value&2:self.fault=False
            return 0
        if offset==16:
            if self.fail_release:self.fail_release=False;return -1
            if self.barriers<=self.map_barrier:self.violations.append('release without post-copy barrier')
            available=(self.reg[20]-self.reg[16])&0xffffffff
            if ((value-self.reg[16])&0xffffffff)>available:return -1
            self.reg[16]=value;self.publish();return 0
        if offset==64:self.reg[16]=self.reg[20]=value;return 0
        self.reg[offset]=value;return 0
    def invalidate(self,ctx,address,length):
        offset=address-self.reg[8]
        if length!=128 or offset<0 or offset+length>2048:self.violations.append('invalidation outside owned DDR');return
        ctypes.memmove(ctypes.addressof(self.cache)+offset,bytes(self.ddr[offset:offset+length]),length)
        self.inv_barrier=self.barriers;self.invalidations+=1
    def flush(self,ctx,address,length):
        if self.reg[4] or address!=self.reg[8] or length!=2048:self.violations.append('unsafe initial flush')
        self.ddr[:]=bytes(self.cache);self.flushes+=1
    def barrier(self,ctx):self.barriers+=1
    def map(self,ctx,address,length):
        if self.bad_map:return None
        if self.barriers<=self.inv_barrier:self.violations.append('map before invalidate completes')
        self.map_barrier=self.barriers;return ctypes.addressof(self.cache)+address-self.reg[8]
def new(model,seed=0xfffffff0,stream=33):
    r=ctypes.create_string_buffer(lib.pdm_stream_ring_size())
    rc=lib.pdm_ring_open(r,ctypes.byref(model.io),0x08000000,4,64,2,seed,stream,100)
    assert rc==0,rc
    return r
def collect(model,r,limit=200000):
    frames=[];result_codes=[];out=ctypes.create_string_buffer(128)
    for _ in range(limit):
        result=lib.pdm_ring_next(r,out);result_codes.append(result)
        if result==1:frames.append((int(lib.pdm_ring_stream_id(r)),bytes(out)))
        elif result<0:assert result==-3,(result,stats(r))
        elif not model.remaining and model.reg[20]==model.reg[16]:break
    else:raise AssertionError('ring did not drain')
    assert not model.violations,model.violations
    return frames,result_codes
model=CacheModel(100000);r=new(model);normal,_=collect(model,r)
assert len(normal)==100000 and stats(r)['sample_gaps']==0 and stats(r)['ownership']==stats(r)['corrupt']==0
assert model.flushes==1 and model.invalidations==100000
for i,(_,record) in enumerate(normal):
    assert struct.unpack_from('<I',record,4)[0]==(0xffffff00+i)&0xffffffff
    assert struct.unpack_from('<Q',record,64)[0]==i*1024+17
normal_stats=stats(r)
fault_model=CacheModel(50);fault_model.bad_crc={5};fault_model.duplicates={10};fault_model.out_of_order={15};fault_model.restart_at=20
fr=new(fault_model);fault_frames,codes=collect(fault_model,fr);fault_stats=stats(fr)
assert len(fault_frames)==47 and fault_stats['corrupt']==1 and fault_stats['duplicates']==1 and fault_stats['out_of_order']==1
assert fault_stats['source_restarts']==1 and fault_stats['timestamp_rollbacks']==1 and fault_stats['sample_gaps']==3
assert lib.pdm_ring_stream_id(fr)==34
for category in ('bad_owner','bad_cal'):
    m=CacheModel(10);getattr(m,category).add(4);state=new(m);frames,_=collect(m,state)
    assert len(frames)==9 and stats(state)['corrupt']==1
m=CacheModel(10);state=new(m);out=ctypes.create_string_buffer(128)
m.bad_map=True;assert lib.pdm_ring_next(state,out)==-4 and m.reg[16]==0xfffffff0
m.bad_map=False;m.fail_release=True;assert lib.pdm_ring_next(state,out)==-4 and m.reg[16]==0xfffffff0
frames,_=collect(m,state);assert len(frames)==10 and stats(state)['io']==2
m=CacheModel(10);state=new(m);m.fault=True;m.busy=10
assert lib.pdm_ring_recover(state,3)==-5 and stats(state)['poll_timeout']==1 and m.fault
m.busy=0;assert lib.pdm_ring_recover(state,10)==0 and stats(state)['recoveries']==1
frames,_=collect(m,state);assert len(frames)==10
invalids=0
for base,log,timeout,polls in [(0x08000001,4,64,10),(0,4,64,10),(0x0ffff800,12,64,10),(0x08000000,3,64,10),(0x08000000,13,64,10),(0x08000000,4,15,10),(0x08000000,4,64,0)]:
    m=CacheModel(0);state=ctypes.create_string_buffer(lib.pdm_stream_ring_size());before=bytes(state)
    assert lib.pdm_ring_open(state,ctypes.byref(m.io),base,log,timeout,2,0,33,polls)<0
    assert bytes(state)==before and not m.writes;invalids+=1
m=CacheModel(0);m.reg[20]=1;state=ctypes.create_string_buffer(lib.pdm_stream_ring_size())
assert lib.pdm_ring_open(state,ctypes.byref(m.io),0x08000000,4,64,2,0,33,10)==-2 and m.reg[20]==1 and m.reg[16]==0
# Independent zlib comparison of the firmware CRC.
rng=random.Random(20261016)
for n in (0,1,7,120,128,572,1104,4096):
    data=rng.randbytes(n);buf=ctypes.create_string_buffer(data)
    assert lib.pdm_crc32(buf,n)==zlib.crc32(data)
def encode(records,packet=0,stream=33,active=False,values=None,reasons=None):
    n=len(records);slots=b''.join(records);buf=ctypes.create_string_buffer(slots)
    if values is None:values=[struct.unpack_from('<h',b,30)[0] for b in records]
    if reasons is None:reasons=[1]*n
    gsc=(ctypes.c_int16*n)(*values);why=(ctypes.c_uint16*n)(*reasons)
    meta=Meta(stream,packet,2,0,7 if active else 6);out=ctypes.create_string_buffer(1108)
    size=lib.pdm_udp_encode(ctypes.byref(meta),buf,gsc,why,n,out,1108)
    assert size==48+132*n+4,size
    return bytes(out[:size])
datagrams=[encode([record for _,record in normal[i:i+8]],i//8) for i in range(0,64,8)]
receiver=Statistics()
for d in datagrams:assert len(receiver.ingest(d))==8
assert receiver.counts['frames_accepted']==64 and not receiver.counts['invalid_datagrams']
fault_receiver=Statistics()
for i in (0,2,2,1,3):fault_receiver.ingest(datagrams[i])
assert fault_receiver.counts['duplicate_datagrams']==1 and fault_receiver.counts['out_of_order_datagrams_discarded']==1
assert fault_receiver.counts['datagram_sequence_holes']==1 and fault_receiver.counts['sample_sequence_holes']==8
bad=bytearray(datagrams[0]);bad[-1]^=1;assert fault_receiver.ingest(bad)==[]
bad=bytearray(datagrams[0]);struct.pack_into('<H',bad,22,8);struct.pack_into('<I',bad,len(bad)-4,zlib.crc32(bad[:-4]));assert fault_receiver.ingest(bad)==[]
bad=bytearray(datagrams[0]);bad[48+40]^=1;struct.pack_into('<I',bad,len(bad)-4,zlib.crc32(bad[:-4]));assert fault_receiver.ingest(bad)==[]
assert fault_receiver.counts['invalid_datagrams']==3
wrap_receiver=Statistics()
for i,seq in enumerate((0xfffffffe,0xffffffff,0,1)):
    d=encode([record for _,record in normal[240+i*8:248+i*8]],seq)
    assert len(wrap_receiver.ingest(d))==8
assert wrap_receiver.counts['frames_accepted']==32 and not wrap_receiver.counts['timestamp_rate_errors']
# Default fixtures replay actual RTL DAS/FIR packets and C GSC results from M8.
# --synthetic-fixture verifies transport fields only, not that arithmetic.
# DDR ownership/time headers come from the independent memory model in both modes.
active_receiver=Statistics()
for start in range(0,256,8):
    records=[]
    for i in range(start,start+8):
        b=bytearray(slot(i,i,seq=i,stamp=i*1024+17));b[:64]=templates[i]
        struct.pack_into('<I',b,120,zlib.crc32(b[:120]));records.append(bytes(b))
    reasons=[2 if i<128 else 0 for i in range(start,start+8)]
    dg=encode(records,start//8,active=True,values=gsc_values[start:start+8],reasons=reasons)
    decoded=active_receiver.ingest(dg);assert [f['gsc'] for f in decoded]==gsc_values[start:start+8]
assert active_receiver.counts['frames_accepted']==256 and active_receiver.counts['gsc_active_frames']==128
# Real sockets, localhost only. Does not alter interface/routing/proxy settings.
loopback=Statistics()
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as rx,socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as tx:
    rx.bind(('127.0.0.1',0));rx.settimeout(2)
    for d in datagrams:tx.sendto(d,rx.getsockname());loopback.ingest(rx.recvfrom(2048)[0])
assert loopback.counts['frames_accepted']==64
result={'status':'PASS_SOFTWARE_LOOPBACK','hardware':'DEFERRED_HARDWARE','normal_ring_frames':100000,
 'fixture':'synthetic_transport_only' if a.synthetic_fixture else 'actual_m8_rtl_gsc',
 'rtl_gsc_arithmetic_validated':not a.synthetic_fixture,'ubsan_enabled':bool(sanitizer),
 'normal_ring_stats':normal_stats,'cache_invalidations':model.invalidations,'cache_flushes':model.flushes,
 'fault_ring_stats':fault_stats,'invalid_configuration_rejections':invalids,
 'receiver_fault_stats':dict(fault_receiver.counts),'receiver_wrap_stats':dict(wrap_receiver.counts),
 'active_gsc_end_to_end_stats':dict(active_receiver.counts),'udp_loopback_stats':dict(loopback.counts),
 'board_network_throughput_validated':False}
(O/'metrics.json').write_text(json.dumps(result,indent=2));print('PDM_STREAM_SOFTWARE_PASS',json.dumps(result))
