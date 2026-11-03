import importlib.util,io,struct,zlib
from pathlib import Path
p=Path(__file__).parents[1]/'tools/receive.py';s=importlib.util.spec_from_file_location('rx',p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
def packet(index,first,n,kind=1,total=0):
 data=bytearray(struct.pack('<11I',0x52393132,77,kind,index,first,n,total,0,0,0,0))
 if kind==2:data.extend(struct.pack('<8I',0,0,0,0,0,0,0,0))
 for k in range(n):data.extend(struct.pack('<9h',*[first+k-c for c in range(9)]))
 struct.pack_into('<I',data,40,zlib.crc32(data));return bytes(data)
f=io.BytesIO();r=m.Capture(f);r.ingest(packet(0,0,64));r.ingest(packet(1,64,64))
x=struct.unpack('<1152h',f.getvalue())
for n in range(128):assert list(x[n*9:n*9+9])==[n-c for c in range(9)]
for bad in [packet(3,128,64),packet(2,129,64),packet(2,128,64)[:-1]]:
 try:r.ingest(bad)
 except ValueError:pass
 else:raise AssertionError('accepted invalid packet')
r.ingest(packet(2,128,0,2,128));assert r.failed and r.metadata()['recording_status']=='failed'
print('RAW9_RECEIVER_PASS channel order/delay, missing/reordered/truncated packets, incomplete final')

class CounterSink:
 def __init__(self):self.size=0
 def write(self,b):self.size+=len(b);return len(b)
f=CounterSink();r=m.Capture(f)
for first in range(0,3840000,64):
 data=bytearray(struct.pack('<11I',0x52393132,77,1,first//64,first,64,first+64,0,0,0,0)+bytes(1152))
 struct.pack_into('<I',data,40,zlib.crc32(data));r.ingest(data)
final=bytearray(packet(60000,3840000,0,2,3840000))
struct.pack_into('<8I',final,44,0,0,0,1199999688,0,0,0,0)
struct.pack_into('<I',final,40,0);struct.pack_into('<I',final,40,zlib.crc32(final));r.ingest(final)
assert r.metadata()['recording_status']=='complete' and f.size==69120000
print('RAW9_FULL_RECEIVER_PASS 60000 packets / 3840000 frames / 69120000 bytes; SYNTHETIC')

final.extend(struct.pack('<6I',0,500,2,3840000,0xffffffff,0))
struct.pack_into('<I',final,40,0);struct.pack_into('<I',final,40,zlib.crc32(final));r.ingest(final)
assert r.metadata()['recording_status']=='complete' and r.final_stats['tx_retries']==500 and r.final_stats['tx_last_error']==-1
print('RAW9_EXTENDED_STATUS_PASS transient retries do not imply capture failure')

final.extend(struct.pack('<3I',32,60000,256))
struct.pack_into('<I',final,40,0);struct.pack_into('<I',final,40,zlib.crc32(final));r.ingest(final)
assert r.final_stats['tx_alloc_failures']==32 and r.final_stats['tx_reclaimed_descriptors']==60000 and not r.failed
print('RAW9_RECLAIM_STATUS_PASS completed-descriptor and allocation counters')
