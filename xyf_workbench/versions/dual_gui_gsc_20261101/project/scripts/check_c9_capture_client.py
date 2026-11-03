"""No network: fake transport verifies frozen protocol and cleanup paths."""
from pathlib import Path
import tempfile,json,struct,hashlib
from capture_c9_window import capture
R=Path(__file__).resolve().parents[1];O=R/'build/offline_closure_20261027';results=[]
class Mock:
 def __init__(self,mode='ok'):self.mode=mode;self.calls=[];self.enabled=False
 def __call__(self,method,path):
  self.calls.append((method,path))
  if method=='POST':
   if path.endswith('/enable'):self.enabled=True;return b'{"enabled":1}'
   if self.mode=='disable_failure':raise OSError('simulated disable failure')
   self.enabled=False;return b'{"enabled":0}'
  if 'frames=' in path:return json.dumps(dict(format='C9W2',version=1,token=7,frames=16640,channels=9,sample_rate_num=156250,sample_rate_den=1,first_sample=40000,epoch=3,session=4,max_chunk_frames=1024,source='synthetic_test_fixture')).encode()
  from urllib.parse import parse_qs,urlsplit
  q=parse_qs(urlsplit(path).query);offset=int(q['offset'][0]);count=int(q['count'][0]);h=[0x43395732,1,7,156250,1,16640,offset,count,40000,3,4,9]
  if self.mode=='token':h[2]+=1
  if self.mode=='epoch':h[9]+=1
  if self.mode=='offset':h[6]+=1
  if self.mode=='disconnect':raise OSError('simulated disconnect')
  payload=b''.join(struct.pack('<h',((40000+offset+i+ch+32768)%65536)-32768) for i in range(count) for ch in range(9));data=struct.pack('<12I',*h)+payload
  return data[:-1] if self.mode=='truncated' else data
with tempfile.TemporaryDirectory() as root:
 root=Path(root)
 for mode in ['ok','token','epoch','offset','disconnect','truncated']:
  mock=Mock(mode);out=root/mode
  try:m=capture(mock,out,16640,True);assert mode=='ok' and m['completed'] and m['source']=='simulation';raw=(out/'audio.pcm').read_bytes();assert len(raw)==16640*18 and hashlib.sha256(raw).hexdigest()==m['sha256']
  except Exception:assert mode!='ok' and not (out/'audio.pcm').exists()
  assert not mock.enabled and mock.calls[-1]==('POST','/api/debug/window/disable');results.append(mode)
 mock=Mock()
 try:capture(mock,root/'no_enable',16640,False);assert False
 except ValueError:pass
 assert not mock.calls
 try:capture(mock,root/'ok',16640,True);assert False
 except ValueError:pass
 assert not mock.calls
 mock=Mock('disable_failure');out=root/'disable_failure'
 try:capture(mock,out,16640,True);assert False
 except RuntimeError:pass
 meta=json.loads((out/'metadata.json').read_text());assert meta['completed'] and not meta['disabled_verified'] and (out/'audio.pcm').exists()
 results.append('disable_failure_reported_without_discarding_valid_capture')
(O/'capture_client_checks.json').write_text(json.dumps({'passed':True,'network_accessed':False,'cases':results+['no_enable_no_requests','no_overwrite_no_requests']},indent=2));print('CAPTURE_CLIENT_MOCK_PASS cases=9 no_network=1')
