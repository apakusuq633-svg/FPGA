"""Sample-position and fault experiments; no production RTL is modified."""
from pathlib import Path
import argparse,json,subprocess,hashlib
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
inputs=[R/'rtl/array'/f for f in ['rv32_pdm_array_rx.v','rv32_pdm_cic.v','rv32_pdm_clkgen.v']]+[R/'tb/tb_pdm_shared_startup.v']
hashes={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs}
(O/'sources.json').write_text(json.dumps(hashes,indent=2));rows=[]
cases=[]
for h,c in [(4,12),(5,13),(6,14)]:
    ns=(h+1)*25
    cases += [(f'phase{ns}_nominal',0,116,h,c,0),(f'phase{ns}_one_ns_before',0,ns-1,h,c,2),(f'phase{ns}_one_ns_late',5,ns+1,h,c,2)]
for name,mode in [('keeper_missing_a',6),('keeper_missing_b',7),('clock_stuck_low',8),('clock_runt',9),('unplug_both_keeper',10)]:cases.append((name,mode,116,4,12,2))
for name,mode,delay,h,c,full in cases:
    exe=O/name
    cmd=['iverilog','-g2012','-s','tb_pdm_shared_startup','-o',str(exe)]
    for k,v in [('MODE',mode),('DELAY',delay),('HOLD',h),('CONSUME',c),('FULL',full)]:cmd+=['-P',f'tb_pdm_shared_startup.{k}={v}']
    commands=[cmd+list(map(str,inputs)),['vvp',str(exe)]]
    row={'case':name,'commands':commands,'expectation':'NORMAL' if mode==0 else 'FAULT_OBSERVED_BY_TESTBENCH','hardware_detector':'NOT_CLAIMED'}
    for i,command in enumerate(commands):
        q=subprocess.run(command,cwd=R,capture_output=True,text=True,timeout=240)
        (O/f'{name}_{i}.log').write_text(q.stdout+q.stderr)
        assert q.returncode==0,(name,q.stdout[-2000:],q.stderr[-2000:])
    assert 'PDM_SHARED_PASS' in q.stdout and 'FATAL' not in q.stdout,q.stdout
    row.update(status='PASS',summary=q.stdout.strip());rows.append(row)
    (O/'results.json').write_text(json.dumps(rows,indent=2));print(name,q.stdout.strip(),flush=True)
assert all(hashlib.sha256((R/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items())
print('PDM_CONVERGENCE_FUNCTION_PASS')
