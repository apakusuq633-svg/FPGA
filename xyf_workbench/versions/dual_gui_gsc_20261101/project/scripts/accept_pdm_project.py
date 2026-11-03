"""Release gate for current PDM evidence; never equates software PASS with board PASS."""
from pathlib import Path
import argparse,csv,hashlib,json
p=argparse.ArgumentParser();p.add_argument('--external',type=Path,required=True);p.add_argument('--ps',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();R=Path(__file__).resolve().parents[1]
e=json.loads((a.external/'acceptance.json').read_text());assert e['status']=='PASS_CONDITIONAL' and e['endpoints']==12 and e['checks']==24
assert e['hardware']=='UNVERIFIED_HARDWARE'
assert hashlib.sha256(Path(e['checkpoint']).read_bytes()).hexdigest()==e['checkpoint_sha256']
for name,digest in e['rtl'].items():assert hashlib.sha256((R/name).read_bytes()).hexdigest().lower()==digest.lower(),name
rows=list(csv.DictReader((a.external/'window/paths.csv').open()));assert len(rows)==24 and all(float(r['slack'])>=0 for r in rows)
ps=json.loads((a.ps/'results.json').read_text());assert len(ps['cases'])==12 and all(c['returncode']==c['expected']==0 for c in ps['cases'])
assert hashlib.sha256((R/'sw/ps_pdm.c').read_bytes()).hexdigest()==ps['source_sha256']
result=dict(status='PASS_SOFTWARE_CONDITIONAL_STA',hardware='UNVERIFIED_HARDWARE',external=str(a.external),ps=str(a.ps),endpoints=12,checks=24,ps_cases=12,production_sample_ns=125)
a.output.write_text(json.dumps(result,indent=2));print('PDM_PROJECT_ACCEPTANCE_PASS_CONDITIONAL hardware=UNVERIFIED_HARDWARE')
