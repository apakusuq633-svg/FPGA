"""Reproduce stage-1 simulation; separate from real-microphone board acceptance."""
from pathlib import Path
import argparse,subprocess
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--iverilog',default='D:/iverilog/bin/iverilog.exe')
parser.add_argument('--vvp',default='D:/iverilog/bin/vvp.exe')
args=parser.parse_args()
rtl=[str(p.relative_to(ROOT)) for p in (ROOT/'rtl').rglob('*.v')]
for top,defines in [('tb_das_stream',['-Ptb_das_stream.ACTIVE_CHANNELS=16']),
                    ('tb_pdm_array_rx',[]),('tb_pdm_capture',[]),('tb_live16_fixed',[])]:
    binary=ROOT/'build'/('check16_'+top+'.vvp')
    subprocess.run([args.iverilog,'-g2012','-Irtl','-s',top,*defines,'-o',str(binary),*rtl,'tb/'+top+'.v'],cwd=ROOT,check=True)
    result=subprocess.run([args.vvp,str(binary)],cwd=ROOT,check=True,capture_output=True,text=True,encoding='utf-8',errors='replace')
    (ROOT/'build/das16'/(top+'.log')).write_text(result.stdout,encoding='utf-8')
    if 'PASS' not in result.stdout:raise RuntimeError('No PASS marker: '+top)
    print(result.stdout.strip())
print('LIVE16_STAGE1_SIM_PASS; real array has not been tested')
