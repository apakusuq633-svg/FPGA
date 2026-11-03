"""Verify repository evidence without local tool paths, board access, or timing reruns."""
from pathlib import Path
import argparse,csv,hashlib,json,math,statistics,sys

HERE=Path(__file__).resolve().parent
DATA=HERE/'performance_comparison'
def read(path):return json.loads(path.read_text(encoding='utf-8-sig'))
def require(condition,message):
    if not condition:raise ValueError(message)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def percentile(values,q):
    values=sorted(values);pos=(len(values)-1)*q;i=int(pos);j=min(i+1,len(values)-1)
    return values[i]+(values[j]-values[i])*(pos-i)
def check_summary(values,summary,label):
    require(len(values)==summary['repeats'],label+': repeat count differs')
    for key,value in [('mean',statistics.mean(values)),('p50',statistics.median(values)),('p95',percentile(values,.95)),('max',max(values)),('min',min(values))]:
        require(math.isclose(value,summary[key],rel_tol=1e-12,abs_tol=1e-12),label+': '+key+' differs')
def verify_hash_manifest():
    manifest=read(HERE/'retained_files.json');checked=0
    for item in manifest['files']:
        path=(HERE/item['path']).resolve()
        require(path.is_relative_to(HERE), 'Manifest path escapes evidence directory')
        require(path.is_file(),'Missing evidence: '+item['path'])
        require(path.stat().st_size==item['bytes'] and sha(path)==item['sha256'],'Evidence hash differs: '+item['path'])
        checked+=1
    return checked
def verify_saved_artifacts(base,result):
    count=0
    for name,expected in result.get('artifact_hashes',{}).items():
        p=base/name
        if p.exists():
            require(sha(p)==expected,'Recorded hash differs: '+str(p.relative_to(HERE)));count+=1
        else:
            # Executables were deliberately omitted from the source/evidence release.
            require(Path(name).parts[0]=='build' or p.suffix.lower() in ['.exe','.dll','.o','.obj','.vvp','.elf'], 'Missing recorded data: '+name)
    return count
