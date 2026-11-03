"""Stop only this task's named validation processes after an RTL revision."""
from pathlib import Path
import os,signal,json,argparse
p=argparse.ArgumentParser();p.add_argument('--tag',action='append',required=True);a=p.parse_args()
R=Path(__file__).resolve().parents[1];tags=a.tag;rows=[]
for p in Path('/proc').iterdir():
    if not p.name.isdigit() or int(p.name)==os.getpid():continue
    try:cmd=(p/'cmdline').read_bytes().decode().strip('\0').split('\0')
    except (OSError,UnicodeError):continue
    if not cmd:continue
    tag=next((t for t in tags if (len(cmd)>3 and cmd[1]=='scripts/run_integrated_validation.py' and t in cmd) or
              (('Vtb_localizer12_safety' in Path(cmd[0]).name or len(cmd)>1 and cmd[1] in ['scripts/check_localizer12_safety.py','scripts/run_localizer_long.py']) and any('/'+t+'/' in s for s in cmd))),None)
    if tag:
        os.kill(int(p.name),signal.SIGTERM);rows.append({'pid':int(p.name),'tag':tag,'command':cmd,'status':'SUPERSEDED_RTL_REVISION'})
(R/('build/zynq12_integrated_plan/superseded_'+('_'.join(tags))+'.json')).write_text(json.dumps(rows,indent=2));print(rows)
