from pathlib import Path
import argparse,json,re,subprocess
import numpy as np
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
results=[]
for name in ['integrated_direction','gsc_tap']:
    bench=(R/'tb'/f'tb_{name}.v').read_text().replace('STEER_LUT',str(R/'build/zynq12_integrated_plan/m1_release/steer_lut.hex'))
    (O/f'{name}.v').write_text(bench)
    cmd=['iverilog','-g2012','-Irtl','-s','tb_'+name,'-o',str(O/name),*[str(x) for x in (R/'rtl').rglob('*.v')],str(O/f'{name}.v')]
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/f'{name}_compile.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
    q=subprocess.run(['vvp',str(O/name)],cwd=R,capture_output=True,text=True);(O/f'{name}.log').write_text(q.stdout+q.stderr)
    assert q.returncode==0,q.stdout[-2000:]+q.stderr
    assert name.upper()+'_PASS' in q.stdout
    result={'test':name,'status':'PASS'}
    if name=='integrated_direction':
        rows=[dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',line)) for line in q.stdout.splitlines() if line.startswith('DIRECTION_AUDIO')]
        audio=np.array([r['pcm'] for r in rows]);peak=int(abs(np.diff(audio[64:])).max())
        energies=[np.mean(audio[i:i+32].astype(float)**2) for i in range(64,len(audio)-32,32)]
        ratio=max(energies)/min(energies)
        result.update(samples=len(rows),max_adjacent_step_lsb=peak,short_energy_ratio=float(ratio))
        assert peak<=4096 and ratio<=2.0,result
        baseline_cmd=cmd.copy();baseline_cmd[1:1]=['-P','tb_integrated_direction.SMOOTH=0']
        baseline_cmd[baseline_cmd.index('-o')+1]=str(O/'direction_step')
        b=subprocess.run(baseline_cmd,cwd=R,capture_output=True,text=True);(O/'direction_step_compile.log').write_text(b.stdout+b.stderr);assert b.returncode==0,b.stderr
        b=subprocess.run(['vvp',str(O/'direction_step')],cwd=R,capture_output=True,text=True);(O/'direction_step.log').write_text(b.stdout+b.stderr);assert b.returncode==0,b.stdout[-2000:]
        br=[dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',line)) for line in b.stdout.splitlines() if line.startswith('DIRECTION_AUDIO')]
        ba=np.array([r['pcm'] for r in br]);be=[np.mean(ba[i:i+32].astype(float)**2) for i in range(64,len(ba)-32,32)]
        result.update(baseline_unsmoothed_max_step_lsb=int(abs(np.diff(ba[64:])).max()),baseline_unsmoothed_energy_ratio=float(max(be)/min(be)))
    results.append(result);print(result,flush=True)
(O/'metrics.json').write_text(json.dumps(results,indent=2))
