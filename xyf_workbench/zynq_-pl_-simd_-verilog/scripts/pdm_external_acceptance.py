"""Preflight/postflight for the PowerShell routed-PDM acceptance entry point."""
from pathlib import Path
import argparse,csv,hashlib,json,math
p=argparse.ArgumentParser();p.add_argument('phase',choices=['prepare','verify']);p.add_argument('--output',type=Path,required=True);p.add_argument('--config',type=Path);p.add_argument('--checkpoint',type=Path);p.add_argument('--manifest',type=Path)
a=p.parse_args();R=Path(__file__).resolve().parents[1];O=a.output.resolve()
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
if a.phase=='prepare':
    O.mkdir(parents=True,exist_ok=False)
    c=json.loads(a.config.read_text());assert c['status']=='ASSUMED_NOT_MEASURED' and c['hardware']=='UNVERIFIED_HARDWARE'
    assert c['system_period_ns']==25 and c['sample_after_drive_ns']==125 and c['part']=='xc7z020clg400-1'
    for k,v in c.items():
        if k.endswith('_ns'):assert isinstance(v,(int,float)) and math.isfinite(v) and v>=0,k
    for name in ['pcb_clock','pcb_data']:assert c[name+'_min_ns']<=c[name+'_max_ns']
    manifest=json.loads(a.manifest.read_text(encoding='utf-8-sig'));assert isinstance(manifest,dict)
    rtl={k:v for k,v in manifest.items() if k.startswith(('rtl/','build/')) and k.endswith(('.v','.vh'))}
    assert rtl and 'rtl/array/rv32_pdm_array_rx.v' in rtl
    expected={f.name for f in (R/'rtl').rglob('*') if f.suffix in ['.v','.vh']}
    assert len(rtl)==len(expected) and {Path(k).name for k in rtl}==expected,'Incomplete/duplicate RTL manifest'
    for name,digest in rtl.items():assert sha(R/name).lower()==digest.lower(),f'Stale checkpoint source manifest: {name}'
    config=dict(dmax=c['mic_tdv_max_ns']+c['pcb_clock_max_ns']+c['pcb_data_max_ns'],dmin=c['mic_thz_min_ns']+c['pcb_clock_min_ns']+c['pcb_data_min_ns'],uncertainty=c['relative_uncertainty_ns'])
    (O/'numeric_config.tcl').write_text(''.join(f'set pdm_{k} {v:.9f}\n' for k,v in config.items()))
    (O/'assumptions.json').write_text(json.dumps(c,indent=2))
    evidence=dict(checkpoint=str(a.checkpoint.resolve()),checkpoint_sha256=sha(a.checkpoint),manifest_sha256=sha(a.manifest),rtl=rtl,parameters=config,hardware='UNVERIFIED_HARDWARE')
    (O/'inputs.json').write_text(json.dumps(evidence,indent=2))
else:
    e=json.loads((O/'inputs.json').read_text())
    assert sha(Path(e['checkpoint']))==e['checkpoint_sha256']
    for name,digest in e['rtl'].items():assert sha(R/name).lower()==digest.lower(),name
    rows=list(csv.DictReader((O/'window/paths.csv').open()));assert len(rows)==24
    for group in ['A','B']:
        for kind in ['max','min']:
            selected=[r for r in rows if r['group']==group and r['kind']==kind];assert len(selected)==6
            assert len({r['cell'] for r in selected})==6
            for r in selected:
                assert float(r['slack'])>=0 and not r['exception'],r
                assert float(r['requirement'])==(125 if kind=='max' else -75)
    e.update(status='PASS_CONDITIONAL',endpoints=12,checks=24,setup_min_ns=min(float(r['slack']) for r in rows if r['kind']=='max'),hold_min_ns=min(float(r['slack']) for r in rows if r['kind']=='min'))
    (O/'acceptance.json').write_text(json.dumps(e,indent=2))
    print('PDM_EXTERNAL_AUTOMATION_PASS_CONDITIONAL endpoints=12 checks=24 hardware=UNVERIFIED_HARDWARE')
