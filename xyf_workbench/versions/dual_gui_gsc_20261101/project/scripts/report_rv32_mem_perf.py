"""Summarize measured transactions, board agreement and application stage stalls."""
from pathlib import Path
import csv,json,re,statistics,hashlib,argparse,subprocess
R=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--directory',type=Path,default=R/'build/rv32_mem_perf')
parser.add_argument('--application-run',type=Path,default=R/'build/pdm12_runs/mem_full_chain')
args=parser.parse_args();O=args.directory.resolve()
rows=list(csv.DictReader((O/'mem_access_baseline.csv').open()))
trace=list(csv.DictReader((O/'transactions.csv').open()))
latency=[]
for r in rows:
 ts=[t for t in trace if t['id']==r['id']]
 if ts:
  response=[int(t['response_cycle'])-int(t['request_cycle']) for t in ts]
  latency.append({'id':r['id'],'name':r['name'],'n':r['n'],'transactions':len(ts),'response_latency_mean':statistics.mean(response),'response_latency_max':max(response),'request_period_mean':statistics.mean(int(b['request_cycle'])-int(a['request_cycle']) for a,b in zip(ts,ts[1:])) if len(ts)>1 else 'NA','retire_latency_max':max(int(t['retire_cycle'])-int(t['request_cycle']) for t in ts)})
with (O/'latency.csv').open('w',newline='') as f:
 w=csv.DictWriter(f,fieldnames=list(latency[0]));w.writeheader();w.writerows(latency)
manifest=json.loads((O/'manifest.json').read_text())
diff=subprocess.check_output(['git','-c','core.autocrlf=true','diff','--name-only','--','rtl'],cwd=R,text=True,stderr=subprocess.DEVNULL).splitlines()
result={'simulation_cases':len(rows),'transactions':len(trace),'latency_definition':'response_edge - first_request_edge; stage occupancy includes both edges',
        'working_tree_rtl_changed':bool(diff),'working_tree_rtl_diff_files':diff,
        'build_manifest':manifest,
        'source_hashes_match':all((R/name).exists() and hashlib.sha256((R/name).read_bytes()).hexdigest()==digest for name,digest in manifest['sources'].items()) if manifest.get('sources') else None}
m=re.search(r'CSR_RETIRE_AUDIT minstret=(\d+) csr_input_events=(\d+) exported_retire=(\d+) held_wb_events=(\d+)',(O/'simulation.log').read_text())
if m:
 result['csr_retirement_audit']=dict(zip(('minstret','csr_input_events','exported_retire','held_wb_events'),map(int,m.groups())))
 audit=result['csr_retirement_audit']
 result['csr_retirement_status']='PASS_ONE_SHOT_MATCH' if audit['minstret']==audit['exported_retire'] else 'FAIL_CSR_EXPORT_MISMATCH'
if (O/'board_raw_cycles.csv').exists():
 board={int(r['id']):int(r['rdcycle']) for r in csv.DictReader((O/'board_raw_cycles.csv').open())}
 mismatches=[{'id':r['id'],'sim':r['raw_rdcycle'],'board':board[int(r['id'])]} for r in rows if int(r['raw_rdcycle'])!=board[int(r['id'])]]
 result['board_cycle_mismatches']=mismatches;result['board_log_pass']='BOARD_MEM_PERF_PASS' in (O/'board.log').read_text(encoding='utf-16' if (O/'board.log').read_bytes()[:2]==b'\xff\xfe' else 'utf-8')
 assert not mismatches,mismatches
 print('BOARD_SIM_RDCYCLE_MATCH_PASS cases='+str(len(rows)))
log=args.application_run/'simulation.log'
if log.exists():
 text=log.read_text();stages=[]
 for m in re.finditer(r'MEM_STAGE frame=(\d+) phase=(\d+) total=(\d+) mmio_wait=(\d+) dtcm_wait=(\d+) scratch_wait=(\d+) lsu=(\d+) retired=(\d+)',text):
  s=dict(zip(('frame','phase','total','mmio_wait','dtcm_wait','scratch_wait','lsu','retired'),map(int,m.groups())))
  assert s['lsu']==s['mmio_wait']+s['dtcm_wait']+s['scratch_wait'];stages.append(s)
 if stages:
  with (O/'application_stall_breakdown.csv').open('w',newline='') as f:
   w=csv.DictWriter(f,fieldnames=list(stages[0]));w.writeheader();w.writerows(stages)
 result['full_chain_soctest_pass']='TEST_SRP_PASS' in text
 result['full_chain_frames_measured']=sorted(set(s['frame'] for s in stages))
 result['strict_overlap_status']='FAIL: snapshot input, not continuous overlapping windows'
result['application_log']=str(log)
(O/'report.json').write_text(json.dumps(result,indent=2))
print('RV32_MEM_REPORT_PASS response_tables=latency.csv trace=transactions.csv')
