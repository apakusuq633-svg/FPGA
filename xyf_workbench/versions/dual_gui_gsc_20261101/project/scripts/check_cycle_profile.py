"""Run instrumented RV32 firmware against the real 12-channel SoC RTL."""
from pathlib import Path
import subprocess, re, json, argparse, shutil, datetime
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das12_profile'
parser=argparse.ArgumentParser()
parser.add_argument('--analyze-only',action='store_true',help='Summarize an existing simulation log without rerunning')
parser.add_argument('--log',type=Path,help='Existing log for --analyze-only, including XSim logs')
parser.add_argument('--simulator',choices=('xsim','iverilog'),default='xsim' if shutil.which('powershell.exe') else 'iverilog')
args=parser.parse_args()
if args.log and not args.analyze_only: parser.error('--log requires --analyze-only')
if not args.analyze_only:
    subprocess.run(['python3','scripts/build_live12.py','--profile'],cwd=ROOT,check=True)
    if args.simulator=='xsim':
        script=subprocess.check_output(['wslpath','-w',str(ROOT/'scripts/check_live16_xsim.ps1')],text=True).strip()
        subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',script,'-Twelve','-CycleProfile'],cwd=ROOT,check=True)
    else:
        sources=[str(p.relative_to(ROOT)) for p in (ROOT/'rtl').rglob('*.v')]
        with (OUT/'compile.log').open('w') as log:
            command=['iverilog','-g2012','-Irtl','-DLIVE12_PROFILE','-s','tb_live12_soc',
                     '-o',str(OUT/'profile.vvp'),*sources,'tb/tb_live12_soc.v']
            subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
        with (OUT/'profile.log').open('w') as log:
            subprocess.run(['vvp',str(OUT/'profile.vvp')],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
log_path=args.log or OUT/('xsim/simulation.log' if args.simulator=='xsim' else 'profile.log')
text=log_path.read_text()
manifest_path=log_path.parent/'build_manifest.json'
if not manifest_path.exists():
    if args.log: raise RuntimeError('Explicit log requires its adjacent build_manifest.json; refuse a different current build')
    manifest_path=OUT/'build_manifest.json'
assert 'LIVE12_SOC_PASS' in text
rows=[dict(zip(('channel','capture','prepare','push','run','pop'),map(int,m)))
      for m in re.findall(r'CYCLE_PROFILE ch=(\d+) capture=(\d+) prepare=(\d+) push=(\d+) run=(\d+) pop=(\d+)',text)]
assert len(rows)==12
assert all(row['capture']==0 if row['channel']%2 else row['capture']>0 for row in rows)
totals={key:sum(row[key] for row in rows) for key in ('capture','prepare','push','run','pop')}
scope=re.search(r'CYCLE_SCOPE frame=(\d+) compute=(\d+) total=(\d+) fft_channels=(\d+) gcc_pairs=(\d+) srp=(\d+) steering=(\d+) first=(\d+)',text)
assert scope,'Missing explicit cycle scope'
scope=dict(zip(('frame','compute','total','fft_channels','gcc_pairs','srp','steering','first'),map(int,scope.groups())))
assert sum(totals.values())<=scope['compute']<=scope['total']
(OUT/'summary.json').write_text(json.dumps({'scope':'RTL simulation, latest completed frame; not board timing',
    'measurement_scope':scope,'stage_sum':sum(totals.values()),'compute_other':scope['compute']-sum(totals.values()),
    'wait_and_control':scope['total']-scope['compute'],
    'build_manifest':json.loads(manifest_path.read_text()),
    'time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'log':str(log_path),
    'capture_accounting':'shared pair cost on even channels only; odd capture is zero',
    'clock_hz_for_conversion':40000000,'channels':rows,'total_cycles':totals,
    'total_ms':{k:v/40000 for k,v in totals.items()}},indent=2)+'\n')
print('\n'.join(line for line in text.splitlines() if line.startswith(('CYCLE_','LIVE12_'))))
print('CYCLE_PROFILE_PASS totals='+str(totals))
