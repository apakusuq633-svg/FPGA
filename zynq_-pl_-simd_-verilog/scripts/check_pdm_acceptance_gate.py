"""Non-vendor failure injection for missing endpoints, bad slack and stale manifests."""
from pathlib import Path
import argparse,csv,json,shutil,subprocess
p=argparse.ArgumentParser();p.add_argument('--evidence',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();R=Path(__file__).resolve().parents[1];O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
helper=R/'scripts/pdm_external_acceptance.py';rows=[]
for name in ['good','missing_endpoint','negative_slack','unexpected_exception']:
 out=O/name;(out/'window').mkdir(parents=True)
 shutil.copyfile(a.evidence/'inputs.json',out/'inputs.json')
 records=list(csv.DictReader((a.evidence/'window/paths.csv').open()))
 columns=list(records[0])
 if name=='missing_endpoint':records.pop()
 if name=='negative_slack':records[0]['slack']='-0.001'
 if name=='unexpected_exception':records[0]['exception']='datapath_only'
 with (out/'window/paths.csv').open('w') as f:
  w=csv.DictWriter(f,fieldnames=columns);w.writeheader();w.writerows(records)
 cmd=['python3',str(helper),'verify','--output',str(out)]
 q=subprocess.run(cmd,capture_output=True,text=True);(out/'run.log').write_text(q.stdout+q.stderr)
 assert (q.returncode==0)==(name=='good'),(name,q.stdout,q.stderr)
 rows.append(dict(case=name,command=cmd,returncode=q.returncode,status='PASS'))
e=json.loads((a.evidence/'inputs.json').read_text());bad=O/'incomplete_manifest.json';bad.write_text(json.dumps({'rtl/array/rv32_pdm_array_rx.v':e['rtl']['rtl/array/rv32_pdm_array_rx.v']}))
cmd=['python3',str(helper),'prepare','--output',str(O/'incomplete'),'--config',str(R/'configs/pdm_external_assumptions.json'),'--checkpoint',e['checkpoint'],'--manifest',str(bad)]
q=subprocess.run(cmd,capture_output=True,text=True);(O/'incomplete.log').write_text(q.stdout+q.stderr);assert q.returncode!=0
rows.append(dict(case='incomplete_manifest',command=cmd,returncode=q.returncode,status='PASS'))
(O/'results.json').write_text(json.dumps(rows,indent=2));print('PDM_ACCEPTANCE_FAILURE_INJECTION_PASS cases=5')
