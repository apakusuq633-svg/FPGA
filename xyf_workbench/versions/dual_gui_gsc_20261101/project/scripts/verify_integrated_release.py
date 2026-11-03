"""Read-only verification of the frozen local M0-M5 handoff."""
from pathlib import Path
import hashlib,json,re

root=Path(__file__).resolve().parents[1]
base=root/'build/zynq12_integrated_plan'
manifest=json.loads((base/'release_manifest.json').read_text())
assert manifest['status']=='PASS_SIM_IMPL' and manifest['hardware']=='DEFERRED_HARDWARE'
paths=[r['path'] for r in manifest['files']]
assert len(paths)==len(set(paths))
for row in manifest['files']:
    p=root/row['path']
    assert p.is_file() and p.stat().st_size==row['bytes'],p
    h=hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    assert h.hexdigest()==row['sha256'],p
reports=[root/manifest['report']]+list((base/'reports/final').glob('M?.md'))
link_count=0
for p in reports:
    text=p.read_text(encoding='utf-8')
    assert '\ufffd' not in text,p
    for target in re.findall(r'\]\(([^)]+)\)',text):
        if target.startswith(('http:','https:','#')):continue
        assert (p.parent/target.split('#',1)[0]).exists(),(p,target)
        link_count+=1
acceptance=json.loads((base/'reports/final/acceptance.json').read_text())
long=acceptance['long4096']
assert long['status']=='PASS' and long['windows']==4096
assert long['raw_drop']==long['window_drop']==long['audio_drop']==0
assert long['raw_checks']==4096*12*1024*3
assert json.loads((root/'configs/production_array.json').read_text())['mic_xyz'] is None
print(json.dumps({'status':'RELEASE_HANDOFF_PASS','manifest_files_verified':len(paths),
                  'report_links_verified':link_count,'long_windows':long['windows'],
                  'raw_checks':long['raw_checks'],'timing':manifest['timing']},ensure_ascii=False))
