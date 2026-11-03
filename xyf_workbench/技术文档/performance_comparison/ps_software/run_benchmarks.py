"""Reproducible Windows x86-64 host benchmarks; never runs a board or edits production files.

All generated inputs, build outputs, raw timings and reports remain below this directory.
"""
from __future__ import annotations
import argparse
import array
import csv
import ctypes as C
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import statistics
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parent.parent
PROJECT = WORKSPACE / 'FPGA/xyf_workbench/zynq_-pl_-simd_-verilog'
GCC = Path('C:/msys64/ucrt64/bin/gcc.exe')
VARIANTS = {
    'reference': ['-DC9_REFERENCE_SEARCH_INTERPOLATION', '-DC9_REFERENCE_SEARCH_IFFT'],
    'precomputed_only': ['-DC9_REFERENCE_SEARCH_IFFT'],
    'paired_ifft_only': ['-DC9_REFERENCE_SEARCH_INTERPOLATION'],
    'combined': [],
}

class Tee:
    def __init__(self, stream, log): self.stream,self.log=stream,log
    def write(self, text):
        self.stream.write(text);self.log.write(text);return len(text)
    def flush(self): self.stream.flush();self.log.flush()

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def dump_json(path, document):
    Path(path).write_text(json.dumps(document, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

def binary(path, code, values):
    a = array.array(code, values)
    if sys.byteorder != 'little': a.byteswap()
    Path(path).write_bytes(a.tobytes())

def unpack(path, code):
    a = array.array(code)
    a.frombytes(Path(path).read_bytes())
    if sys.byteorder != 'little': a.byteswap()
    return a

def percentile(values, q):
    x = sorted(values); position = (len(x)-1)*q
    a = int(position); b = min(a+1, len(x)-1)
    return x[a] + (x[b]-x[a])*(position-a)

def summarize(values):
    return {'unit': 'ms', 'repeats': len(values), 'mean': statistics.mean(values),
            'p50': statistics.median(values), 'p95': percentile(values, .95),
            'max': max(values), 'min': min(values),
            'stdev': statistics.stdev(values) if len(values)>1 else 0}

def compile_library(out, name, files, defines, commands, env):
    dll = out / 'build' / (name + '.dll')
    cmd = [str(GCC), '-std=c11', '-O2', '-Wall', '-Wextra', '-shared',
           '-Wno-unused-function', '-Wno-unused-const-variable', '-MMD',
           '-I'+str(PROJECT/'sw'), *defines, *[str(HERE/f) for f in files],
           '-lm', '-o', str(dll)]
    started=time.perf_counter()
    p=subprocess.run(cmd, cwd=out/'build', env=env, capture_output=True, text=True)
    (out/'logs'/(name+'_compile.log')).write_text(p.stdout+p.stderr, encoding='utf-8')
    commands.append({'argv':cmd, 'returncode':p.returncode, 'build_wall_seconds':time.perf_counter()-started})
    if p.returncode: raise RuntimeError(f'{name}: compile failed: {p.stdout}{p.stderr}')
    return C.CDLL(str(dll)), dll

def source_hashes():
    names=['sw/circular9_candidates.c','sw/circular9_candidates.h','sw/circular9_decimator.h',
           'sw/circular9_direction.h','sw/circular9_diagnosis.h','sw/circular9_profile.h',
           'sw/acoustic_circular9_image.h','sw/gsc9.c','sw/gsc9.h','sw/circular9_envelope.h',
           'sw/bearing_6004_2zr.h','sw/ps_env_pipeline.h','sw/ps_features.h',
           'configs/circular9_array.json','scripts/build_circular9.py']
    return {str((PROJECT/n).relative_to(WORKSPACE)).replace('\\','/'):sha(PROJECT/n) for n in names}

def generate_search_inputs(out):
    config=json.loads((PROJECT/'configs/circular9_array.json').read_text(encoding='utf-8'))
    header=(PROJECT/'sw/acoustic_circular9_image.h').read_text(encoding='utf-8')
    match=re.search(r'static const uint32_t acoustic_steer_lut\[\d+\]\s*=\s*\{(.*?)\};', header, re.S)
    if not match: raise ValueError('Current generated steering LUT missing')
    lut=[int(v,0) for v in re.findall(r'0x[0-9a-fA-F]+|\d+',match.group(1))]
    assert len(lut)==9*1024
    lutpath=out/'inputs/steer_lut.u32le'; binary(lutpath,'I',lut)
    geometry=int(re.search(r'#define ACOUSTIC_GEOMETRY_VERSION (0x[0-9a-fA-F]+|\d+)',header)[1],0)
    calibration=int(re.search(r'#define ACOUSTIC_CALIBRATION_VERSION (0x[0-9a-fA-F]+|\d+)',header)[1],0)
    # Confirm the embedded table actually matches CURRENT configuration, avoiding a stale image.
    from importlib.util import spec_from_file_location, module_from_spec
    spec=spec_from_file_location('current_c9_builder', PROJECT/'scripts/build_circular9.py')
    builder=module_from_spec(spec);spec.loader.exec_module(builder)
    built=builder.geometry(config)
    expected_steer=built[1]
    if list(expected_steer)!=lut: raise AssertionError('Generated image steering LUT differs from current config')
    positions=config['channel_positions_m'];fs=156250.;nframes=16640
    scenes={
        'single_wideband':[(15.,8.,.065,[650+70*i for i in range(18)]+[2350+95*i for i in range(20)]+[4800+110*i for i in range(25)])],
        'three_band_sources':[(-55.,0.,.05,[600+30*i for i in range(40)]),
                              (15.,8.,.018,[2600+70*i for i in range(16)]),
                              (60.,-5.,.08,[5200+60*i for i in range(40)])],
    }
    metadata=[]
    for scene,sources in scenes.items():
        rng=random.Random(20261028);components=[]
        for az,el,amplitude,frequencies in sources:
            a,e=math.radians(az),math.radians(el)
            u=[math.cos(e)*math.sin(a), math.sin(e), math.cos(e)*math.cos(a)]
            phases=[rng.random()*2*math.pi for _ in frequencies]
            osc=[]
            for ch,pos in enumerate(positions):
                arrival=-sum(v*w for v,w in zip(pos,u))/config['sound_speed_m_s']
                osc.append([(2*math.pi*f/fs, phase-2*math.pi*f*arrival) for f,phase in zip(frequencies,phases)])
            components.append((amplitude/math.sqrt(len(frequencies)/2),osc))
        pcm=[];clipped=0;energy=[0]*9
        for n in range(nframes):
            for ch in range(9):
                value=sum(scale*sum(math.sin(step*n+phase) for step,phase in osc[ch]) for scale,osc in components)
                v=round(value*32768)+rng.randrange(-15,16)
                if not -32768<v<32767: clipped+=1
                v=max(-32768,min(32767,v));pcm.append(v);energy[ch]+=v*v
        assert clipped==0
        path=out/'inputs'/(scene+'.pcm');binary(path,'h',pcm)
        metadata.append({'scene':scene,'path':str(path),'sha256':sha(path),'source':'synthetic_far_field_plane_waves',
                         'frames':nframes,'channels':9,'format':'s16le_interleaved','sample_rate_num':156250,
                         'sample_rate_den':1,'warmup_raw_frames':256,'evidence_raw_frames':16384,
                         'geometry_confirmed':False,'calibration_version':calibration,'clipped_samples':clipped,
                         'rms_pcm':[math.sqrt(v/nframes) for v in energy],
                         'sources':[{'azimuth_deg':az,'elevation_deg':el,'amplitude':amp,'frequencies_hz':f} for az,el,amp,f in sources]})
    dump_json(out/'inputs/search_metadata.json',metadata)
    return lutpath,geometry,calibration,metadata

def measure_search(out,args,commands,env,rows):
    lutpath,geometry,calibration,fixtures=generate_search_inputs(out)
    libraries={}
    for name,flags in VARIANTS.items():
        lib,dll=compile_library(out,'search_'+name,['search_bench.c'],flags,commands,env)
        lib.bench_search_load.argtypes=[C.c_char_p,C.c_char_p,C.c_uint32,C.c_uint32]
        lib.bench_search_once.argtypes=[C.POINTER(C.c_double)]
        lib.bench_search_dump.argtypes=[C.c_char_p,C.c_char_p,C.c_char_p]
        libraries[name]=lib
    summaries={};equivalence={};first_calls={}
    for fixture in fixtures:
        scene=fixture['scene'];data={v:[] for v in VARIANTS};dumps={}
        for name,lib in libraries.items():
            assert lib.bench_search_load(os.fsencode(fixture['path']),os.fsencode(lutpath),geometry,calibration)==1
            ms=C.c_double();assert lib.bench_search_once(C.byref(ms))==1
            first_calls[f'{scene}/{name}']=ms.value
            for _ in range(args.warmup):assert lib.bench_search_once(C.byref(ms))==1
        rng=random.Random(24680)
        for iteration in range(args.search_repeats):
            order=list(VARIANTS);rng.shuffle(order)
            for position,name in enumerate(order):
                ms=C.c_double();assert libraries[name].bench_search_once(C.byref(ms))==1
                data[name].append(ms.value);rows.append(['search',scene,name,iteration,position,ms.value])
        for name,lib in libraries.items():
            paths=[out/'numeric'/f'{scene}_{name}_{suffix}.bin' for suffix in ('feedback','scores','last_band_lags')]
            assert lib.bench_search_dump(*[os.fsencode(p) for p in paths])==1
            dumps[name]=paths
        base=dumps['reference'];ref_feedback=unpack(base[0],'I');ref_scores=unpack(base[1],'i');ref_lags=unpack(base[2],'d')
        per_variant={}
        for name,paths in dumps.items():
            feedback=unpack(paths[0],'I');scores=unpack(paths[1],'i');lags=unpack(paths[2],'d')
            assert len(feedback)==len(ref_feedback) and len(scores)==len(ref_scores)
            differences=[(i,int(a),int(b)) for i,(a,b) in enumerate(zip(ref_feedback,feedback)) if a!=b]
            score_error=max(abs(a-b) for a,b in zip(ref_scores,scores))
            lag_error=max(abs(a-b) for a,b in zip(ref_lags,lags))
            # Whole public feedback must be word-exact, not merely the leading direction.
            assert not differences,(scene,name,'public feedback differs',differences)
            assert score_error<=1,(scene,name,'score error',score_error)
            assert lag_error<=1e-10,(scene,name,'lag error',lag_error)
            per_variant[name]={'feedback_word_exact':True,'feedback_words':len(feedback),
                               'all_3072_scores_max_abs_integer_error':score_error,
                               'last_processed_band_2304_lags_max_abs_error':lag_error,
                               'feedback_sha256':sha(paths[0]),'scores_sha256':sha(paths[1]),'lags_sha256':sha(paths[2])}
        assert ref_feedback[1]>0 and ref_feedback[12]==0,(scene,'fixture must exercise nonempty valid search')
        equivalence[scene]={'feedback_candidate_count':ref_feedback[1],'feedback_invalid_input':ref_feedback[12],
                            'variants':per_variant,'physical_classification_claimed':False}
        summaries[scene]={v:summarize(t) for v,t in data.items()}
        for v in summaries[scene]:
            summaries[scene][v]['mean_speedup_vs_reference']=summaries[scene]['reference']['mean']/summaries[scene][v]['mean']
        print('SEARCH',scene,json.dumps(summaries[scene],ensure_ascii=False),flush=True)
    return {'summary':summaries,'equivalence':equivalence,'first_call_ms_excluded':first_calls,
            'scope':'entire c9_candidates_search; excludes PCM generation/history copying/DMA/queue/HTTP',
            'first_call_note':'Each fixture first call excluded; lookup cache persists across fixtures; no ARM NEON on x86',
            'fixtures':fixtures,'lut_sha256':sha(lutpath),'reference_macros':VARIANTS}

def measure_division(out,args,commands,env,rows):
    rng=random.Random(20261028);bound=1<<44;den=[];nums=[]
    for b in range(4096):
        d=[1,3,(1<<35)+(1<<30),1<<20][b] if b<4 else rng.randrange(1,(1<<35)+(1<<30)+1)
        den.append(d);values=[0,1,-1,bound,-bound,d,-d,d-1,1-d]
        while len(values)<32:
            q=rng.randrange(0,bound//d+1);v=min(bound,q*d+rng.choice([0,1,d-1]));values.append(-v if rng.getrandbits(1) else v)
        nums.extend(values)
    np=out/'inputs/division_numerators.i64le';dp=out/'inputs/division_denominators.u64le'
    binary(np,'q',nums);binary(dp,'Q',den)
    lib,dll=compile_library(out,'division',['division_bench.c'],[],commands,env)
    lib.bench_division_load.argtypes=[C.c_char_p,C.c_char_p];lib.bench_division_once.argtypes=[C.c_int,C.POINTER(C.c_double)]
    lib.bench_division_dump.argtypes=[C.c_char_p];assert lib.bench_division_load(os.fsencode(np),os.fsencode(dp))==1
    outputs={};names=['signed_division_reference','production_shared_reciprocal'];data={n:[] for n in names}
    for mode,name in enumerate(names):
        ms=C.c_double();assert lib.bench_division_once(mode,C.byref(ms))==1
        path=out/'numeric'/(name+'.i64le');assert lib.bench_division_dump(os.fsencode(path))==1
        outputs[name]=unpack(path,'q')
        for _ in range(args.warmup):assert lib.bench_division_once(mode,C.byref(ms))==1
    expected=[(-1 if n<0 else 1)*(abs(n)//den[i//32]) for i,n in enumerate(nums)]
    assert list(outputs[names[0]])==expected==list(outputs[names[1]])
    rng=random.Random(100)
    for iteration in range(args.division_repeats):
        order=[0,1];rng.shuffle(order)
        for position,mode in enumerate(order):
            ms=C.c_double();assert lib.bench_division_once(mode,C.byref(ms))==1
            data[names[mode]].append(ms.value);rows.append(['division','4096_batches_of_32',names[mode],iteration,position,ms.value])
    summary={n:summarize(v) for n,v in data.items()}
    speedup=summary[names[0]]['mean']/summary[names[1]]['mean']
    print('DIVISION',json.dumps(summary),flush=True)
    return {'summary':summary,'mean_speedup':speedup,'quotients_compared':len(expected),'max_abs_error':0,
            'batches_per_timed_call':4096,'updates_per_batch':32,'scope':'division arithmetic only; NOT gsc9_process throughput',
            'baseline':'C signed int64 division with runtime-changing positive denominator per batch',
            'optimized':'unchanged production divide_shared plus one reciprocal per 32 quotients',
            'input_hashes':{np.name:sha(np),dp.name:sha(dp)}}

def measure_envelope(out,args,commands,env,rows):
    fs=39062.5;shaft=10.;orders=[.3975806451612903,2.338525527051054,3.578225806451613,5.421774193548387]
    mods=[(orders[0]*shaft,.12,.2),(shaft,.04,-.3),(4*orders[3]*shaft,.08,.4)]
    values=[.15*(1+sum(d*math.cos(2*math.pi*f*i/fs+p) for f,d,p in mods))*math.cos(2*math.pi*3400*i/fs+.37) for i in range(40000)]
    path=out/'inputs/envelope_am600rpm.f64le';binary(path,'d',values)
    lib,dll=compile_library(out,'envelope',['envelope_bench.c','envelope_legacy.c'],[],commands,env)
    lib.bench_envelope_load.argtypes=[C.c_char_p,C.c_double];lib.bench_envelope_once.argtypes=[C.c_int,C.POINTER(C.c_double)]
    lib.bench_envelope_features.argtypes=[C.c_int,C.POINTER(C.c_double)];lib.bench_envelope_spectrum.argtypes=[C.POINTER(C.c_double)]
    assert lib.bench_envelope_load(os.fsencode(path),shaft)==1
    names=['historical_24x8192_frontend','current_C9F2_1x4096_frontend'];data={n:[] for n in names}
    for mode in (0,1):
        for _ in range(args.warmup+1):
            ms=C.c_double();assert lib.bench_envelope_once(mode,C.byref(ms))==1
    rng=random.Random(55)
    for iteration in range(args.envelope_repeats):
        order=[0,1];rng.shuffle(order)
        for position,mode in enumerate(order):
            ms=C.c_double();assert lib.bench_envelope_once(mode,C.byref(ms))==1
            data[names[mode]].append(ms.value);rows.append(['envelope','AM_600rpm_3400Hz',names[mode],iteration,position,ms.value])
    features={}
    for mode,name in enumerate(names):
        buf=(C.c_double*18)();lib.bench_envelope_features(mode,buf);features[name]=list(buf)
    spectrum=(C.c_double*2049)();lib.bench_envelope_spectrum(spectrum)
    # Independent direct DFT of the ideal analytic AM envelope, outside all timings.
    rate=fs/16;window=[.5-.5*math.cos(2*math.pi*i/2499) for i in range(2500)];ws=sum(window)
    ideal=[.15*(1+sum(d*math.cos(2*math.pi*f*i/rate+p) for f,d,p in mods)) for i in range(2500)]
    mean=sum(a*b for a,b in zip(ideal,window))/ws;centered=[(a-mean)*w for a,w in zip(ideal,window)]
    bins=sorted({k for f,_,_ in mods for k in range(round(f/(rate/4096))-2,round(f/(rate/4096))+3) if k>0})
    checks=[]
    for k in bins:
        z=sum(v*complex(math.cos(-2*math.pi*k*i/4096),math.sin(-2*math.pi*k*i/4096)) for i,v in enumerate(centered))
        expected=2*abs(z)/ws;checks.append({'bin':k,'expected':expected,'actual':spectrum[k],'abs_error':abs(expected-spectrum[k])})
    error=max(c['abs_error'] for c in checks);assert error<2e-4
    assert lib.bench_envelope_status()==1
    dump_json(out/'numeric/envelope_features.json',features);dump_json(out/'numeric/envelope_dft_checks.json',checks)
    summary={n:summarize(v) for n,v in data.items()}
    speedup=summary[names[0]]['mean']/summary[names[1]]['mean']
    print('ENVELOPE',json.dumps(summary),flush=True)
    return {'summary':summary,'mean_runtime_ratio':speedup,'numerically_equivalent_frontends':False,
            'scope':'feature extraction only; excludes separation, capture, task queue and display',
            'differences':['historical carrier1400..4600Hz vs current2200..4600Hz',
                          'historical short-window averaged envelope vs current full1.024s envelope',
                          'different filters, peak tolerance and normalization floor; models require matching feature contract'],
            'current_vs_independent_analytic_DFT_max_abs_amplitude_error':error,'DFT_not_timed':True,
            'input_sha256':sha(path),'input_samples':40000,'input_rate_hz':fs,'shaft_hz':shaft,
            'observation_seconds':1.024,'features':features}

def main():
    a=argparse.ArgumentParser(description=__doc__)
    a.add_argument('--output',type=Path);a.add_argument('--warmup',type=int,default=5)
    a.add_argument('--search-repeats',type=int,default=41);a.add_argument('--division-repeats',type=int,default=101)
    a.add_argument('--envelope-repeats',type=int,default=31);a.add_argument('--skip-envelope',action='store_true')
    args=a.parse_args()
    if min(args.warmup,args.search_repeats,args.division_repeats,args.envelope_repeats)<1: a.error('positive counts required')
    out=(args.output or HERE/('run_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))).resolve()
    if not out.is_relative_to(HERE): a.error('output must remain under performance_comparison/ps_software')
    if out.exists(): a.error('output directory already exists; preserve previous measurements')
    for sub in ('inputs','build','logs','numeric'): (out/sub).mkdir(parents=True,exist_ok=True)
    run_log=(out/'logs/run.log').open('w',encoding='utf-8',buffering=1)
    sys.stdout=Tee(sys.stdout,run_log);sys.stderr=Tee(sys.stderr,run_log)
    env=dict(os.environ);env['PATH']=str(GCC.parent)+os.pathsep+env.get('PATH','')
    dll_cookie=os.add_dll_directory(str(GCC.parent)) if hasattr(os,'add_dll_directory') else None
    before=source_hashes();commands=[];rows=[]
    cpu=platform.processor()
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,r'HARDWARE\DESCRIPTION\System\CentralProcessor\0') as key:
            cpu=winreg.QueryValueEx(key,'ProcessorNameString')[0]
    except (ImportError,OSError): pass
    tools={}
    for name,path in [('gcc',GCC),('python',Path(sys.executable))]:
        p=subprocess.run([str(path),'--version'],env=env,text=True,capture_output=True)
        tools[name]={'path':str(path),'sha256':sha(path),'version':(p.stdout+p.stderr).strip()}
    for name in ('cc1','as','ld'):
        p=subprocess.run([str(GCC),'-print-prog-name='+name],env=env,text=True,capture_output=True)
        candidate=Path(p.stdout.strip())
        if not candidate.is_absolute(): candidate=GCC.parent/candidate
        if candidate.exists():tools[name]={'path':str(candidate.resolve()),'sha256':sha(candidate)}
    report={'schema':'PS_HOST_PERFORMANCE_V1','started_utc':datetime.now(timezone.utc).isoformat(),
            'scope':'Windows x86_64 native host; NOT Cortex-A9/ARM, NOT FPGA, NOT three-architecture system speedup',
            'host':{'platform':platform.platform(),'machine':platform.machine(),'processor':cpu,'logical_cpus':os.cpu_count()},
            'tools':tools,'flags_common':['-std=c11','-O2','-shared','no -ffast-math','no -march=native'],
            'timer':'QueryPerformanceCounter inside native C; Python/ctypes entry, process launch, file I/O excluded',
            'warmup_calls_excluded':args.warmup,'ordering':'seeded shuffled variant order in each measured round, one process',
            'additional_pre_warmup_validation_calls_per_variant':1,
            'cache_scope':'steady-state after warmup; no forced cache flush or frequency lock',
            'source_hashes_before':before,'requested_counts':vars(args)|{'output':str(out)},'commands':commands}
    report['requested_counts']['output']=str(out)
    print('OUTPUT',out,flush=True)
    try:
        report['search']=measure_search(out,args,commands,env,rows)
        report['division']=measure_division(out,args,commands,env,rows)
        if not args.skip_envelope:report['envelope']=measure_envelope(out,args,commands,env,rows)
        after=source_hashes();report['source_hashes_after']=after
        assert before==after,'production inputs changed while benchmarking'
        report['source_unchanged']=True;report['passed']=True
    except Exception as error:
        report['passed']=False;report['error']=repr(error);raise
    finally:
        report['finished_utc']=datetime.now(timezone.utc).isoformat()
        with (out/'raw_timings.csv').open('w',newline='',encoding='utf-8') as f:
            writer=csv.writer(f);writer.writerow(['benchmark','fixture','variant','iteration','order_in_round','wall_ms']);writer.writerows(rows)
        report['artifact_hashes']={str(p.relative_to(out)).replace('\\','/'):sha(p) for p in sorted(out.rglob('*')) if p.is_file() and p.name not in ('results.json','run.log')}
        report['benchmark_sources']={p.name:sha(p) for p in HERE.iterdir() if p.is_file() and p.suffix in ('.py','.c')}
        dump_json(out/'results.json',report)
    print('PASS',out/'results.json',flush=True)
    report['artifact_hashes']['logs/run.log']=sha(out/'logs/run.log')
    dump_json(out/'results.json',report)

if __name__=='__main__':main()
