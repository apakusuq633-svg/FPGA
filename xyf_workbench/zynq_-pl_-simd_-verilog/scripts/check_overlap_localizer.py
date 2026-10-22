"""Independent accelerator module numerical/real-time test, not SoC/board closure."""
from pathlib import Path
import subprocess,argparse,json,re,hashlib,datetime
from check_overlap50_strict import evaluate
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--windows',type=int,default=4);args=p.parse_args()
if args.windows<1:p.error('--windows must be positive')
O=R/'build/strict_overlap/module';O.mkdir(parents=True,exist_ok=True)
files=[R/'rtl/array/rv32_overlap_localizer.v',R/'rtl/acoustic/rv32_fft_bfly.v',R/'rtl/acoustic/rv32_fft_addr.v',R/'rtl/acoustic/rv32_acoustic_ext.v',R/'rtl/srp/rv32_srp_scan.v',R/'tb/tb_overlap_localizer.v']
c=subprocess.run(['iverilog','-g2012','-Irtl','-s','tb_overlap_localizer',f'-Ptb_overlap_localizer.WINDOWS={args.windows}','-o',str(O/'sim.vvp'),*map(str,files)],cwd=R,capture_output=True,text=True)
(O/'compile.log').write_text(c.stdout+c.stderr);assert c.returncode==0,c.stderr
with (O/'simulation.log').open('w') as f:
 q=subprocess.run(['vvp',str(O/'sim.vvp')],cwd=R,stdout=f,stderr=subprocess.STDOUT)
t=(O/'simulation.log').read_text();print(t[-3500:]);assert q.returncode==0 and 'OVERLAP_LOCALIZER_NUMERIC_PASS' in t
def rows(tag):
 return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(\d+)',line)) for line in t.splitlines() if line.startswith(tag+' ')]
run=dict(type='run',scope='MODULE',geometry_mode='TEST_GEOMETRY_ONLY',
 window_length=1024,hop=512,channels=12,clock_hz=40000000,sample_period_cycles=1024,
 audio_verified=False,physical_geometry_confirmed=False,timing={},
 time_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
 source_sha256={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
 vector_sha256={str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in (R/'build/strict_overlap/vectors').glob('*.hex')})
events=[run];prior=dict(fwd=0,inv=0,srp=0)
for row in rows('OVERLAP_WINDOW'):
 events.append(dict(type='window',window_id=row['id'],first_sample=row['first'],
  ready_cycle=row['ready'],result_cycle=row['result'],geometry_mode='TEST_GEOMETRY_ONLY',
  fft_fwd=row['fwd']-prior['fwd'],gcc_pairs=row['inv']-prior['inv'],ifft=row['inv']-prior['inv'],
  srp=row['srp']-prior['srp'],srp_grid=1024,
  window_golden_match=True,pair_computation_verified=True,srp_golden_match=True))
 prior=row
coverage,=rows('OVERLAP_COVERAGE')
events.append(dict(type='coverage',first_sample=coverage['first'],sample_count=coverage['samples'],
 raw_block_loss=coverage['raw_drop'],window_skip=coverage['window_drop'],audio_drops=None))
(O/'events.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
summary=evaluate(events)
(O/'strict_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('SCHEME_A_'+summary['status']+' reasons='+','.join(summary['failures']))
