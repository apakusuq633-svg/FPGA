"""Reproducible shared-DATA, startup and unchanged-CIC regression."""
from pathlib import Path
import argparse, hashlib, json, subprocess, re
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
p.add_argument('--channels',type=int,default=12,choices=[8,10,12])
p.add_argument('--hold',type=int,default=4);p.add_argument('--consume',type=int,default=12)
p.add_argument('--shared-only',action='store_true');a=p.parse_args()
assert 0 <= a.hold < 8 and a.consume == a.hold + 8
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
rows=[]
def run(name,commands,marker):
    row={'name':name,'commands':commands};rows.append(row)
    for i,cmd in enumerate(commands):
        q=subprocess.run(cmd,cwd=R,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=240)
        (O/f'{name}_{i}.log').write_text(q.stdout+q.stderr,encoding='utf-8')
        if q.returncode or (i==len(commands)-1 and (marker not in q.stdout or 'FAIL' in q.stdout or 'FATAL' in q.stdout)):
            row['status']='FAIL';(O/'results.json').write_text(json.dumps(rows,indent=2));raise RuntimeError(q.stdout[-3000:]+q.stderr[-3000:])
    row['status']='PASS';row['summary']=q.stdout.strip();print(name,q.stdout.strip()[-300:],flush=True)
    (O/'results.json').write_text(json.dumps(rows,indent=2))
rtl=[R/'rtl/array'/f for f in ['rv32_pdm_array_rx.v','rv32_pdm_clkgen.v','rv32_pdm_cic.v']]
inputs=rtl+[R/'tb/tb_pdm_shared_startup.v']
(O/'sources.json').write_text(json.dumps({str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in inputs},indent=2))
for name,mode,delay,startup,full in [('normal_min',0,40,8192,0),('normal_max',0,116,8192,0),('drive_release_boundary',0,116,8192,0),('swap',1,116,8192,0),('conflict',2,108,8192,0),('missing_a',3,108,8192,0),('missing_b',4,108,8192,0),('late_negative',5,140,8192,0),('default_50ms',0,116,2000000,1)]:
    exe=O/name
    cmd=['iverilog','-g2012','-s','tb_pdm_shared_startup','-o',str(exe)]
    if name=='late_negative':delay=(a.hold+1)*25+15
    for k,v in [('N_CH',a.channels),('HOLD',a.hold),('CONSUME',a.consume),('MODE',mode),('DELAY',delay),('STARTUP',startup),('FULL',full)]:cmd+=['-P',f'tb_pdm_shared_startup.{k}={v}']
    if name=='drive_release_boundary':cmd+=['-P','tb_pdm_shared_startup.DRIVE=80','-P','tb_pdm_shared_startup.RELEASE=5']
    run(name,[cmd+list(map(str,inputs)),['vvp',str(exe)]],'PDM_SHARED_PASS')
# Explicit raw diagnostic compatibility; production defaults remain startup-gated.
for top in ([] if a.shared_only else ['tb_pdm_array_rx','tb_pdm12_sync']):
    source=(R/'tb'/f'{top}.v').read_text(encoding='utf-8')
    if top=='tb_pdm12_sync':
        source=source.replace('rv32_pdm_array_rx #(', 'rv32_pdm_array_rx #(.MIC_STARTUP_CYCLES(0),.CIC_SETTLE_FRAMES(0),')
    path=O/f'{top}_diagnostic.v';path.write_text(source,encoding='utf-8')
    exe=O/top
    deps=[*rtl,R/'rtl/array/rv32_chan_align.v',path]
    if top=='tb_pdm12_sync':deps+=[O/'tb_pdm_array_rx_diagnostic.v']
    run(top,[['iverilog','-g2012','-s',top,'-o',str(exe),*map(str,deps)],['vvp',str(exe)]],'PASS')
print('PDM_SHARED_SUITE_PASS hardware=UNVERIFIED_HARDWARE')
