"""Full gsc9_process and production same-snapshot separation on Windows x86-64."""
import argparse
import array
import csv
import ctypes as C
from datetime import datetime,timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import random
import re
import subprocess
import sys
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import run_benchmarks as common
PROJECT=common.PROJECT

def load_module(name,path):
 spec=importlib.util.spec_from_file_location(name,path);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod
def bytes_arg(path):return os.fsencode(path)

def gsc_inputs(out,reuse):
 names=['gsc_packets.u32le','gsc_fir.i16le','gsc_expected_active.i16le','gsc_expected_bypass.i16le']
 if reuse:
  import shutil
  for name in names:shutil.copyfile(reuse/'inputs'/name,out/'inputs'/name)
  return
 golden=load_module('gsc_independent_golden',PROJECT/'scripts/check_gsc9.py')
 rng=random.Random(20261028);count=512+32768
 raw=[[int(900*math.sin(2*math.pi*3000*n/156250))+rng.randrange(-1000,1001) for _ in range(9)] for n in range(count)]
 image=(PROJECT/'sw/acoustic_circular9_image.h').read_text(encoding='utf-8')
 match=re.search(r'acoustic_fir_coeff\[32\]\s*=\s*\{([^}]+)',image)
 fir=[int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)u',match[1])];fir=[v-65536 if v>=32768 else v for v in fir]
 assert len(fir)==32
 das,beam,refs=golden.frontend(raw,[0]*9,fir);active=golden.adaptive(beam,refs)
 packets=[]
 for n,row in enumerate(raw):
  w=[0]*16;w[0]=0x47534302;w[1]=n;w[2]=1;w[5]=65536;w[6]=(7<<8)|1
  w[7]=(das[n]&65535)|((beam[n]&65535)<<16);w[13]=0x000a0009
  for ch,v in enumerate(row):w[8+ch//2]|=(v&65535)<<(16*(ch%2))
  packets.extend(w)
 common.binary(out/'inputs'/names[0],'I',packets);common.binary(out/'inputs'/names[1],'h',fir)
 common.binary(out/'inputs'/names[2],'h',active[512:]);common.binary(out/'inputs'/names[3],'h',beam[512:])

def gsc_state(lib):
 names=['packets','active','disabled','warmup','bad_format','seq_errors','lost_packets','overflow_events','meta_mismatch',
 'transitions','align_errors','saturations','coeff_clips','update_frozen','divergence','restarts','ref_clips','input_clips',
 'target_leak_events','target_guard_samples','target_guard_releases']
 state={name:int(lib.full_gsc_stat(i)) for i,name in enumerate(names)}
 weights=(C.c_int32*32)();lib.full_gsc_weights(weights)
 state['weights']=list(weights);state['last_reason']=lib.full_gsc_reason();return state

def separation_state(lib):
 names=['count','frames','usable_bins','total_bins','invalid_input','ready_mask','covariance_frames','covariance_used_bins',
 'carrier_bins','carrier_usable_bins','carrier_max_gap','clipped_output_0','clipped_output_1','protected_rank_min','protected_rank_max']
 s={name:lib.full_sep_metric(i) for i,name in enumerate(names)}
 quality=['target_error','max_null_leakage','max_weight_norm','min_sector_gain','max_sector_gain','max_sector_leakage',
 'energy_0','energy_1','usable_energy_0','usable_energy_1']
 s.update({name:lib.full_sep_quality(i) for i,name in enumerate(quality)});return s

def main():
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=Path)
 ap.add_argument('--inputs-from',type=Path);ap.add_argument('--probe-only',action='store_true')
 ap.add_argument('--repeats',type=int,default=31);ap.add_argument('--warmup',type=int,default=5)
 args=ap.parse_args();assert args.repeats>0 and args.warmup>0
 out=(args.output or HERE/('run_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))).resolve()
 assert out.is_relative_to(HERE) and not out.exists()
 for sub in ['inputs','build','logs','numeric']:(out/sub).mkdir(parents=True)
 log=(out/'logs/run.log').open('w',encoding='utf-8',buffering=1);sys.stdout=common.Tee(sys.stdout,log);sys.stderr=common.Tee(sys.stderr,log)
 env=dict(os.environ);env['PATH']=str(common.GCC.parent)+os.pathsep+env.get('PATH','')
 cookie=os.add_dll_directory(str(common.GCC.parent));commands=[];rows=[];before=common.source_hashes()
 extras={'scripts/check_gsc9.py':common.sha(PROJECT/'scripts/check_gsc9.py')}
 report={'scope':'Windows x86-64 host full modules; not A9/NEON/FPGA/system diagnosis latency',
 'started_utc':datetime.now(timezone.utc).isoformat(),'probe_only':args.probe_only,'repeats':args.repeats,'warmup':args.warmup,
 'timer':'native QueryPerformanceCounter; setup/reset,512-raw-point GSC prefix,files,compilation excluded',
 'commands':commands,'source_hashes_before':before,'independent_oracle_hashes':extras,
 'gcc_sha256':common.sha(common.GCC),'python_sha256':common.sha(Path(sys.executable)),
 'ordering':'seeded random order of GSC modes in each round; separation measured separately; no dropped outliers'}
 print('OUTPUT',out,flush=True)
 try:
  gsc,_=common.compile_library(out,'gsc_full',['full_modules/gsc_full.c'],[],commands,env)
  sep,_=common.compile_library(out,'separation_full',['full_modules/separation_full.c'],[],commands,env)
  gsc.full_gsc_load.argtypes=[C.c_char_p,C.c_char_p];gsc.full_gsc_once.argtypes=[C.c_int,C.POINTER(C.c_double)]
  gsc.full_gsc_dump.argtypes=[C.c_char_p];gsc.full_gsc_stat.argtypes=[C.c_uint];gsc.full_gsc_stat.restype=C.c_uint64
  gsc.full_gsc_weights.argtypes=[C.POINTER(C.c_int32)]
  sep.full_sep_generate.argtypes=[C.c_char_p,C.c_char_p];sep.full_sep_load.argtypes=[C.c_char_p,C.c_char_p]
  sep.full_sep_once.argtypes=[C.POINTER(C.c_double)];sep.full_sep_dump.argtypes=[C.c_char_p,C.c_char_p]
  sep.full_sep_metric.argtypes=[C.c_uint];sep.full_sep_quality.argtypes=[C.c_uint];sep.full_sep_quality.restype=C.c_double
  reuse=args.inputs_from.resolve() if args.inputs_from else None
  if reuse:
   assert reuse.is_relative_to(HERE)
   source=json.loads((reuse/'results.json').read_text(encoding='utf-8'));assert source['passed']
   for name,digest in source['source_hashes_after'].items():assert common.sha(common.WORKSPACE/name)==digest
  gsc_inputs(out,reuse)
  assert gsc.full_gsc_load(bytes_arg(out/'inputs/gsc_packets.u32le'),bytes_arg(out/'inputs/gsc_fir.i16le'))==1
  expected={'disabled_bypass':(out/'inputs/gsc_expected_bypass.i16le').read_bytes(),
            'adaptive_enabled':(out/'inputs/gsc_expected_active.i16le').read_bytes()}
  states={};mode_names=['disabled_bypass','adaptive_enabled']
  for mode,name in enumerate(mode_names):
   ms=C.c_double();assert gsc.full_gsc_once(mode,C.byref(ms))==1
   dest=out/'numeric'/f'gsc_{name}.i16le';assert gsc.full_gsc_dump(bytes_arg(dest))==1
   assert dest.read_bytes()==expected[name],(name,'independent sample mismatch')
   s=gsc_state(gsc);states[name]=s
   assert all(s[k]==0 for k in ['bad_format','seq_errors','meta_mismatch','transitions','align_errors','divergence','target_guard_samples'])
   assert s['packets']==33280
   if mode:assert s['active']==32768 and any(s['weights']) and s['update_frozen']==0 and s['last_reason']==0
   else:assert s['disabled']==33280 and not any(s['weights'])
  assert expected['disabled_bypass']!=expected['adaptive_enabled'],'adaptation must change output'
  report['gsc']={'validation':states,'timed_raw_samples':32768,'raw_rate_hz':156250,'audio_duration_seconds':32768/156250,
   'prefix_raw_samples_excluded':512,'target_guard_enabled':True,'delays_q16':[0]*9,
   'fir':'actual current image32tap coefficients','input':'known common tone plus independent per-sensor noise; synthetic tap records',
   'independent_integer_oracle_sample_exact':True,'same_output_expected_between_modes':False}
  lut=out/'inputs/steer_lut.u32le'
  import shutil
  image=(PROJECT/'sw/acoustic_circular9_image.h').read_text(encoding='utf-8')
  match=re.search(r'static const uint32_t acoustic_steer_lut\[\d+\]\s*=\s*\{(.*?)\};',image,re.S)
  table=[int(v,0) for v in re.findall(r'0x[0-9a-fA-F]+|\d+',match[1])]
  config=json.loads((PROJECT/'configs/circular9_array.json').read_text(encoding='utf-8'))
  builder=load_module('full_module_c9_builder',PROJECT/'scripts/build_circular9.py')
  assert table==builder.geometry(config)[1],'embedded LUT must match current configuration'
  common.binary(lut,'I',table);pcm=out/'inputs/separation_two_sources.pcm'
  cpu=common.platform.processor()
  try:
   import winreg
   with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,r'HARDWARE\DESCRIPTION\System\CentralProcessor\0') as key:cpu=winreg.QueryValueEx(key,'ProcessorNameString')[0]
  except (ImportError,OSError):pass
  report['host']={'platform':common.platform.platform(),'machine':common.platform.machine(),'processor':cpu,'logical_cpus':os.cpu_count()}
  report['gcc_version']=subprocess.check_output([str(common.GCC),'--version'],env=env,text=True).strip()
  report['python_version']=sys.version
  if reuse:
   shutil.copyfile(reuse/'inputs/separation_two_sources.pcm',pcm)
   assert sep.full_sep_load(bytes_arg(lut),bytes_arg(pcm))==1
  else:assert sep.full_sep_generate(bytes_arg(lut),bytes_arg(pcm))==1
  ms=C.c_double();assert sep.full_sep_once(C.byref(ms))==1
  s=separation_state(sep);report['separation']={'validation':s,'candidate_grids':[515,540],
   'raw_frames':160256,'raw_channels':9,'raw_rate_hz':156250,'output_samples_per_candidate':40000,'output_rate_hz':39062.5,
   'fixture':'two deterministic broadband sources with current calibrated-table-compatible quantized steering; NOT physical-source accuracy',
   'timing_scope':'entire production c9_candidates_separate including preparation,8 observations,covariance,target protection,bin solves,WOLA,quality',
   'classifier_and_external_session_validation_included':False}
  assert s['invalid_input']==0 and s['ready_mask']==3 and s['count']==2,('not a valid separation',s)
  assert s['covariance_frames']==8 and s['covariance_used_bins']>0 and s['clipped_output_0']==s['clipped_output_1']==0
  sep_audio=out/'numeric/separation_output.f64le';sep_meta=out/'numeric/separation_report.bin'
  assert sep.full_sep_dump(bytes_arg(sep_audio),bytes_arg(sep_meta))==1
  expected_sep=common.sha(sep_audio);report['separation']['validation_output_sha256']=expected_sep
  print('VALID_GSC',json.dumps(states),flush=True);print('VALID_SEPARATION',json.dumps(s),flush=True)
  if not args.probe_only:
   data={name:[] for name in mode_names}
   for mode in (0,1):
    for _ in range(args.warmup):assert gsc.full_gsc_once(mode,C.byref(ms))==1
   rng=random.Random(515)
   for iteration in range(args.repeats):
    order=[0,1];rng.shuffle(order)
    for position,mode in enumerate(order):
     assert gsc.full_gsc_once(mode,C.byref(ms))==1
     data[mode_names[mode]].append(ms.value);rows.append(['gsc',mode_names[mode],iteration,position,ms.value])
   report['gsc']['summary']={name:common.summarize(t) for name,t in data.items()}
   for _ in range(args.warmup):assert sep.full_sep_once(C.byref(ms))==1
   values=[]
   for iteration in range(args.repeats):
    assert sep.full_sep_once(C.byref(ms))==1
    values.append(ms.value);rows.append(['separation','two_candidates_production',iteration,0,ms.value])
   report['separation']['summary']=common.summarize(values)
   assert sep.full_sep_dump(bytes_arg(sep_audio),bytes_arg(sep_meta))==1
   assert common.sha(sep_audio)==expected_sep,'separation changed between repeated calls'
   assert separation_state(sep)==s,'quality report changed between repeated calls'
   print('TIMING_GSC',json.dumps(report['gsc']['summary']),flush=True)
   print('TIMING_SEPARATION',json.dumps(report['separation']['summary']),flush=True)
  after=common.source_hashes();assert after==before
  for name,digest in extras.items():assert common.sha(PROJECT/name)==digest
  report['source_hashes_after']=after;report['source_unchanged']=True;report['passed']=True
 except Exception as error:
  report['passed']=False;report['error']=repr(error);raise
 finally:
  report['finished_utc']=datetime.now(timezone.utc).isoformat()
  with (out/'raw_timings.csv').open('w',newline='',encoding='utf-8') as f:
   wr=csv.writer(f);wr.writerow(['module','mode','iteration','order_in_round','wall_ms']);wr.writerows(rows)
  report['benchmark_sources']={p.name:common.sha(p) for p in HERE.iterdir() if p.suffix in ('.py','.c')}
  report['shared_runner_sha256']=common.sha(HERE.parent/'run_benchmarks.py')
  report['artifact_hashes']={str(p.relative_to(out)).replace('\\','/'):common.sha(p) for p in out.rglob('*') if p.is_file() and p.name not in ('results.json','run.log')}
  common.dump_json(out/'results.json',report)
 print('PASS',out/'results.json',flush=True)
 report['artifact_hashes']['logs/run.log']=common.sha(out/'logs/run.log');common.dump_json(out/'results.json',report)

if __name__=='__main__':main()
