"""Release only the measured M8 software prototype, preserving board deferrals."""
from pathlib import Path
import hashlib,json,struct
import numpy as np
R=Path(__file__).resolve().parents[1];O=R/'build/m8_20261016'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):
    h=hashlib.sha256()
    with p.open('rb')as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
assert not (O/'acceptance.json').exists(),'M8 already packaged'
for row in read(R/'build/m7_20261016/release_manifest.json')['files']:
    assert sha(R/row['path'])==row['sha256'],('M7 drift',row['path'])
pl=read(R/'build/m6_20261016/implementation_sources.json')
now={str(p.relative_to(R)):sha(p) for folder in ('rtl','constrs','configs') for p in (R/folder).rglob('*') if p.is_file()}
assert now==pl,'Changed PL inputs require a new implementation'
for p,h in read(O/'c_verified/sources.json').items():assert sha(R/p)==h,('C source drift',p)
before=read(O/'golden/acceptance.json');after=read(O/'golden_conditioned/acceptance.json')
for k in ('seed','n','channels','target_grids','band_hz','mu_q15','epsilon','snr_improvement_db_min','target_gain_db_min','target_relative_error_max','evaluation_tail_samples','fir_sha256'):
    assert before[k]==after[k],('Acceptance/dataset changed',k)
for case in range(3):
    a=np.load(O/f'golden/case{case}.npz',allow_pickle=False);b=np.load(O/f'golden_conditioned/case{case}.npz',allow_pickle=False)
    assert all(np.array_equal(a[k],b[k]) for k in ('raw','target_raw','noise_raw','delays_q16','fir','das','beam'))
golden=read(O/'golden_conditioned/metrics.json');c=read(O/'c_verified/metrics.json')
assert golden['status']=='PASS' and c['status']=='PASS_SOFTWARE' and len(c['cases'])==3
for row in c['cases']:
    assert row['bit_exact'] and row['samples']==32768
    assert row['acoustics']['snr_improvement_db']>=3 and row['acoustics']['target_gain_db']>=-1
    assert row['acoustics']['target_relative_rms_error']<=.2
assert len(c['faults'])==20 and all(f['status']=='PASS' for f in c['faults']),len(c['faults'])
rtl=read(O/'rtl_packets/metrics.json');assert rtl['status']=='PASS' and rtl['packets']==256
normal=read(O/'safety/baseline8_summary.json')['results'][0]
assert normal['status']=='PASS' and normal['windows']==8 and normal['raw_drop']==normal['window_drop']==normal['audio_drop']==0
interfaces=read(O/'interfaces/metrics.json');assert len(interfaces)==2 and all(r['status']=='PASS' for r in interfaces)
elf=R/'build/m8_20261016_selftest/gsc12_selftest.elf';data=elf.read_bytes()
assert data[:4]==b'\x7fELF' and struct.unpack_from('<H',data,18)[0]==40 and struct.unpack_from('<I',data,24)[0]==0x100000
symbol_bytes=(elf.parent/'symbols.txt').read_bytes()
symbols=symbol_bytes.decode('utf-16' if symbol_bytes.startswith(b'\xff\xfe') else 'utf-8-sig')
assert 'gsc12_test_' not in symbols and 'gsc12_selftest_status' in symbols
old=read(R/'build/m6_20261016/acceptance.json')
confirmed=[]
for case in golden['cases']:
    blocks=case['block_snr_improvements_db'];i=next(i for i in range(len(blocks)-2) if min(blocks[i:i+3])>=3)
    confirmed.append((i+4)*1024/39062.5)
report={'stage':'M8','status':'PASS_PROTOTYPE_SOFTWARE_RTL','hardware':'DEFERRED_HARDWARE',
 'gsc_placement':'PS portable C prototype; not live deployed','golden':golden,'c':c,'rtl':rtl,'normal8':normal,
 'convergence_confirmed_seconds':confirmed,'vivado':'REUSED_IDENTICAL_PL_INPUTS','timing':old['timing'],'resources':old['resources'],
 'baseline_manifest_sha256':sha(R/'build/m7_20261016/release_manifest.json'),
 'deferred':['Cortex-A9 actual runtime throughput','live DMA input','production coordinates/calibration','real audio/noise quality'],
 'arm_selftest':{'path':str(elf.relative_to(R)),'built':True,'executed':False,'sha256':sha(elf)}}
(O/'acceptance.json').write_text(json.dumps(report,indent=2))
paths={p for base in (O,elf.parent) for p in base.rglob('*') if p.is_file() and p.suffix.lower() in ('.json','.log','.md','.txt','.npz','.bin','.hex','.o','.so','.elf','.c','.h','.ps1','.su','.ld','.s')}
paths.update(R/p for p in ['sw/gsc12.c','sw/gsc12.h','scripts/gsc12_bench.c','scripts/gsc12_golden.py','scripts/evaluate_gsc12.py','scripts/analyze_gsc12_model.py','scripts/check_gsc12.py','scripts/check_gsc12_rtl.py','scripts/build_gsc12_selftest.ps1','scripts/finalize_m8.py','tb/tb_gsc12_frontend.v','docs/M8_GSC原型接口与验收_2026-10-16.md'])
(O/'release_manifest.json').write_text(json.dumps({'status':report['status'],'hardware':'DEFERRED_HARDWARE',
 'files':[{'path':str(p.relative_to(R)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(paths)]},indent=2))
print('M8_RELEASE_PASS',json.dumps({'snr_improvements_db':[r['snr_improvement_db'] for r in golden['cases']],
 'target_gains_db':[r['target_gain_db'] for r in golden['cases']],'state_bytes':c['state_bytes'],'arm_executed':False}))
