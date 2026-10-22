"""Read-only source audit; preserve a copy of drift without reverting any work."""
from pathlib import Path
import argparse,datetime,hashlib,json,shutil

R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
expected={'rtl/array/rv32_gsc_tap.v','rtl/soc/rv32_soc.v','rtl/soc/rv32_ps_top.v',
          'scripts/create_zynq_project.tcl','scripts/filelist.f'}
def digest(f):return hashlib.sha256(f.read_bytes()).hexdigest()
baseline=json.loads((R/'build/m9_20261016/before_hashes.json').read_text(encoding='utf-8-sig'))
changes=[]
for item in baseline:
    # The recorded paths are Windows paths; resolve through the project suffix.
    name=item['Path'].replace('\\','/').split('/zynq_-pl_-simd_-verilog/',1)[1]
    if '__pycache__/' in name:continue
    f=R/name
    current=digest(f) if f.is_file() else None
    if current!=item['Hash'].lower():
        changes.append(dict(path=name,before=item['Hash'].lower(),current=current,
                            authorized_m9_file=name in expected))
        if f.is_file():
            target=O/'current_snapshot'/name;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(f,target)
implemented=json.loads((R/'build/zynq12_integrated_plan/m9_impl_20261016/source_manifest.json').read_text(encoding='utf-8-sig'))
impl_drift=[]
for name,sha in implemented.items():
    f=R/name
    if f.is_file() and digest(f)!=sha:
        impl_drift.append(dict(path=name,implemented=sha,current=digest(f)))
result=dict(status='BLOCKED_WORKSPACE_DRIFT' if impl_drift or any(not x['authorized_m9_file'] for x in changes) else 'PASS',
            timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            note='File allowlist is not blanket approval for new concurrent edits within an allowed file.',
            changed_preexisting_files=changes,implemented_source_drift=impl_drift,
            board_actions='NONE',source_mutations='NONE')
(O/'audit.json').write_text(json.dumps(result,indent=2))
print(result['status'])
for entry in impl_drift:print('IMPLEMENTATION_SOURCE_DRIFT',entry['path'])
raise SystemExit(2 if result['status']!='PASS' else 0)
