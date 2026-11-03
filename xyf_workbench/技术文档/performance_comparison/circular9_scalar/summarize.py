"""Read measured results and produce the bounded same-task comparison."""
from pathlib import Path
import csv,datetime,hashlib,json,statistics
H=Path(__file__).resolve().parent
W=H.parents[1]
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
plain=read(H/'rv_plain_Os/results.json')
other=read(H/'rv_plain_O2_corrected/results.json')
profile=read(H/'rv_profile_Os/results.json')
host=read(H/'results.json')
valid=read(H/'validation.json')
windows=read(H/'windows_validation.json')
pl=read(H.parent/'pl_rtl/results.json')
anchor=next(row for row in pl['tests']['circular9']['score_completion_boundary'] if row['first_sample']==0)
assert all(x['pass'] for x in [plain,other,profile,host,valid,windows])
assert anchor['raw_ready_to_scores']==82354
values=[row['per_window_ms'] for row in host['host_wall_clock']]
rows=[
 {'scheme':'RV32 scalar nine-mic map','environment':'40MHz SoC RTL','optimization':'Os primary','cycles':plain['scalar_call_cycles'],'ms':plain['scalar_call_ms_at40MHz']},
 {'scheme':'PL accelerated nine-mic map','environment':'40MHz SoC RTL','optimization':'production Os plus hardware','cycles':anchor['raw_ready_to_scores'],'ms':anchor['raw_ready_to_scores']/40000},
 {'scheme':'RV32 scalar nine-mic map','environment':'40MHz SoC RTL','optimization':'O2 auxiliary','cycles':other['scalar_call_cycles'],'ms':other['scalar_call_ms_at40MHz']},
 {'scheme':'Portable scalar nine-mic map','environment':'x86_64 host QPC; NOT A9','optimization':'O2, auto-vectorization disabled','cycles':None,'ms':statistics.median(values)},
]
with (H/'comparison.csv').open('w',encoding='utf-8-sig',newline='') as f:
 writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
copies={p.name:p.read_bytes()==(W/'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog/sw/fw'/p.name).read_bytes() for p in (H/'third_party').iterdir() if p.is_file()}
assert all(copies.values())
summary={
 'pass':True,'completed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'task':'aligned raw1024x9 resident through1024 score writes;9FFT,36XSPEC/PHAT/IFFT64lag,36x1024Q4 SRP',
 'primary_rows':rows[:2],'auxiliary_rows':rows[2:],
 'primary_speedup':plain['scalar_call_cycles']/anchor['raw_ready_to_scores'],
 'primary_time_reduction_percent':100*(1-anchor['raw_ready_to_scores']/plain['scalar_call_cycles']),
 'same_first_sample':0,'PL_anchor':anchor,'scalar_boundary':plain['timing_boundary'],
 'excluded':['PDM/CIC/alignment','input/LUT preload','PS runtime','peak/confidence/tracking/publication','DAS/FIR/GSC/diagnosis','continuous-load acceptance'],
 'rolling_statistics_note':'PL statistics overlap acquisition; scalar computes statistics after raw input is ready. This is an explicit architecture organization difference.',
 'phase_profile':{'file':'rv_profile_Os/results.json','cycles':profile['phase_cycles'],'sum':sum(profile['phase_cycles'].values()),'instrumented_total':profile['scalar_call_cycles'],'delta_vs_uninstrumented':profile['scalar_call_cycles']-plain['scalar_call_cycles'],'note':'Instrumentation changes code generation. Phase table explains this build only; do not subtract these phases from plain Os or interpret faster total as negative timestamp overhead.'},
 'host':{'file':'results.json','median_batch_mean_ms':statistics.median(values),'min_batch_mean_ms':min(values),'max_batch_mean_ms':max(values),'rounds':9,'calls_per_round':64,'warmup_calls':3,'clock':'QueryPerformanceCounter','not_Cortex_A9':True,'individual_window_percentiles_not_measured':True,'competing_RTL_compiler_processes_observed_before_run':False},
 'validation':{'first_window_words':{k:v['words'] for k,v in valid['checks'].items()},'all_zero_mismatch':True,'all_window_count':windows['window_count'],'all_statistics_words':windows['statistics_words'],'all_score_words':windows['score_words'],'periodic_synthetic_input_frames':4096,'independent_real_recordings':False},
 'source_copies_identical_to_production':copies,
 'memory':{'scratch_base':'0x10000','scratch_bytes':65536,'packed_lut_bytes':46080,'raw_bytes':18432,'raw_reused_after_all_FFTs_for_correlations_and_scores':True,'workspace_bytes':6712,'entry_PC':0,'text_VMA':0,'build_id_disabled':True},
 'invalid_initial_run':{'file':'rv_failed_build_id_vma24/failure.json','excluded':True,'cause':'36B GNU build-id moved .text VMA while TB loaded section-only image at0; PCrelative startup cleared const data early. Fixed only in experiment link/loader, not production.'},
 'future_A9_entry':{'function':'c9s_locate(raw,lut,hann,&workspace,correlations,scores)','sources':['c9_scalar.c','third_party/fw_fft.c','third_party/fw_tables.c'],'define':'FW_ACCEL=0','remaining':'A9 DDR fixture loader and calibrated PMU/global timer board wrapper','A9_runtime_measured':False},
 'reproduce':['python performance_comparison/circular9_scalar/run_scalar.py --all-windows --bench 64','python performance_comparison/circular9_scalar/run_rv.py --reuse-model --optimization Os','python performance_comparison/circular9_scalar/run_rv.py --reuse-model --optimization Os --profile'],
 'PL_results_sha256':sha(H.parent/'pl_rtl/results.json'),
}
(H/'comparison_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
manifest={p.relative_to(W).as_posix():{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(H.rglob('*')) if p.is_file() and p.name!='artifact_hashes.json'}
(H/'artifact_hashes.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'primary_speedup':summary['primary_speedup'],'reduction_percent':summary['primary_time_reduction_percent'],'host_median_ms':statistics.median(values),'artifact_count':len(manifest),'production_copies_unchanged':all(copies.values())}))
