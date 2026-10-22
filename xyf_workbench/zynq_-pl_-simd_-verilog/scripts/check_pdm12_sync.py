"""M6 digital shared-DATA verification; no hardware acceptance implied."""
from pathlib import Path
import argparse,hashlib,json,subprocess,re
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
inputs=[R/'tb/tb_pdm12_sync.v',R/'tb/tb_pdm_array_rx.v',*sorted((R/'rtl/array').glob('*.v'))]
(O/'sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs},indent=2))
# Preserve the original raw-bit/CIC comparison independently of the production
# startup gate. Production defaults are verified by check_pdm_shared.py.
bench=O/'tb_pdm12_sync_diagnostic.v'
bench.write_text((R/'tb/tb_pdm12_sync.v').read_text().replace(
    'rv32_pdm_array_rx #(', 'rv32_pdm_array_rx #(.MIC_STARTUP_CYCLES(0),.CIC_SETTLE_FRAMES(0),'))
inputs=[bench if f==R/'tb/tb_pdm12_sync.v' else f for f in inputs]
results=[]
for name,mode,delay in [('normal_fast',0,40),('normal_max',0,108),('near_sample',0,124),('lr_swap',1,108),('lr_conflict',2,108),('late_data_counterexample',3,140)]:
    exe=O/name
    commands=[['iverilog','-g2012','-s','tb_pdm12_sync','-P',f'tb_pdm12_sync.MODE={mode}','-P',f'tb_pdm12_sync.DELAY_NS={delay}','-o',str(exe),*map(str,inputs)],['vvp',str(exe)]]
    for i,cmd in enumerate(commands):
        q=subprocess.run(cmd,cwd=R,capture_output=True,text=True)
        (O/f'{name}_{i}.log').write_text(q.stdout+q.stderr)
        assert q.returncode==0,(name,q.stdout,q.stderr)
    assert 'PDM12_SYNC_PASS' in q.stdout,q.stdout
    results.append({'name':name,'mode':mode,'delay_ns':delay,'status':'PASS','summary':q.stdout.strip(),'commands':commands})
    (O/'results.json').write_text(json.dumps(results,indent=2));print(q.stdout.strip(),flush=True)
print('M6_DIGITAL_SYNC_PASS hardware=UNVERIFIED_HARDWARE')
