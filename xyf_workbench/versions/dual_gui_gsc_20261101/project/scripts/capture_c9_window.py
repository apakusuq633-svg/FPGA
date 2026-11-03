"""Explicitly opt-in capture from the board; running without --enable does nothing.
No background polling. Always attempts POST disable, even after capture failure."""
from pathlib import Path
import argparse,json,struct,hashlib,urllib.request,ipaddress
from datetime import datetime,timezone
from c9_capture_identity import validate_identity

def capture(request,output,frames=160256,enable=False,event=None,manifest=None):
 if not enable:raise ValueError('Explicit enable is required')
 key=validate_identity(event,manifest) if event is not None else None
 if key:frames=(((key['end']+3)&0xfffffffc)-(key['first']&~3))&0xffffffff
 if not 1024<=frames<=160256 or frames%4:raise ValueError('frames outside aligned1024..160256')
 output=Path(output)
 if output.exists():raise ValueError('Refusing to overwrite output')
 output.mkdir(parents=True);enabled=False;disabled=False;complete=False;meta={};problem=None
 requested=datetime.now(timezone.utc).isoformat()
 try:
  state=json.loads(request('POST','/api/debug/window/enable'));enabled=state.get('enabled')==1
  if not enabled:raise ValueError('Board did not enable export')
  query=f'/api/debug/window?frames={frames}'
  if key:query+='&first={first}&end={end}&session={session}&epoch={epoch}&sequence={sequence}&origin={origin}'.format(**key)
  meta=json.loads(request('GET',query))
  if key:
   if not meta.get('exact_source') or meta.get('source_sequence')!=key['sequence'] or meta.get('origin')!=key['origin'] or meta.get('first_sample')!=(key['first']&~3) or meta.get('end_sample')!=((key['end']+3)&0xfffffffc) or meta.get('source_first')!=key['first'] or meta.get('source_end')!=key['end'] or meta.get('session')!=key['session'] or meta.get('epoch')!=key['epoch']:raise ValueError('Board froze a different source window')
   if meta.get('evidence_build_id')!=manifest['evidence_build_id'] or meta.get('geometry_version')!=manifest['geometry_version']:raise ValueError('Board identity mismatch')
  if not (meta['format']=='C9W2' and meta['version']==1 and meta['frames']==frames and meta['channels']==9):raise ValueError('Capture format/dimensions mismatch')
  if not (meta['sample_rate_num']==156250 and meta['sample_rate_den']==1 and 1<=meta['max_chunk_frames']<=1024):raise ValueError('Capture rate/chunk mismatch')
  if meta['source'] not in ['live_history_frozen_copy','synthetic_test_fixture']:raise ValueError('Unknown PCM source')
  sha=hashlib.sha256();size=0
  with (output/'audio.pcm.part').open('xb') as f:
   for offset in range(0,frames,meta['max_chunk_frames']):
    count=min(meta['max_chunk_frames'],frames-offset)
    packet=request('GET',f"/api/debug/window?token={meta['token']}&offset={offset}&count={count}")
    if len(packet)!=48+18*count:raise ValueError('Truncated or extra chunk bytes')
    expected=(0x43395732,1,meta['token'],156250,1,frames,offset,count,meta['first_sample'],meta['epoch'],meta['session'],9)
    if struct.unpack('<12I',packet[:48])!=expected:raise ValueError('Mismatched token/window/offset/era')
    payload=packet[48:];f.write(payload);sha.update(payload);size+=len(payload)
  if size!=18*frames:raise ValueError('Incomplete PCM payload')
  (output/'audio.pcm.part').rename(output/'audio.pcm')
  if key:
   (output/'source_event.json').write_text(json.dumps(event,indent=2),encoding='utf8')
   (output/'release_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf8')
   meta.update({k:manifest[k] for k in ('evidence_build_id','geometry_version','elf_sha256','bitstream_sha256','geometry_sha256','channel_mapping_sha256','channel_order')})
   meta.update(source_key=key,event_sha256=hashlib.sha256((output/'source_event.json').read_bytes()).hexdigest(),manifest_sha256=hashlib.sha256((output/'release_manifest.json').read_bytes()).hexdigest())
  meta.update(format='s16le_interleaved',wire_format='C9W2',source='simulation' if meta['source']=='synthetic_test_fixture' else 'captured_pcm',sha256=sha.hexdigest(),bytes=size,completed=True,hardware_function_validated=False)
  complete=True
 except Exception as e:problem=e
 finally:
  try:disabled=json.loads(request('POST','/api/debug/window/disable')).get('enabled')==0
  except Exception:disabled=False
  meta.update(completed=complete,disabled_verified=disabled,export_enabled_by_this_tool=enabled,request_utc=requested,result_utc=datetime.now(timezone.utc).isoformat(),recording_status="complete" if complete else "failed",bit_depth=16,endianness="little",interval="[first,end)")
  if key:meta['requested_source_key']=key
  if problem:meta['error']=str(problem)
  (output/'metadata.json').write_text(json.dumps(meta,indent=2),encoding='utf8')
 if problem:raise problem
 if not disabled:raise RuntimeError('Capture saved, but disable unconfirmed; manually disable export on the board')
 return meta

def main():
 p=argparse.ArgumentParser();p.add_argument('--base-url',default='http://192.168.2.10');p.add_argument('--output',type=Path,required=True);p.add_argument('--frames',type=int,default=160256);p.add_argument('--enable',action='store_true');p.add_argument('--event',type=Path);p.add_argument('--manifest',type=Path);a=p.parse_args()
 if bool(a.event)!=bool(a.manifest):p.error('Exact capture requires both --event and --manifest')
 if not a.enable:p.error('No network accessed. Pass --enable to explicitly enable one capture, followed by disable.')
 from urllib.parse import urlsplit
 url=urlsplit(a.base_url);assert url.scheme=='http' and ipaddress.ip_address(url.hostname).is_private and not url.username and not url.query and url.path in ('','/')
 def request(method,path):
  r=urllib.request.Request(a.base_url.rstrip('/')+path,data=b'' if method=='POST' else None,method=method,headers={'Cache-Control':'no-store'})
  with urllib.request.urlopen(r,timeout=10) as response:return response.read()
 result=capture(request,a.output,a.frames,True,event=json.loads(a.event.read_text(encoding='utf8')) if a.event else None,manifest=json.loads(a.manifest.read_text(encoding='utf8')) if a.manifest else None);print('CAPTURE_COMPLETE_AND_DISABLED',result['sha256'])
if __name__=='__main__':main()
