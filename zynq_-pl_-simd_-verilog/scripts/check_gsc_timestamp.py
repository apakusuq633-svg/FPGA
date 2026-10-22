from pathlib import Path
import argparse,json,subprocess
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
for cmd,name in [(['iverilog','-g2012','-s','tb_gsc_timestamp','-o',str(O/'sim'),'rtl/array/rv32_gsc_tap.v','tb/tb_gsc_timestamp.v'],'compile'),(['vvp',str(O/'sim')],'run')]:
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/(name+'.log')).write_text(q.stdout+q.stderr);assert q.returncode==0,q.stdout+q.stderr
assert 'GSC_TIMESTAMP_PASS' in q.stdout,q.stdout
(O/'metrics.json').write_text(json.dumps({'status':'PASS','summary':q.stdout.strip()}));print(q.stdout.strip())
