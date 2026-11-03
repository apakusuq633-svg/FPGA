"""Strict provenance checks shared by capture and replay; no hardware access."""
import hashlib,json
KEYS=('origin','sequence','session','epoch','first','end')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def event_key(event):
 if event.get('origin') not in ('PS_AUX','PL_MAIN_MAP'):raise ValueError('Unknown event origin')
 for k in KEYS[1:]:
  if type(event.get(k)) is not int or not 0<=event[k]<=0xffffffff:raise ValueError('Invalid event key: '+k)
 frames=(event['end']-event['first'])&0xffffffff
 if frames!=(16640 if event['origin']=='PS_AUX' else 1024) or (event['origin']=='PS_AUX' and (event['first']%4 or event['end']%4)):raise ValueError('Unsupported source window')
 return {k:event[k] for k in KEYS}
def validate_identity(envelope,manifest):
 if manifest.get('consensus_experiment') is not False or manifest.get('debug_observation') is not True:raise ValueError('Not an observation-only manifest')
 bid=manifest.get('evidence_build_id')
 if not bid or bid=='unrecorded' or envelope.get('evidence_build_id')!=bid:raise ValueError('Build identity mismatch')
 if envelope.get('geometry_version')!=manifest.get('geometry_version'):raise ValueError('Geometry version mismatch')
 for name in ('elf_sha256','bitstream_sha256','geometry_sha256','channel_mapping_sha256'):
  v=manifest.get(name)
  if not isinstance(v,str) or len(v)!=64 or any(c not in '0123456789abcdef' for c in v):raise ValueError('Missing manifest hash: '+name)
 if manifest.get('channel_order')!=['CH%d=U%d'%(i,i+1) for i in range(9)]:raise ValueError('Unsupported physical channel order')
 return event_key(envelope['event'])
def validate_recording(folder,manifest,envelope):
 m=json.loads((folder/'metadata.json').read_text());key=validate_identity(envelope,manifest)
 if not m.get('completed') or not m.get('exact_source') or m.get('format')!='s16le_interleaved':raise ValueError('Not a complete exact source recording')
 if (m.get('sample_rate_num'),m.get('sample_rate_den'),m.get('channels'),m.get('bit_depth'),m.get('endianness'))!=(156250,1,9,16,'little'):raise ValueError('PCM format/rate mismatch')
 if m.get('source_first')!=key['first'] or m.get('source_end')!=key['end'] or m.get('source_key')!=key or m.get('first_sample')!=(key['first']&~3) or m.get('end_sample')!=((key['end']+3)&0xfffffffc):raise ValueError('Source sequence/window mismatch')
 for k in ('evidence_build_id','geometry_version','elf_sha256','bitstream_sha256','geometry_sha256','channel_mapping_sha256','channel_order'):
  if m.get(k)!=manifest[k]:raise ValueError('Recording provenance mismatch: '+k)
 if m.get('event_sha256')!=digest(folder/'source_event.json') or m.get('manifest_sha256')!=digest(folder/'release_manifest.json'):raise ValueError('Sidecar hash mismatch')
 pcm=folder/'audio.pcm';frames=(((key['end']+3)&0xfffffffc)-(key['first']&~3))&0xffffffff
 if m.get('frames')!=frames or m.get('bytes')!=18*frames or pcm.stat().st_size!=18*frames or digest(pcm)!=m.get('sha256'):raise ValueError('PCM size/hash mismatch')
 return m,key
