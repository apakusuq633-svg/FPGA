"""Bind M7 measured software/RTL evidence to the unchanged M6 production inputs."""
from pathlib import Path
import hashlib,json,struct
import numpy as np
R=Path(__file__).resolve().parents[1];O=R/'build/m7_20261016';D=O/'calibration_release'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
assert not (O/'acceptance.json').exists(),'M7 already packaged'
baseline=read(R/'build/m6_20261016/release_manifest.json')
assert baseline['status']=='PASS_SIM_IMPL'
for row in baseline['files']:assert sha(R/row['path'])==row['sha256'],('M6 baseline changed',row['path'])
source=read(R/'build/m6_20261016/implementation_sources.json')
current={str(p.relative_to(R)):sha(p) for folder in ('rtl','constrs','configs') for p in (R/folder).rglob('*') if p.is_file()}
assert source==current,'PL files changed; implementation cannot be reused'
cal=read(D/'metrics.json');assert cal['status']=='PASS_SOFTWARE' and cal['c_loader_rejections']==849
for p,h in cal['source_hashes'].items():assert sha(R/p)==h,('source changed',p)
for name in ('rv32','cortex_a9'):
    obj=(D/(name+'.o')).read_bytes();assert obj[:4]==b'\x7fELF'
    assert struct.unpack_from('<H',obj,18)[0]==(243 if name=='rv32' else 40)
for file in ('test_only_calibration.bin','test_only_srp_lut.hex','test_only_steer_lut.hex'):
    assert sha(D/file)==sha(O/'calibration_final'/file),('RTL input drift',file)
data=np.load(D/'synthetic_capture.npz',allow_pickle=False);used=np.load(O/'calibration_final/synthetic_capture.npz',allow_pickle=False)
assert all(np.array_equal(data[k],used[k]) for k in ('pcm','reference','directions'))
assert sha(D/'test_only_calibration.bin')==sha(O/'cli_release/calibration.bin')
rtl=read(O/'calibrated_rtl/metrics.json');assert rtl['status']=='PASS' and len(rtl['cases'])==4
assert all(r['all_scores_checked']==1024 and r['rtl_result']['status']=='PASS' for r in rtl['cases'])
normal=read(O/'safety/baseline8_summary.json')['results'][0]
assert normal['status']=='PASS' and normal['windows']==8
assert normal['raw_drop']==normal['window_drop']==normal['audio_drop']==0
old=read(R/'build/m6_20261016/acceptance.json')
acceptance={'stage':'M7','status':'PASS_SOFTWARE_RTL_REGRESSION','hardware':'DEFERRED_HARDWARE',
 'production_configuration_unchanged':True,'production_geometry_enabled':False,
 'calibration':cal,'calibrated_rtl':rtl,'normal8':normal,
 'vivado':'REUSED_IDENTICAL_PL_INPUTS','timing':old['timing'],'resources':old['resources'],
 'baseline_full_regression':'build/m6_20261016/acceptance.json',
 'baseline_manifest_sha256':sha(R/'build/m6_20261016/release_manifest.json'),
 'not_validated':['real coordinates/mapping','physical calibration','live firmware deployment','Cortex-A9 runtime throughput','real angle accuracy']}
(O/'acceptance.json').write_text(json.dumps(acceptance,indent=2))
files={p for p in O.rglob('*') if p.is_file() and p.suffix.lower() in ('.json','.log','.bin','.hex','.npz','.o','.txt')}
files.update(R/p for p in ['scripts/pdm12_calibration.py','scripts/check_pdm12_calibration.py','scripts/check_m7_calibrated_rtl.py','scripts/finalize_m7.py','sw/pdm12_calibration.c','sw/pdm12_calibration.h','docs/M7_几何标定机制_2026-10-16.md'])
(O/'release_manifest.json').write_text(json.dumps({'status':acceptance['status'],'hardware':'DEFERRED_HARDWARE',
 'files':[{'path':str(p.relative_to(R)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(files)]},indent=2))
print('M7_RELEASE_PASS',json.dumps({'loader_rejections':849,'calibrated_rtl_cases':4,'vivado':acceptance['vivado']}))
