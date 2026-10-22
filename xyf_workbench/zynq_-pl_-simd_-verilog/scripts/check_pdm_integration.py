"""Current SoC control and capture regression; isolated generated artifacts."""
from pathlib import Path
import subprocess,re,json,argparse
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--top',action='append');a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
rows=[]
for top in a.top or ['tb_pdm_capture','tb_rv32_soc','tb_rv32_ps']:
    text=(R/'tb'/f'{top}.v').read_text(encoding='utf-8')
    for word in ['expect','before','ref']:text=re.sub(r'\b'+word+r'\b','test_'+word,text)
    text=re.sub(r'\$dumpfile\("[^"]+"\)',lambda _: f'$dumpfile("{(O/top).as_posix()}.vcd")',text)
    path=O/(top+'.v');path.write_text(text,encoding='utf-8')
    dependencies=[str(R/'tb/tb_pdm_shared_startup.v')] if top=='tb_pdm_ps_firstframe' else []
    commands=[['iverilog','-g2005' if top=='tb_rv32_ps' else '-g2012','-Irtl','-s',top,'-o',str(O/top),*map(str,sorted((R/'rtl').rglob('*.v'))),*dependencies,str(path)],['vvp',str(O/top)]]
    for i,cmd in enumerate(commands):
        q=subprocess.run(cmd,cwd=R,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=300)
        (O/f'{top}_{i}.log').write_text(q.stdout+q.stderr,encoding='utf-8')
        assert q.returncode==0,(top,q.stdout[-2000:],q.stderr[-2000:])
    assert 'PASS' in q.stdout and 'FAIL' not in q.stdout and 'FATAL' not in q.stdout,q.stdout
    rows.append({'test':top,'status':'PASS','commands':commands,'summary':q.stdout.strip()[-500:]})
    (O/'results.json').write_text(json.dumps(rows,indent=2));print(top,rows[-1]['summary'],flush=True)
print('PDM_INTEGRATION_PASS')
