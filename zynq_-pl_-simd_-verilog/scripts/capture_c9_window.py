"""Explicitly opt-in capture from the board; running without --enable does nothing.
No background polling. Always attempts POST disable, even after capture failure."""
from pathlib import Path
import argparse,json,struct,hashlib,urllib.request,ipaddress

def capture(request,output,frames=160256,enable=False):
 if not enable:raise ValueError('Explicit enable is required')
 if not 1024<=frames<=160256:raise ValueError('frames outside1024..160256')
 output=Path(output)
 if output.exists():raise ValueError('Refusing to overwrite output')
 output.mkdir(parents=True);enabled=False;disabled=False;complete=False;meta={};problem=None
 try:
  state=json.loads(request('POST','/api/debug/window/enable'));enabled=state.get('enabled')==1
  if not enabled:raise ValueError('Board did not enable export')
  meta=json.loads(request('GET',f'/api/debug/window?frames={frames}'))
  assert meta['format']=='C9W2' and meta['version']==1 and meta['frames']==frames and meta['channels']==9
  assert meta['sample_rate_num']==156250 and meta['sample_rate_den']==1 and 1<=meta['max_chunk_frames']<=1024
  assert meta['source'] in ['live_history_frozen_copy','synthetic_test_fixture']
  sha=hashlib.sha256();size=0
  with (output/'audio.pcm.part').open('xb') as f:
   for offset in range(0,frames,meta['max_chunk_frames']):
    count=min(meta['max_chunk_frames'],frames-offset)
    packet=request('GET',f"/api/debug/window?token={meta['token']}&offset={offset}&count={count}")
    assert len(packet)==48+18*count,'Truncated or extra chunk bytes'
    expected=(0x43395732,1,meta['token'],156250,1,frames,offset,count,meta['first_sample'],meta['epoch'],meta['session'],9)
    assert struct.unpack('<12I',packet[:48])==expected,'Mismatched token/window/offset/era'
    payload=packet[48:];f.write(payload);sha.update(payload);size+=len(payload)
  assert size==18*frames
  (output/'audio.pcm.part').rename(output/'audio.pcm');complete=True
  meta.update(format='s16le_interleaved',wire_format='C9W2',source='simulation' if meta['source']=='synthetic_test_fixture' else 'captured_pcm',sha256=sha.hexdigest(),bytes=size,completed=True,hardware_function_validated=False)
 except Exception as e:problem=e
 finally:
  try:disabled=json.loads(request('POST','/api/debug/window/disable')).get('enabled')==0
  except Exception:disabled=False
  meta.update(completed=complete,disabled_verified=disabled,export_enabled_by_this_tool=enabled)
  if problem:meta['error']=str(problem)
  (output/'metadata.json').write_text(json.dumps(meta,indent=2),encoding='utf8')
 if problem:raise problem
 if not disabled:raise RuntimeError('Capture saved, but disable unconfirmed; manually disable export on the board')
 return meta

def main():
 p=argparse.ArgumentParser();p.add_argument('--base-url',default='http://192.168.2.10');p.add_argument('--output',type=Path,required=True);p.add_argument('--frames',type=int,default=160256);p.add_argument('--enable',action='store_true');a=p.parse_args()
 if not a.enable:p.error('No network accessed. Pass --enable to explicitly enable one capture, followed by disable.')
 from urllib.parse import urlsplit
 url=urlsplit(a.base_url);assert url.scheme=='http' and ipaddress.ip_address(url.hostname).is_private and not url.username and not url.query and url.path in ('','/')
 def request(method,path):
  r=urllib.request.Request(a.base_url.rstrip('/')+path,data=b'' if method=='POST' else None,method=method,headers={'Cache-Control':'no-store'})
  with urllib.request.urlopen(r,timeout=10) as response:return response.read()
 result=capture(request,a.output,a.frames,True);print('CAPTURE_COMPLETE_AND_DISABLED',result['sha256'])
if __name__=='__main__':main()
