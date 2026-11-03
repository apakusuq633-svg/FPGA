"""Actual board cycles, synthetic SRP LUT, physical PDM input of unknown geometry."""
from pathlib import Path
import re,json,csv,statistics
R=Path(__file__).resolve().parents[1];O=R/'build/rv32_mem_perf/board_profile'
p=O/'telemetry.txt';data=p.read_text(encoding='utf-16' if p.read_bytes()[:2]==b'\xff\xfe' else 'utf-8')
mem={int(a,16):int(v,16) for a,v in re.findall(r'([0-9A-Fa-f]{8}):\s+([0-9A-Fa-f]{8})',data)}
w=lambda n:mem[0xffff0000+4*n]
assert w(0)==0x42505041 and w(1)==4 and w(2)==w(4)==w(5)==w(6)==0
rows=[]
for f in range(4):
 b=32+f*256;x=lambda n:w(b+n)
 r={'frame':f+1,'capture':sum(x(134+ch*5) for ch in range(12)),
 'prepare':sum(x(135+ch*5) for ch in range(12)),
 'fft_push':sum(x(136+ch*5) for ch in range(12)),
 'fft_run':sum(x(137+ch*5) for ch in range(12)),
 'fft_pop':sum(x(138+ch*5) for ch in range(12)),
 'compute_with_numeric_audit':x(4),'snapshot_total':x(5),'first':x(93),
 'srp_wait':x(203),'srp_hardware':x(204),'srp_readback':x(205),
 'audio_drop':x(240),'audio_max':x(241),'trap':x(242),
 'gcc66':x(245),'audit_full':x(246),'audit_phi_copy':x(247),'srp_ring_load':x(248),
 'gcc_pairs_observed':x(249),'pair_observation_errors':x(250)}
 assert x(196)==66 and x(197)==f+1 and x(231)==0x54455354 and x(3)==0
 assert r['audio_drop']==r['trap']==0
 if r['gcc_pairs_observed']==66 and r['pair_observation_errors']==0:
  r['algorithm_stage_sum']=sum(r[k] for k in ('capture','prepare','fft_push','fft_run','fft_pop','gcc66','srp_ring_load','srp_wait','srp_readback'))
  r['over_budget']=r['algorithm_stage_sum']-524288
 else:r['algorithm_stage_sum']='UNATTRIBUTED_PAIR_TIMES';r['over_budget']='UNKNOWN'
 rows.append(r)
with (O/'cycles.csv').open('w',newline='') as fp:
 writer=csv.DictWriter(fp,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
summary={'role':'TEST_GEOMETRY_ONLY','input':'physical PDM, unknown microphone geometry and wiring validity','overlap':False,'frames':rows,'audio_drained':w(3),'audio_drop':w(5),'raw_snapshot_drop':w(7),'strict_realtime_status':'FAIL_snapshot_windows','physical_localization_accuracy':'NOT_VALIDATED'}
(O/'summary.json').write_text(json.dumps(summary,indent=2))
print('BOARD_FULL12_66_SRP_PROFILE_PASS frames=4 audio_drop=0 TEST_GEOMETRY_ONLY')
print(json.dumps(rows,indent=2))
