"""Cycle accounting for geometry-free runs, keeping audit work out of algorithm totals."""
from pathlib import Path
import argparse,json,re,statistics,hashlib
ap=argparse.ArgumentParser();ap.add_argument('directory',type=Path);ap.add_argument('--numeric',action='store_true');args=ap.parse_args()
folder=args.directory;text=(folder/'simulation.log').read_text(encoding='utf-8')
assert 'LIVE12_SOC_PASS' in text and 'Fatal:' not in text and 'FATAL:' not in text
def rows(tag):
    return [{k:int(v) for k,v in re.findall(r'(\w+)=(-?\d+)',line)} for line in text.splitlines() if line.startswith(tag+' ')]
timings=rows('FRAME_TIMING');protocol=rows('FRAME_PROTOCOL');gcc=rows('NUMERIC66_FRAME');stages=rows('GCC_STAGES')
srp=rows('TEST_SRP_FRAME');mem_stages=rows('MEM_STAGE')
if srp:
    assert args.numeric and 'TEST_SRP_PASS' in text and len(srp)==len(timings)
    assert all(s['pairs']==66 and s['grid']==1024 for s in srp)
    scores=[int(s,16) for s in (folder/'test_srp/scores.hex').read_text().split()]
    for i,s in enumerate(srp):
        p=[(v+2147483648)%4294967296-2147483648 for v in scores[i*1024:(i+1)*1024]]
        assert s['best_grid']==max(range(1024),key=lambda g:p[g]) and s['best_score']==max(p)
assert timings and len(protocol)==len(timings)
if args.numeric:
    assert 'NUMERIC66_PASS' in text and len(gcc)==len(timings) and len(stages)==len(timings)
    assert sum(row['pairs'] for row in gcc)==66*len(timings)
for i,row in enumerate(timings):
    row['five_sum']=sum(row[k] for k in ('capture','prepare','push','run','pop'))
    assert row['five_sum']<=row['compute']<=row['total'] and row['audio_max']<1024
    p=protocol[i];assert p['ready']==3 and p['first1']-p['first0']==512 and p['seq1']-p['seq0']==1
    assert p['ack_errors']==p['capture_drops']==p['direction_updates']==0
    if args.numeric:
        row['gcc_ring']=gcc[i]['ring_cycles'];row['algorithm_stage_sum']=row['five_sum']+row['gcc_ring']
        if srp:
            row['fft_gcc_stage_sum']=row['algorithm_stage_sum']
            row['srp_wait']=srp[i]['wait'];row['srp_hardware']=srp[i]['hardware'];row['srp_readback']=srp[i]['readback']
            row['srp_residency_with_marker_bookkeeping']=next(s['total'] for s in mem_stages if s['frame']==row['frame'] and s['phase']==9)
            row['algorithm_stage_sum']+=row['srp_residency_with_marker_bookkeeping']
        row['audit_full']=gcc[i]['full_check_cycles'];row['audit_phi_copy']=stages[i]['audit_copy']
        row['control_and_instrumentation']=row['compute']-row['algorithm_stage_sum']-row['audit_full']-row['audit_phi_copy']
        assert row['control_and_instrumentation']>=0
    row['waiting_control']=row['total']-row['compute']
keys=[k for k in timings[0] if k not in ('frame','first','interval')]
summary={'scope':'synthetic PCM, real RV32/RTL; TEST_GEOMETRY_ONLY, SRP included with marker bookkeeping; no production steering' if srp else 'synthetic PCM, real RV32/RTL; no geometry, no SRP or steering',
 'legacy_scope_note':'Raw CYCLE_SCOPE srp=0 label is stale for test-srp runs; TEST_SRP_FRAME/PASS and score oracle define actual executed scope' if srp else None,
 'frames':timings,'protocol':protocol,'gcc_stages':stages,'capture_detail':rows('DETAIL_CAPTURE'),
 'prepare_detail':rows('DETAIL_PREPARE'),'capture_residency':rows('CAPTURE_RESIDENCY'),
 'statistics':{k:{'mean_cycles':statistics.mean(r[k] for r in timings),'max_cycles':max(r[k] for r in timings),
                  'mean_ms_at_40MHz':statistics.mean(r[k] for r in timings)/40000} for k in keys},
 'build':json.loads((folder/'build_manifest.json').read_text()),
 'log_sha256':hashlib.sha256((folder/'simulation.log').read_bytes()).hexdigest(),
 'complete_pairs':66*len(timings) if args.numeric else 0}
(folder/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('PDM12_RUN_SUMMARY_PASS frames='+str(len(timings))+' pairs='+str(summary['complete_pairs']))
print(json.dumps(summary['statistics'],indent=2))
