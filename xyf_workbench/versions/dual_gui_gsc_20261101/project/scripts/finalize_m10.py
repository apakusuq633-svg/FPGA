"""Gate the final M10 release against actual regressions, snapshots and builds."""
from pathlib import Path
import argparse,collections,csv,hashlib,json,re,struct
p=argparse.ArgumentParser();p.add_argument('--preflight',action='store_true');a=p.parse_args()
R=Path(__file__).resolve().parents[1];O=R/'build/m10_20261016'
V=R/'build/zynq12_integrated_plan/m10_regression_v2_20261016';S=V/'safety'
I=R/'build/zynq12_integrated_plan/m10_impl_20261016';M9=R/'build/m9_merge_20261016'
def read(f):return json.loads(f.read_text(encoding='utf-8-sig'))
def log(f):
 b=f.read_bytes();return b.decode('utf-16' if b.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig',errors='replace')
def sha(f):
 h=hashlib.sha256()
 with f.open('rb')as stream:
  for b in iter(lambda:stream.read(1024*1024),b''):h.update(b)
 return h.hexdigest()
tool_history={}
def source_check(values):
 for name,value in values.items():
  if sha(R/name)!=value:
   assert name in tool_history and sha(tool_history[name])==value,('SOURCE_CHANGED',name)
def metrics(folder,status):
 value=read(folder/'metrics.json');assert value['status']==status,(folder,value['status']);return value
assert not (O/'acceptance.json').exists(),'Do not overwrite a packaged release'
pending=[]
before=read(O/'before_sources.json');m9_manifest=read(M9/'release_manifest.json')
m9_hashes={row['path']:row['sha256'] for row in m9_manifest['files']}
changed={name for name,value in before.items() if sha(R/name)!=value}
merge=read(O/'concurrent_merge.json');assert merge['status']=='DEFAULT_PATH_EQUIVALENCE_PROVED'
assert sha(R/'scripts/audit_m10_concurrent_merge.py')==merge['audit_script_sha256']
external={row['path'] for row in merge['concurrent_changes']}
assert changed=={'sw/fw/fw_localizer12.c','tb/tb_localizer12_safety.v'}|external,changed
for row in merge['concurrent_changes']:
 assert row['before_sha256']==before[row['path']] and row['current_sha256']==sha(R/row['path'])
legacy={'sw/fw/fw_localizer12.c':O/'before/fw_localizer12.c',
        'tb/tb_localizer12_safety.v':O/'before/tb_localizer12_safety.v'}
legacy.update({name:R/path for name,path in merge['historical_copies'].items()})
for name,file in legacy.items():assert sha(file)==before.get(name,m9_hashes.get(name))
for row in merge['supporting_doc_updates']:
 assert row['before_sha256']==m9_hashes[row['path']] and row['current_sha256']==sha(R/row['path'])
tool_history['scripts/check_localizer12_safety.py']=legacy['scripts/check_localizer12_safety.py']
assert not merge['default_overlay_enabled']
protocol=read(O/'ps_capture_protocol/results.json');assert protocol['source_sha256']==sha(R/'sw/ps_pdm.c')
assert len(protocol['cases'])==12 and all(row['returncode']==0 for row in protocol['cases'])
old_protocol=read(O/'ps_capture_before/results.json');assert old_protocol['source_sha256']==sha(legacy['sw/ps_pdm.c'])
assert sum(row['expected']==1 for row in old_protocol['cases'])==4
assert 'PS_PDM_STARTUP_ORDER_PASS' in log(O/'ps_capture_startup/run_1.log')
assert 'PS_PDM_DEAD_STARTUP_BOUNDED_PASS' in log(O/'ps_capture_startup/run_2.log')
# Numerical evidence, binaries and archived source versions remain pinned.
# Authorized supporting-document updates have separate version records.
supporting_changes={row['path']:row for row in merge['supporting_doc_updates']}
for row in m9_manifest['files']:
 if row['path'] in supporting_changes and row['path'] not in legacy:
  document=supporting_changes[row['path']]
  assert row['sha256']==document['before_sha256'] and sha(R/row['path'])==document['current_sha256']
  assert sha(R/document['current_snapshot'])==document['current_sha256']
  continue
 f=legacy.get(row['path'],R/row['path'])
 assert f.is_file() and f.stat().st_size==row['bytes'] and sha(f)==row['sha256'],('M9_DRIFT',row['path'])
perf=read(O/'performance.json');assert perf['status']=='PASS_MEASURED_AB' and perf['normal_checker_equivalence_verified']
assert sha(R/'sw/fw/fw_localizer12.c')==perf['after_sha256']
assert sha(legacy['sw/fw/fw_localizer12.c'])==perf['before_sha256']
assert perf['compute_saved_cycles']>0 and not perf['algorithm_approximation'] and not perf['core_rtl_modified']
for folder in ('profile_before_v2','profile_final_v2','request_wrap_release'):
 source_check(read(O/folder/'profile_sources.json'));source_check(read(O/folder/'sources.json'))
source_check(read(S/'sources.json'));source_check(read(S/'manifest.json')['oracle_sources'])
source_check(read(O/'auxiliary/source_manifest.json'))
assert 'PHAT_BOUNDARY_DIAGNOSIS_CONFIRMED' in log(O/'boundary_reproduced_driver.log')
diagnosis=read(O/'boundary_reproduced/diagnosis.json')
assert diagnosis['status']=='CONFIRMED_CHECKER_SAMPLED_UNACCEPTED_DATA'
assert 'loss_now=1 run_ok=0 ac_start=0 ac_fire=0 phi_check=1' in diagnosis['diagnostic']
negative=read(O/'checker_negative/negative_control.json');assert negative['status']=='PASS_REJECTED_CORRUPT_ACCEPTED_PHAT'
assert read(O/'request_wrap_release/request_wrap.json')['status']=='PASS_FIRMWARE_TICKET_WRAP'
boundary=read(S/'boundary_fixed_summary.json')['results'][0];assert boundary['status']=='EXPLICIT_LOSS'
assert boundary['raw_drop']+boundary['window_drop']>0
model=metrics(O/'model528','PASS');assert model['scenarios']==528
old_model=read(M9/'model528/metrics.json');assert model['angles']==old_model['angles'] and model['das_complex_rms_error']==old_model['das_complex_rms_error']
cal=metrics(O/'calibrated_rtl_release','PASS');assert len(cal['cases'])==4
for row in cal['cases']:
 assert row['all_scores_checked']==1024 and row['angle_error_deg']<=18
 assert 'all_scores_checked=1024' in log(R/row['rtl_result']['log'])
aux=read(O/'auxiliary/metrics.json');assert len(aux)==19 and all(x['status']=='PASS' for x in aux)
isolation=read(O/'dma_isolation_release/dma_isolation_metrics.json')
assert isolation['status']=='PASS_SAFE_QUARANTINE' and isolation['main_pipeline']=='PASS'
assert isolation['quarantined_transactions']==1 and isolation['dma_published']==0
assert isolation['normal_result']['windows']==8 and isolation['normal_result']['raw_checks']==294912
assert 'LOCALIZER12_SOC_PASS windows=4' in log(R/'build/pdm12_runs/m10_20261016_soc_xsim/simulation.log')
for mem in ('itcm','dtcm'):
 expected=(O/'profile_final_v2/fw'/f'{mem}.hex').read_bytes()
 assert (S/'fw'/f'{mem}.hex').read_bytes()==expected
 assert (O/'rv32_release/fw'/f'{mem}.hex').read_bytes()==expected
rv32_manifest=read(O/'rv32_release/build_manifest.json')
assert rv32_manifest['test_transfer'] and rv32_manifest['transfer_windows']==0 and not rv32_manifest['geometry_enabled']
rvelf=O/'rv32_release/fw/fw_live12.elf'
assert struct.unpack_from('<H',rvelf.read_bytes(),18)[0]==243
assert 'M9_PLATFORM_PASS' in log(O/'platform_build_v3.log')
assert 'after 5000' in log(O/'build_stream_platform_v3.tcl')
arm=[]
for folder,enabled in [('ps_default_release',False),('ps_gsc_release',True)]:
 b=O/folder;m=read(b/'build_manifest.json');assert m['status']=='PASS_BUILD_ONLY' and m['gsc_enabled']==enabled
 for name,value in m['source_hashes'].items():
  if name.startswith('sw/'):assert sha(R/name)==value,(folder,name)
 assert sha(I/'das_fir.xsa')==m['source_hashes']['XSA'] and sha(b/'pdm_stream.elf')==m['source_hashes']['ELF']
 assert struct.unpack_from('<H',(b/'pdm_stream.elf').read_bytes(),18)[0]==40
 assert 'gsc12_test_' not in log(b/'symbols.txt');arm.append(m)
pl={str(f.relative_to(R)):sha(f) for folder in ('rtl','configs','constrs') for f in (R/folder).rglob('*') if f.is_file()}
implemented=read(I/'source_manifest.json');source_check(implemented)
extra={row['path']:row for row in merge['additional_configs']}
assert set(pl)-set(implemented)==set(extra) and not set(implemented)-set(pl)
for name,row in extra.items():assert pl[name]==row['sha256'] and not row['synthesized_input'] and row['assumptions_match_frozen_analysis']
assert re.search(r'^FLOW_PASS',log(I/'implementation.log'),re.M)
timing={};text=log(I/'timing_zynq.rpt')
for label,name in [('Setup','wns_ns'),('Hold','whs_ns')]:
 m=re.search(label+r'\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+([-\d.]+)ns',text)
 assert m and float(m[1])>=0;timing[name]=float(m[1])
timing.update(tns_ns=0,ths_ns=0)
resources={};text=log(I/'util_zynq.rpt')
for label,name in [('Slice LUTs','lut'),('Slice Registers','ff'),('Block RAM Tile','bram36'),('DSPs','dsp')]:
 m=re.search(r'\|\s*'+label+r'\*?\s*\|\s*([\d.]+)',text);assert m;resources[name]=float(m[1])
m9=read(M9/'acceptance.json');assert resources==m9['implementation']['resources']
assert timing==m9['implementation']['timing']
assert 'M10_ROUTED_AUDIT_PASS' in log(O/'routed_audit.log')
check=log(O/'routed_audit/check_timing.rpt')
for key in ('no_clock','unconstrained_internal_endpoints','no_input_delay'):assert re.search(r'checking '+key+r' \(0\)',check),key
assert 'All paths are Safely Timed.' in log(O/'routed_audit/cdc.rpt')
assert 'No congestion windows are found above level 5' in log(O/'routed_audit/congestion.rpt')
external={}
for name in ('nominal','late_setup','early_hold'):
 values={}
 for line in log(O/'routed_audit/external_window'/name/'summary.txt').splitlines():
  group,kind,slack=line.split();values[group+'_'+kind]=float(slack)
 assert len(values)==4
 if name=='nominal':assert min(values.values())>=0
 if name=='late_setup':assert values['A_max']<0 and values['B_max']<0
 if name=='early_hold':assert values['A_min']<0 and values['B_min']<0
 external[name]=values
power={}
for name in ('before','after'):
 text=log(O/f'routed_audit/power_vectorless_{name}.rpt')
 m=re.search(r'\|\s*Total On-Chip Power \(W\)\s*\|\s*([\d.]+)',text);assert m
 assert re.search(r'\|\s*Confidence Level\s*\|\s*Low',text)
 power[name]=dict(watts=float(m[1]),confidence='Low',activity='VECTORLESS; NOT FIRMWARE-AWARE')
normal=read(S/'normal1024_summary.json')['results'][0] if (S/'normal1024_summary.json').exists() else None
if normal is None:pending.append('normal1024')
long=read(V/'extended4096/metrics.json') if (V/'extended4096/metrics.json').exists() else None
if long is None:pending.append('long4096')
for value,n in ([] if normal is None else [(normal,1024)])+([] if long is None else [(long,4096)]):
 assert value['status']=='PASS' and value['windows']==n and value['raw_checks']==n*12*1024*3
 assert value['raw_drop']==value['window_drop']==value['audio_drop']==value['gsc_overflow']==0
 assert value['max_latency']==393217 and value['max_compute']<323463
if long is not None:
 lm=read(V/'extended4096/manifest.json');source_check(lm['sources'])
 assert sha(Path(lm['binary_path']))==lm['binary_sha256'] and sha(S/'fw/fw_live12.elf')==lm['firmware_sha256']
runs=read(V/'runs.json')
if len(runs)!=22:pending.append('full22')
assert all(row['status']=='PASS' for row in runs),runs[-1]
matrix=None;comparison=[];counts={}
if (S/'matrix183_summary.json').exists():
 matrix=read(S/'matrix183_summary.json');assert matrix['status']=='PASS' and len(matrix['results'])==183
 counts=dict(collections.Counter(row['status'] for row in matrix['results']));assert not counts.get('ERROR',0)
 base=read(R/'build/zynq12_integrated_plan/m9_merge_regression_20261016/safety/matrix183_summary.json')
 key=lambda row:tuple(row[k] for k in ('kind','phase','duration','target','offset','requested_windows','seed','seq_base'))
 prior={key(row):row for row in base['results']};rank={'PASS':0,'CORRECT_LATE':1,'EXPLICIT_LOSS':2}
 assert len(prior)==183
 for row in matrix['results']:
  old=prior[key(row)];assert rank[row['status']]<=rank[old['status']],('STRESS_REGRESSION',old,row)
  comparison.append(dict(kind=row['kind'],phase=row['phase'],duration=row['duration'],before=old['status'],after=row['status']))
else:pending.append('matrix183')
dtcm=None
if (V/'dtcm/dtcm50000_summary.json').exists():
 dtcm=read(V/'dtcm/dtcm50000_summary.json')['results'][0];assert dtcm['status']=='PASS' and dtcm['dtcm_blocked']==50000
else:pending.append('real_DTCM50000')
for k in range(4):assert 'all_scores_checked=1024' in log(V/f'physical{k}_rtl.log')
if not pending:
 assert len(read(V/'rv32/summary.json'))==9
 assert 'INTEGRATED_VALIDATION_PASS' in log(O/'regression_v2_driver.log')
if a.preflight:
 print('M10_PREFLIGHT_CHECKED',json.dumps(dict(pending=pending,timing=timing,resources=resources,stress=counts,release_created=False)));raise SystemExit(0)
assert not pending,pending
with (O/'stress_comparison.csv').open('w',newline='')as f:
 w=csv.DictWriter(f,fieldnames=list(comparison[0]));w.writeheader();w.writerows(comparison)
old_m5=read(R/'build/zynq12_integrated_plan/reports/final/acceptance.json')
baseline_cycles=old_m5['long4096']['max_compute'];assert baseline_cycles==323463
saved=baseline_cycles-long['max_compute']
report=dict(stage='M10',status='PASS_SIM_IMPL_MEASURED_OPTIMIZATION',hardware='DEFERRED_HARDWARE',
 scope=dict(channels=12,nfft=1024,hop=512,pairs=66,grid=1024,simd_lanes=8,clock_hz=40000000,part='xc7z020clg400-1'),
 changed_preexisting_files=sorted(changed),production_changes=['sw/fw/fw_localizer12.c','sw/ps_pdm.c'],
 own_optimization_source='sw/fw/fw_localizer12.c',concurrent_merge=merge,ps_capture_protocol=protocol,
 checker_fix='Qualify PHAT with actual ac_start && ac_ready; legacy failure and accepted-corruption negative control retained',
 protected_sources_unchanged=len(before)-len(changed),performance=perf,normal1024=normal,long4096=long,
 compute_vs_m5=dict(before_cycles=baseline_cycles,after_cycles=long['max_compute'],saved_cycles=saved,saved_microseconds=saved/40,improvement_percent=100*saved/baseline_cycles),
 timing=timing,resources=resources,power=power,external_window=external,stress_classifications=counts,
 stress_regressions=0,model_scenarios=528,auxiliary_tests=19,runs=runs,dtcm=dtcm,arm=arm,
 m9_manifest_sha256=sha(M9/'release_manifest.json'),rv32_firmware_role='TEST_GEOMETRY_ONLY; PS-loaded separate ITCM/DTCM',
 m6_m9_reused_components='Exact source/artifact hashes; full M10 SoC separately checks RAW/DAS/FIR/tap and directions',
 deferred=m9['deferred'],board_actions='NONE')
(O/'acceptance.json').write_text(json.dumps(report,indent=2))
index=R/'docs/M6-M10_交付索引_2026-10-16.md'
index.write_text(f'''# M6–M10 实施交付索引

全部阶段的软件/RTL适用验收完成；实板状态均为 DEFERRED_HARDWARE。保持12路、1024 FFT、512 Hop、66对、1024格、八lane SIMD和40MHz。生产坐标与通道映射仍未填入。

| 阶段 | 结果 | 报告 |
|---|---|---|
| M6 | PASS_SIM_IMPL；1024/4096窗及完整实现 | [PDM同步审计](M6_PDM同步审计_2026-10-16.md) |
| M7 | PASS_SOFTWARE_RTL_REGRESSION | [几何标定机制](M7_几何标定机制_2026-10-16.md) |
| M8 | PASS_PROTOTYPE_SOFTWARE_RTL；合成SNR提升8.94–10.30dB | [GSC原型](M8_GSC原型接口与验收_2026-10-16.md) |
| M9 | PASS_SOFTWARE_RTL_IMPL；DMA、PS环、UDP及GSC应用mock | [DMA/UDP实施](M9_DMA_UDP实施与验收_2026-10-16.md) |
| M10 | PASS_SIM_IMPL_MEASURED_OPTIMIZATION | [固件派发优化](M10_固件派发优化与验收_2026-10-16.md) |

M10完整4096窗最坏计算从M5的{baseline_cycles}拍降到{long['max_compute']}拍，节省{saved}拍（{saved/40:.3f}微秒，{100*saved/baseline_cycles:.4f}%）。固定发布延迟仍为393217拍。MMIO总访问增加4.84%，代码增加20字节；未声称功耗下降。

本轮最终回归：1024和4096窗零RAW/window/audio丢失，4096窗{long['raw_checks']}次RAW检查；183压力分类{json.dumps(counts,ensure_ascii=False)}，相对M9无退步。非实时正确与显式损失保持独立分类。另有528模型、4个基线及4个校准RTL场景、19辅助RTL、CPU/内存/MMIO/严格验收、真实50000拍DTCM阻塞、XSim、ticket回绕、错误接受数据负例、DMA隔离。

最新Vivado为xc7z020clg400-1：WNS +{timing['wns_ns']:.3f}ns、WHS +{timing['whs_ns']:.3f}ns，TNS/THS=0；{int(resources['lut'])} LUT、{int(resources['ff'])} FF、{resources['bram36']} BRAM36、{int(resources['dsp'])} DSP。WHS余量较小。外部PDM窗口仅在明确假设下分析通过。

## 当前交付与复验

- [最终acceptance](../build/m10_20261016/acceptance.json)
- [完整文件/哈希清单](../build/m10_20261016/release_manifest.json)
- [修改文件清单](../build/m10_20261016/changed_files.csv)
- [A/B数据](../build/m10_20261016/performance.json) / [逐项压力对比](../build/m10_20261016/stress_comparison.csv)
- [连续RV32镜像与ELF](../build/m10_20261016/rv32_release/build_manifest.json)
- [新XSA](../build/zynq12_integrated_plan/m10_impl_20261016/das_fir.xsa) / [时序](../build/zynq12_integrated_plan/m10_impl_20261016/timing_zynq.rpt)
- [PS默认旁路ELF](../build/m10_20261016/ps_default_release/pdm_stream.elf) / [显式TEST_ONLY GSC ELF](../build/m10_20261016/ps_gsc_release/pdm_stream.elf)

复验：`wsl python3 scripts/verify_stage_release.py --manifest build/m10_20261016/release_manifest.json`。所有重新仿真/构建命令见各阶段报告，并使用新输出目录。旧阶段清单对应历史源版本；M10 before目录保存本轮修改前固件和testbench。

## 实板待验收

芯片完整型号、12麦DATA/LR/CLK和供电、电气启动窗口、生产几何/通道映射和真实标定、Cortex-A9 GSC与DDR缓存/DMA/网口吞吐、拥塞长跑、实测角度和音质均待验收。RV32固件仍标TEST_GEOMETRY_ONLY，PS应用也保留UNVERIFIED标志；未用测试坐标启用生产定位。没有执行Git提交、Git复位/清理或板卡烧写/复位。
''',encoding='utf-8')
stage_sources=['scripts/localizer12_profile.h','scripts/profile_localizer12.py','scripts/prepare_m10_candidates.py',
 'scripts/analyze_localizer12_profile.py','scripts/check_localizer12_request_wrap.py','scripts/audit_m10_routed.tcl',
 'scripts/diagnose_localizer12_boundary.py','scripts/check_localizer12_checker.py','scripts/finalize_m10.py',
 'scripts/audit_m10_concurrent_merge.py',
 'scripts/ps_pdm_protocol_mock.c','configs/pdm_external_assumptions.json',
 'docs/M10_固件派发优化与验收_2026-10-16.md',str(index.relative_to(R))]
with (O/'changed_files.csv').open('w',newline='')as f:
 w=csv.DictWriter(f,fieldnames=['path','role','before_sha256','after_sha256']);w.writeheader()
 for name in sorted(changed):w.writerow(dict(path=name,role='concurrent merge' if name in external else ('production optimization' if name.startswith('sw/') else 'testbench'),before_sha256=before[name],after_sha256=sha(R/name)))
 for name in stage_sources:w.writerow(dict(path=name,role='new stage tool/report',before_sha256='',after_sha256=sha(R/name)))
paths={R/row['path'] for row in m9_manifest['files']}
paths.update(R/name for name in before);paths.update(R/name for name in stage_sources)
paths.add(M9/'release_manifest.json')
extensions={'.json','.log','.rpt','.md','.txt','.csv','.bin','.hex','.elf','.npz','.su','.ld','.h','.c','.cpp','.tcl','.ps1','.bit','.xsa','.dcp','.a','.spec','.udp','.py','.v','.vh','.xdc','.f','.s','.so','.jou'}
for base in (O,V,I,R/'build/pdm12_runs/m10_20261016_soc_xsim'):
 for f in base.rglob('*'):
  if not f.is_file() or '__pycache__' in f.parts or '.metadata' in f.parts:continue
  if any(part in ('platform_workspace','platform_workspace_v2') for part in f.parts):continue
  if f.suffix.lower() in extensions:paths.add(f)
paths.difference_update({O/'finalize.log',O/'handoff_verification.log'})
paths.add(S/'model/Vtb_localizer12_safety')
paths.add(R/'build/zynq12_integrated_plan/m10_impl_20261016_project/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit')
manifest=dict(status=report['status'],hardware='DEFERRED_HARDWARE',files=[dict(path=str(f.relative_to(R)),bytes=f.stat().st_size,sha256=sha(f)) for f in sorted(paths)])
(O/'release_manifest.json').write_text(json.dumps(manifest,indent=2))
print('M10_RELEASE_PASS',json.dumps(dict(compute_vs_m5=report['compute_vs_m5'],timing=timing,resources=resources,stress=counts,files=len(paths))))
