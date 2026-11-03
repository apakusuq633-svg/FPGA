"""Independent local test bundle; never alters prior releases or accesses JTAG."""
import argparse,json,hashlib,shutil
from pathlib import Path
r=Path(__file__).resolve().parents[1]
a=argparse.ArgumentParser();a.add_argument('stage');args=a.parse_args()
assert args.stage.replace('_','').isalnum()
base=r/'build/gui9_complete_release';out=r/'build/snapshot_repair_20261026'/args.stage
assert not out.exists(), 'Never overwrite an existing stage'
m=json.loads((base/'manifest.json').read_text())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for n in ['pl.bit','ps7_init.tcl','program.tcl','program.ps1','jtag_guard.tcl','check_jtag_owner.ps1']:
 assert sha(base/n)==m['files'][n]['sha256'],n
ps=r/'build/ui_pipeline_circular9';proof=json.loads((ps/'build_manifest.json').read_text(encoding='utf-8-sig'))
assert sha(ps/'ui.elf')==proof['elf_sha256']
for n,h in proof['source_sha256'].items():assert sha(r/n)==h,n
out.mkdir()
for n in ['pl.bit','ps7_init.tcl','program.tcl','program.ps1','jtag_guard.tcl','check_jtag_owner.ps1']:shutil.copy2(base/n,out/n)
for n,dst in [('ui.elf','ps_ui.elf'),('build_manifest.json','ps_build_manifest.json')]:shutil.copy2(ps/n,out/dst)
m['files']={p.name:{'bytes':p.stat().st_size,'sha256':sha(p)} for p in out.iterdir()}
m['status']='SNAPSHOT_REPAIR_'+args.stage.upper()+'_BOARD_PENDING';m['physical_board_tested']=False
(out/'manifest.json').write_text(json.dumps(m,indent=2))
print('BUNDLE',out,'ELF',sha(out/'ps_ui.elf'))
