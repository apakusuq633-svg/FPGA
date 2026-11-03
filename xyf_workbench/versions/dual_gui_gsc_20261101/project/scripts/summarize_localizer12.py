"""Attach matching product timing evidence to a full RV32/transfer/audio SoC run."""
from pathlib import Path
import argparse,hashlib,json,re,statistics
from check_overlap50_strict import evaluate
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('run',type=Path)
p.add_argument('--implementation',type=Path);a=p.parse_args()
O=a.run;log=(O/'simulation.log').read_text()
assert 'LOCALIZER12_SOC_PASS' in log and 'OVERLAP_LOCALIZER_NUMERIC_PASS' in log
assert not re.search(r'Fatal:|FATAL:|LOCALIZER12_SOC_FAIL',log)
def rows(tag):
    return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(\d+)',line)) for line in log.splitlines() if line.startswith(tag+' ')]
audio,=rows('LOCALIZER12_SOC_PASS');coverage,=rows('OVERLAP_COVERAGE');windows=rows('OVERLAP_WINDOW')
assert audio['windows']==len(windows)
assert audio['audio_in']==audio['audio_out']==coverage['samples']
for key,n in dict(custom_fwd=12,custom_inv=66,custom_cross=66,custom_phat=66,custom_srp=1).items():
    assert audio[key]==n*len(windows),(key,audio)
manifest=json.loads((O/'build_manifest.json').read_text(encoding='utf-8-sig'))
timing={}
if a.implementation:
    I=a.implementation
    physical=json.loads((I/'source_manifest.json').read_text(encoding='utf-8-sig'))
    current={k:hashlib.sha256((R/k).read_bytes()).hexdigest() for k in physical}
    matches=physical==current and all(manifest['sources'].get(k)==v for k,v in physical.items())
    report=(I/'timing_zynq.rpt').read_text()
    flow='\n'.join(f.read_text(errors='replace') for f in I.parent.glob('implementation*.log'))
    match=re.search(r'WNS\(ns\)[^\n]*\n\s*[- ]+\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)',report)
    assert match,'Missing routed timing summary'
    clock=bool(re.search(r'clk_fpga_0\s+\{[^}]+\}\s+25\.000',report))
    timing=dict(source_hash_match=matches,clock_hz=40000000 if clock else 0,
                report=str((I/'timing_zynq.rpt').resolve()),wns_ns=float(match[1]),whs_ns=float(match[5]),
                flow_pass=bool(re.search(r'^FLOW_PASS',flow,re.M)),
                report_sha256=hashlib.sha256((I/'timing_zynq.rpt').read_bytes()).hexdigest())
    if not timing['flow_pass']:timing['source_hash_match']=False
events=[dict(type='run',scope='SOC',geometry_mode='TEST_GEOMETRY_ONLY',window_length=1024,hop=512,
             channels=12,clock_hz=40000000,sample_period_cycles=1024,audio_verified=True,
             physical_geometry_confirmed=False,timing=timing,manifest=manifest)]
prior=dict(fwd=0,inv=0,srp=0)
for w in windows:
    events.append(dict(type='window',window_id=w['id'],first_sample=w['first'],ready_cycle=w['ready'],
                       result_cycle=w['result'],geometry_mode='TEST_GEOMETRY_ONLY',fft_fwd=w['fwd']-prior['fwd'],
                       gcc_pairs=w['inv']-prior['inv'],ifft=w['inv']-prior['inv'],srp=w['srp']-prior['srp'],
                       srp_grid=1024,window_golden_match=True,pair_computation_verified=True,srp_golden_match=True))
    prior=w
events.append(dict(type='coverage',first_sample=coverage['first'],sample_count=coverage['samples'],
                   raw_block_loss=coverage['raw_drop'],window_skip=coverage['window_drop'],audio_drops=audio['audio_drops']))
(O/'events.jsonl').write_text(''.join(json.dumps(e)+'\n' for e in events))
result=evaluate(events)
result.update(audio=audio,compute_cycles=[w.get('compute') for w in windows],
              physical_geometry_accuracy='NOT_VALIDATED',
              log_sha256=hashlib.sha256((O/'simulation.log').read_bytes()).hexdigest())
stages=rows('TRANSFER_STAGES')
if stages:
    assert len(stages)==len(windows)
    result['stage_statistics']={key:dict(mean_cycles=statistics.mean(s[key] for s in stages),
                                       max_cycles=max(s[key] for s in stages)) for key in stages[0] if key!='id'}
(O/'strict_summary.json').write_text(json.dumps(result,indent=2)+'\n')
print('LOCALIZER12_STRICT_'+result['status']+' reasons='+','.join(result['failures']))
print('windows='+str(len(windows))+' max_gap='+str(result['max_result_gap_cycles'])+
      ' max_latency='+str(result['max_window_latency_cycles'])+' audio='+str(audio['audio_out']))
raise SystemExit(0 if result['status']=='PASS' else 1)