def analyze():
    checked=verify_hash_manifest()
    pl=read(DATA/'pl_rtl/results.json');tests=pl['tests'];scalar=read(DATA/'circular9_scalar/rv_plain_Os/results.json')
    require(pl['pl_clock_hz']==40000000,'Unexpected timing conversion clock')
    require(scalar['pass'] and all(x['mismatched_bytes']==0 for x in scalar['checks_vs_host'].values()),'Scalar output mismatch')
    require(sha(DATA/'circular9_scalar/input.pcm')==scalar['input_sha256'],'Scalar PCM input differs')
    circ=tests['circular9'];require(circ['status']=='PASS' and circ['windows']==32,'Continuous-window record differs')
    require(all(len(circ[k])==32 for k in ['frames','window_latency','post','score_completion_boundary','stage_aggregates']),'Window records incomplete')
    first=circ['score_completion_boundary'][0];require(first['first_sample']==0,'Wrong first-window comparison')
    require(tests['fft']['mismatched_int16']==0 and tests['fft']['int16_checked']==1026,'FFT output mismatch')
    require(tests['fir']['mismatched_samples']==0 and tests['fir']['samples_checked']==512,'FIR output mismatch')
    metrics=[]
    def add(item,baseline,optimized,unit,scope):
        metrics.append({'指标':item,'原始方案':baseline,'改进方案':optimized,'单位':unit,'加速比':baseline/optimized,'验证范围':scope})
    add('九麦完整方向评分',scalar['scalar_call_cycles'],first['raw_ready_to_scores'],'cycles','同一首窗；输入驻留至1024格评分；RTL')
    add('1024点实数FFT',tests['fft']['scalar_cycles'],tests['fft']['hardware_total_cycles'],'cycles','含装载、运行和取回；RTL')
    add('512点32抽头FIR',tests['fir']['scalar_cycles'],tests['fir']['simd_cycles'],'cycles','完整调用；512点整数结果一致；RTL')
    srp=read(DATA/'rtl_primitives/measured_20261028/srp/results.json');cycles={}
    require(srp['pass'],'SRP record failed')
    for case in srp['cases']:
        require(case['pass'] and case['compared_scores']==2048,'SRP output record failed')
        if case['r_len']==64 and case['idx_w']==6:cycles[case['fast_scan']]=statistics.mean(case['start_to_done_cycles'])
    add('SRP总结构对照',cycles[0],cycles[4],'cycles','原串行至快速四麦对；START到DONE；RTL')
    add('SRP同结构并行增益',cycles[1],cycles[4],'cycles','快速单麦对至快速四麦对；RTL')
    hostbase=DATA/'ps_software/measured_20261028_host_quiet';host=read(hostbase/'results.json')
    require(host['passed'] and host['source_unchanged'],'Host result not accepted')
    groups={}
    with (hostbase/'raw_timings.csv').open(encoding='utf-8',newline='') as f:rows=list(csv.DictReader(f))
    for row in rows:groups.setdefault((row['benchmark'],row['fixture'],row['variant']),[]).append(float(row['wall_ms']))
    for scene,variants in host['search']['summary'].items():
        for variant,s in variants.items():check_summary(groups[('search',scene,variant)],s,'search/'+scene+'/'+variant)
        add('PS搜索/'+scene,variants['reference']['mean'],variants['combined']['mean'],'ms','同一Windows宿主；41次；不代表A9板端')
        ref=(hostbase/'numeric'/f'{scene}_reference_scores.bin').read_bytes()
        feedback=(hostbase/'numeric'/f'{scene}_reference_feedback.bin').read_bytes()
        for variant in variants:
            require((hostbase/'numeric'/f'{scene}_{variant}_scores.bin').read_bytes()==ref,'PS score output differs')
            require((hostbase/'numeric'/f'{scene}_{variant}_feedback.bin').read_bytes()==feedback,'PS feedback differs')
    for variant,s in host['division']['summary'].items():check_summary(groups[('division','4096_batches_of_32',variant)],s,'division/'+variant)
    for variant,s in host.get('envelope',{}).get('summary',{}).items():check_summary(groups[('envelope','AM_600rpm_3400Hz',variant)],s,'envelope/'+variant)
    artifact_checks=verify_saved_artifacts(hostbase,host)
    fullbase=DATA/'ps_software/full_modules/measured_20261028_full_quiet';full=read(fullbase/'results.json')
    require(full['passed'] and full['source_unchanged'] and not full['probe_only'],'Full-module record failed')
    with (fullbase/'raw_timings.csv').open(encoding='utf-8',newline='') as f:fullrows=list(csv.DictReader(f))
    groups={}
    for row in fullrows:groups.setdefault((row['module'],row['mode']),[]).append(float(row['wall_ms']))
    for (module,mode),values in groups.items():check_summary(values,full['gsc']['summary'][mode] if module=='gsc' else full['separation']['summary'],module+'/'+mode)
    for mode,expected in [('disabled_bypass','gsc_expected_bypass.i16le'),('adaptive_enabled','gsc_expected_active.i16le')]:
        require((fullbase/'numeric'/('gsc_'+mode+'.i16le')).read_bytes()==(fullbase/'inputs'/expected).read_bytes(),'GSC integer output differs')
    require(full['gsc']['validation']['adaptive_enabled']['active']==32768,'GSC active sample count differs')
    require(full['separation']['validation']['ready_mask']==3 and full['separation']['validation']['invalid_input']==0,'Separation validity differs')
    artifact_checks+=verify_saved_artifacts(fullbase,full)
    for row,expected in zip(metrics[:5],[134.1692206814484,27.118448954862163,18.28339278636544,15.843773503814333,3.991941549371441]):
        require(math.isclose(row['加速比'],expected,rel_tol=1e-8),'Metric differs: '+row['指标'])
    return {'passed':True,'scope':'Repository file integrity, recorded numerical outputs and timing statistics; no compilation, timing rerun or board test','retained_files_checked':checked,'original_artifact_hashes_checked':artifact_checks,'host_timing_rows':len(rows),'full_module_timing_rows':len(fullrows),'continuous_rtl_windows':32,'board_measurement_added':False,'metrics':metrics}
def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path);args=parser.parse_args()
    try:result=analyze()
    except (ValueError,KeyError,OSError) as e:print('FAIL: '+str(e),file=sys.stderr);return 1
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
