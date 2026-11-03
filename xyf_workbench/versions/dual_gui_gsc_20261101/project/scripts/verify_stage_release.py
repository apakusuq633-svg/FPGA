"""Read-only hash verification of a stage manifest; does not run board tools."""
from pathlib import Path
import argparse,hashlib,json
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True);a=p.parse_args()
manifest=json.loads(a.manifest.read_text(encoding='utf-8-sig'));seen=set();total=0
assert manifest['status'].startswith('PASS') and manifest['hardware']=='DEFERRED_HARDWARE'
for row in manifest['files']:
 f=(R/row['path']).resolve();assert R in f.parents and row['path'] not in seen
 seen.add(row['path']);assert f.is_file() and f.stat().st_size==row['bytes'],row['path']
 h=hashlib.sha256()
 with f.open('rb')as stream:
  for b in iter(lambda:stream.read(1024*1024),b''):h.update(b)
 assert h.hexdigest()==row['sha256'],('HASH_MISMATCH',row['path']);total+=row['bytes']
print('STAGE_RELEASE_HANDOFF_PASS',json.dumps(dict(status=manifest['status'],files=len(seen),bytes=total,hardware=manifest['hardware'])))
