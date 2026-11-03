"""Explicit manual recording. No automatic board access or programming."""
import argparse,datetime,hashlib,json,socket,struct,time,zlib
from pathlib import Path
HEADER=struct.Struct('<11I')
class Capture:
 def __init__(self,stream):
  self.file=stream;self.session=None;self.packet=0;self.frames=0;self.final=False;self.failed=False;self.final_stats={}
 def ingest(self,data):
  if len(data)<44:raise ValueError('short packet')
  m,session,kind,packet,first,n,total,failed,overflow,gaps,crc=HEADER.unpack_from(data)
  check=bytearray(data);check[40:44]=bytes(4)
  if m!=0x52393132 or zlib.crc32(check)!=crc:raise ValueError('format/CRC')
  if self.session is None:self.session=session
  if session!=self.session:raise ValueError('source restart')
  if kind==2:
   if n or len(data) not in (76,100,112):raise ValueError('invalid final')
   start,lo,hi,endlo,endhi,drops,errors,timeouts=struct.unpack_from('<8I',data,44)
   self.final_stats=dict(source_first_sample=start,source_first_clock=lo+(hi<<32),source_last_clock=endlo+(endhi<<32),dropped_frames=drops,overflow_count=overflow,dma_errors=errors,dma_timeouts=timeouts,gap_count=gaps)
   if len(data)>=100:
    writes,retries,peak,sent,err,full=struct.unpack_from('<6I',data,76)
    self.final_stats.update(source_frame_count=total,write_errors=writes,tx_retries=retries,tx_queue_peak_blocks=peak,tx_sent_frames=sent,tx_last_error=err if err<2147483648 else err-4294967296,tx_queue_full=full)
    failed=failed or writes or full or sent!=total
   if len(data)>=112:
    alloc,reclaimed,free=struct.unpack_from('<3I',data,100)
    self.final_stats.update(tx_alloc_failures=alloc,tx_reclaimed_descriptors=reclaimed,tx_free_descriptors=free)
   delta=self.final_stats['source_last_clock']-self.final_stats['source_first_clock']
   expected=(total-1)*625/2 if total else 0
   self.final_stats['nominal_clock_hz']=40000000
   self.final_stats['timestamp_rate_check_pass']=total>1 and abs(delta-expected)<=1
   failed=failed or drops or errors or timeouts or not self.final_stats['timestamp_rate_check_pass']
   self.final=True;self.failed=bool(failed or overflow or gaps or total!=3840000 or self.frames!=total)
   return
  if kind!=1 or not 1<=n<=64 or len(data)!=44+18*n:raise ValueError('payload length')
  if packet!=self.packet or first!=self.frames:raise ValueError(f'packet/sample discontinuity: expected packet={self.packet}, first={self.frames}; received packet={packet}, first={first}, count={n}, session={session}')
  if self.frames+n>3840000:raise ValueError('excess frames')
  if self.file.write(data[44:])!=18*n:raise OSError('short write')
  self.frames+=n;self.packet+=1
 def metadata(self):
  return dict(sample_rate=128000,bit_depth=16,channels=9,sample_format='s16le',endianness='little',
   channel_order=['CH%d=U%d'%(i,i+1) for i in range(9)],duration=self.frames/128000,
   actual_frame_count=self.frames,file_size=18*self.frames,session=self.session,
   recording_status='complete' if self.final and not self.failed else 'failed',
   rate_validation='nominal digital rate; physical clock must be measured',acoustic_quality='not_certified_by_transport',physical_channel_independence='requires board test',**self.final_stats)
def main():
 a=argparse.ArgumentParser();a.add_argument('--board',default='192.168.2.10');a.add_argument('--out',required=True);args=a.parse_args()
 out=Path(args.out);out.mkdir(parents=True,exist_ok=False)
 started=datetime.datetime.now(datetime.timezone.utc).isoformat();error=None
 with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s, (out/'recording.partial.pcm').open('xb',buffering=0) as f:
  s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024);s.bind(('',0));s.settimeout(5)
  last_print=0.0;capture=Capture(f);s.sendto(b'START',(args.board,1235));end=time.monotonic()+45
  try:
   while not capture.final:
    if time.monotonic()>end:raise TimeoutError('45s total timeout')
    data,peer=s.recvfrom(2048)
    if peer[0]!=args.board or peer[1]!=1235:continue
    capture.ingest(data)
    if time.monotonic()-last_print>=1:
     print(f'{capture.frames}/3840000 frames; {capture.frames/128000:.3f}s; file bytes={capture.frames*18}',flush=True);last_print=time.monotonic()
  except (OSError,ValueError,TimeoutError,KeyboardInterrupt) as exc:error=str(exc);capture.failed=True
  finally:
   try:s.sendto(b'STOP',(args.board,1235))
   except OSError:pass
  try:f.flush();__import__('os').fsync(f.fileno())
  except OSError as exc:error=str(exc);capture.failed=True
 if capture.failed and error is None:error='Board reported failure or incomplete transfer; inspect source/tx counters'
 meta=capture.metadata();meta.update(capture_start_time=started,capture_start_time_source='PC START request UTC',error=error)
 partial=out/'recording.partial.pcm'
 meta['file_size']=partial.stat().st_size
 if meta['file_size']!=capture.frames*18:meta['recording_status']='failed';meta['error']='file size differs from received frames'
 if meta['recording_status']=='complete':
  partial.rename(out/'recording_9ch_128k_s16le.pcm');partial=out/'recording_9ch_128k_s16le.pcm'
 with partial.open('rb') as source:meta['sha256']=hashlib.file_digest(source,'sha256').hexdigest()
 (out/'metadata.json').write_text(json.dumps(meta,indent=2),encoding='utf-8');print(json.dumps(meta,indent=2))
 if meta['recording_status']!='complete':raise SystemExit(1)
if __name__=='__main__':main()
