"""Long SoC runs: real RV32 custom compute instructions, autonomous transfers, audio oracle."""
from pathlib import Path
import argparse,hashlib,json,subprocess,shutil
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--windows',type=int,default=4)
p.add_argument('--reuse-model',action='store_true');p.add_argument('--tag',default='verilator4')
p.add_argument('--mode',choices=('normal','halt','gap','slow'),default='normal')
p.add_argument('--output',type=Path,help='Isolated run, firmware and model directory')
a=p.parse_args()
if a.windows<1 or not a.tag.replace('_','').isalnum():p.error('Invalid windows/tag')
O=a.output.resolve() if a.output else R/'build/localizer12'/a.tag;O.mkdir(parents=True,exist_ok=True)
build_args=['--output',str(O)] if a.output else []
subprocess.run(['python3','scripts/build_live12.py','--transfer','--windows',str(a.windows),'--hot-o2',*build_args],cwd=R,check=True)
files=sorted((R/'rtl').rglob('*.v'))+[R/'tb/tb_localizer12_verilator.v',R/'scripts/localizer12_sim.cpp']
sources={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files+list((R/'rtl').rglob('*.vh'))+list((R/'rtl/rom').glob('*.hex'))}
M=O/'verilated' if a.output else R/'build/localizer12/verilated'
if a.output:
    wrapper=O/'tb_localizer12_verilator.v'
    wrapper.write_text((R/'tb/tb_localizer12_verilator.v').read_text().replace('build/localizer12/fw/',str(O/'fw')+'/'))
    files=[wrapper if f.name=='tb_localizer12_verilator.v' else f for f in files]
if not a.reuse_model:
    cmd=['verilator','-Wno-fatal','-DLOCALIZER_PCM_TEST','--cc','--exe','--build','-j','4','--top-module','tb_localizer12_verilator',
         '-Irtl','--Mdir',str(M),'--output-split','20000','--output-split-cfuncs','500',
         '-CFLAGS','-O2',*map(str,files)]
    with (O/'compile.log').open('w') as f:
        c=subprocess.run(cmd,cwd=R,stdout=f,stderr=subprocess.STDOUT)
    if c.returncode:raise RuntimeError((O/'compile.log').read_text()[-4000:])
    (M/'sources.json').write_text(json.dumps(sources,indent=2))
else:
    assert json.loads((M/'sources.json').read_text())==sources,'Model sources changed; rebuild required'
firmware_root=O if a.output else R/'build/localizer12'
manifest=json.loads((firmware_root/'build_manifest.json').read_text())
manifest.update(simulator=subprocess.check_output(['verilator','--version'],text=True).strip(),
                windows=a.windows,sources=sources,mode=a.mode,simulator_defines=['LOCALIZER_PCM_TEST'],
                scope='SOC_SYNTHETIC_PCM_TEST_GEOMETRY_ONLY')
(O/'build_manifest.json').write_text(json.dumps(manifest,indent=2))
if not a.output:shutil.copytree(R/'build/localizer12/fw',O/'fw',dirs_exist_ok=True)
with (O/'simulation.log').open('w') as f:
    c=subprocess.run([str(M/'Vtb_localizer12_verilator'),str(a.windows),a.mode],cwd=R,stdout=f,stderr=subprocess.STDOUT)
log=(O/'simulation.log').read_text();print(log[-3500:])
if a.mode in ('gap','slow'):
    assert c.returncode!=0 and 'LOCALIZER12_SOC_FAIL CAPTURE_LOSS' in log and 'LOCALIZER12_SOC_PASS' not in log
    print('LOCALIZER12_NEGATIVE_PASS mode='+a.mode)
    raise SystemExit(0)
assert c.returncode==0 and 'LOCALIZER12_SOC_PASS' in log
print('LOCALIZER12_CHECK_PASS windows='+str(a.windows))
