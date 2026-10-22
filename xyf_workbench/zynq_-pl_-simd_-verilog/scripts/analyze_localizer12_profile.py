"""Measured candidate comparison; no claim of sample-rate or power improvement."""
from pathlib import Path
import csv,difflib,hashlib,json
R=Path(__file__).resolve().parents[1];O=R/'build/m10_20261016'
def read(f):return json.loads(f.read_text(encoding='utf-8-sig'))
def sha(f):return hashlib.sha256(f.read_bytes()).hexdigest()
def rows(f):return list(csv.DictReader(f.open()))
names=['profile_before','profile_id_first','profile_no_jump_table','profile_combined','profile_final',
       'profile_before_v2','profile_final_v2']
result=[]
groups={'raw_prepare':[1,2,3],'forward_fft_io_compute':[4,5,6,7,8],
 'cross_power_io_compute':[9,10,11,12],'phat_io_compute':[13,14,15],
 'inverse_fft_io_compute':[16,17,18,19],'r_ring_extract':[20,21,22,23],
 'srp_and_score_read':[24,25,26,27],'publish_padding':[28]}
for name in names:
 d=O/name;m=read(d/'profile_metrics.json');assert m['status']=='PASS_PROFILE_FULL_ARITHMETIC'
 mmio=rows(d/'profile_mmio.csv');states=rows(d/'profile_states.csv')
 transfer={int(x['state']):int(x['cycles']) for x in states if x['unit']=='transfer'}
 hot=sorted(rows(d/'profile_pc.csv'),key=lambda r:int(r['active_retired']),reverse=True)[:12]
 result.append(dict(name=name,max_compute=m['safety']['max_compute'],publish_latency=m['safety']['max_latency'],
  total_dispatch_cycles=sum(r['total_dispatch_cycles'] for r in m['dispatch']),dispatch=m['dispatch'],
  counters=m['counters'],mmio_acknowledgements=sum(int(r['acknowledgements']) for r in mmio),
  active_mmio_acknowledgements=sum(int(r['active_acknowledgements']) for r in mmio),
  stage_cycles_per_window={g:sum(transfer[i] for i in indices)/m['windows'] for g,indices in groups.items()},
  hot_pc=hot,itcm_bytes=(d/'fw/itcm.bin').stat().st_size,dtcm_data_bytes=(d/'fw/dtcm.bin').stat().st_size,
  metrics_sha256=sha(d/'profile_metrics.json')))
before=result[-2];after=result[-1];assert after['max_compute']<before['max_compute']
assert after['max_compute']==result[3]['max_compute']
# Correcting acceptance qualification must not change healthy-run observations.
for old,new in [(result[0],before),(result[4],after)]:
 assert old['counters']==new['counters'] and old['dispatch']==new['dispatch']
 assert old['stage_cycles_per_window']==new['stage_cycles_per_window']
assert after['counters']['ram_requests']==after['counters']['ram_wait']==40
assert after['counters']['simd_mac_slots']==before['counters']['simd_mac_slots']
for memory in ('itcm','dtcm'):
 assert (O/'profile_final_v2/fw'/f'{memory}.hex').read_bytes()==(O/'profile_combined/fw'/f'{memory}.hex').read_bytes()
 assert (O/'profile_before_v2/fw'/f'{memory}.hex').read_bytes()==(R/'build/zynq12_integrated_plan/m9_merge_regression_20261016/safety/fw'/f'{memory}.hex').read_bytes()
source_before=O/'before/fw_localizer12.c';source_after=R/'sw/fw/fw_localizer12.c'
(O/'firmware.diff').write_text(''.join(difflib.unified_diff(source_before.read_text().splitlines(True),source_after.read_text().splitlines(True),
 fromfile='before/fw_localizer12.c',tofile='sw/fw/fw_localizer12.c')))
report=dict(status='PASS_MEASURED_AB',scope='8-window complete RTL/C oracle for each candidate; full regressions separately required',
 candidates=result,selected='combined',changed_production_source='sw/fw/fw_localizer12.c',
 before_sha256=sha(source_before),after_sha256=sha(source_after),
 compute_saved_cycles=before['max_compute']-after['max_compute'],
 compute_improvement_percent=100*(before['max_compute']-after['max_compute'])/before['max_compute'],
 dtcm_requests_saved=before['counters']['ram_requests']-after['counters']['ram_requests'],
 retired_reduction_percent=100*(before['counters']['retired']-after['counters']['retired'])/before['counters']['retired'],
 mmio_change_percent=100*(after['mmio_acknowledgements']-before['mmio_acknowledgements'])/before['mmio_acknowledgements'],
 code_size_change_bytes=after['itcm_bytes']-before['itcm_bytes'],
 published_latency_improved=False,power_reduction_claimed=False,core_rtl_modified=False,algorithm_approximation=False,
 normal_checker_equivalence_verified=True,
 note='Faster polling increases total MMIO acknowledgements and fetch/memory stall counters; instruction retirement falls. No power claim.')
with (O/'performance.json').open('x')as f:json.dump(report,f,indent=2)
print('M10_MEASURED_AB_PASS',json.dumps({k:v for k,v in report.items() if k not in ('candidates','note')}))
