# Simulation only: real FSTF recordings propagated as far-field plane waves.
from pathlib import Path
import numpy as np,json,wave,hashlib,subprocess,itertools,math,time,argparse
R=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--scenes',type=Path);ap.add_argument('--output',type=Path);args=ap.parse_args()
O=args.output.resolve() if args.output else R/'build/fstf_integration_20261027';O.mkdir(parents=True,exist_ok=True)
# Build the actual adapter/task harness on every run; never reuse a stale executable.
cc=r'D:\winlibs\mingw64\bin\gcc.exe'
inc=R/'build/circular9_pipeline_checks/include'
if not (inc/'xtime_l.h').exists():
 import sys
 subprocess.run([sys.executable,str(R/'scripts/check_circular9_pipeline.py')],cwd=R,check=True)
subprocess.run([cc,'-std=c11','-O2','-DC9_CANDIDATES_TEST','-DC9_FSTF_EXPERIMENTAL=1','-I'+str(inc),'-Isw','sw/circular9_candidates.c','sw/circular9_diagnosis.c','sw/circular9_fstf_e2e_test.c','-pthread','-lm','-o',str(O/'fstf_e2e.exe')],cwd=R,check=True)
DATA=Path(r'F:\RISC-V\26fpga创新设计赛道\测试音频\FSTF_1800rpm_6_fault_types_WAV');labels=['inner','outer','ball','healthy','looseness','combined'];waves={};wave_manifest={}
assert len(list(DATA.glob('*.wav')))==6
for label,p in zip(labels,sorted(DATA.glob('*.wav'))):
 with wave.open(str(p)) as f:assert f.getframerate()==48000 and f.getnchannels()==1 and f.getsampwidth()==2;waves[label]=np.frombuffer(f.readframes(f.getnframes()),'<i2').astype(float)/32768
 wave_manifest[label]={'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
cfg=json.loads((R/'configs/circular9_array.json').read_text());xyz=np.array(cfg['channel_positions_m']);N=400000;IN=122880;freq=np.fft.rfftfreq(N,1/156250);rng=np.random.default_rng(20261027)
def segment(label,start):
 x=waves[label];ids=np.arange(round(start*48000),round(start*48000)+IN);return x[ids%len(x)],bool(ids[-1]>=len(x))
def source(label,az,rms=.04):return {'label':label,'azimuth_deg':az,'elevation_deg':0,'rms':rms,'start_s':0 if label=='outer' else 15.36 if label in ('inner','ball') else 7.168}
scenes=[{'name':'single_'+label,'sources':[source(label,0)]} for label in labels]
scenes +=[{'name':'dual_normal_inner','sources':[source('healthy',-50),source('inner',50)]},{'name':'dual_swap_inner_normal','sources':[source('inner',-50),source('healthy',50)]},{'name':'dual_loud_normal_weak_ball','sources':[source('healthy',-50,.08),source('ball',50,.02)]}]
if args.scenes:scenes=json.loads(args.scenes.read_text(encoding='utf8'))
results=[]
for scene in scenes:
 name=scene['name'];mix=rng.normal(0,scene.get('noise_rms',.00003),(N,9));provenance=[]
 for source_index,src in enumerate(scene['sources']):
  x,looped=segment(src['label'],src['start_s']);x=x*(src['rms']/np.sqrt(np.mean(x*x)));spec=np.fft.rfft(x);base=np.zeros(N//2+1,complex);base[:len(spec)]=spec*(N/IN);base[len(spec)-1]*=.5
  a=np.deg2rad(src['azimuth_deg']);e=np.deg2rad(src['elevation_deg']);u=np.array([np.cos(e)*np.sin(a),np.sin(e),np.cos(e)*np.cos(a)]);arrival=-(xyz@u)/343
  for ch in range(9):mix[:,ch]+=np.fft.irfft(base*np.exp(-2j*np.pi*freq*arrival[ch]),n=N)
  for echo in scene.get('reflections',[]):
   if echo['source_index']!=source_index:continue
   ea=np.deg2rad(echo['azimuth_deg']);eu=np.array([np.sin(ea),0,np.cos(ea)]);et=-(xyz@eu)/343+echo['delay_s']
   for ch in range(9):mix[:,ch]+=echo['gain']*np.fft.irfft(base*np.exp(-2j*np.pi*freq*et[ch]),n=N)
  provenance.append({**src,'source_wav':wave_manifest[src['label']],'looped_for_simulation':looped,'heldout_within_recording':src['label']!='outer','recording_disjoint':False})
 maximum=float(np.max(abs(mix)));clipped=int(np.sum((mix>32767/32768)|(mix< -1)))
 pcm=np.clip(np.rint(mix*32768),-32768,32767).astype('<i2');path=O/(name+'.pcm');pcm.tofile(path);output=O/(name+'.json');start=time.perf_counter()
 p=subprocess.run([str(O/'fstf_e2e.exe'),str(path),str(N),str(output),','.join(str(s['azimuth_deg']) for s in scene['sources'])],cwd=R,text=True,capture_output=True);(O/(name+'.log')).write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(name+': '+p.stdout+p.stderr)
 d=json.loads(output.read_text());out=[]
 for c in d['candidates']:
  az=c['azimuth_mdeg']/1000;el=c['elevation_mdeg']/1000;near=min(provenance,key=lambda s:abs(s['azimuth_deg']-az));diag=c['diagnosis'];exp=diag.get('fstf_experimental',{});out.append({'track_id':c['track_id'],'azimuth_deg':az,'elevation_deg':el,'nearest_truth_label':near['label'],'nearest_truth_angle_error_deg':abs(az-near['azimuth_deg']),'experimental':exp,'trusted_label':diag['label'],'fault_direction_valid':diag['fault_direction_valid'],'stale':c['stale'],'separation_ready':c['separation_ready']})
  assert diag['label']=='unknown' and diag['fault_direction_valid']==0
  assert exp.get('validated',0)==0
  # Verify raw API contract, not a synthetic replacement status object.
  assert diag['binding']['track_id']==c['track_id'] and diag['binding']['sample_count']==40000
 entry={'scene':name,'scenario_parameters':scene,'simulated_clipped_samples':clipped,'peak_before_quantization':maximum,'sources':provenance,'pcm_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'snapshot_sequence':d['sequence'],'candidates':out,'proposals':d['proposals'],'scheduler':d['diagnostic_scheduler'],'eligibility':d.get('diagnostic_eligibility'),'host_elapsed_s':time.perf_counter()-start,'source':'simulated_plane_wave_PCM_from_FSTF','hardware_tested':False,'host_mock_clock_metrics_not_real_timing':True};entry['known_direction_control']=json.loads(Path(str(output)+'.known_direction_control.json').read_text());results.append(entry)
 print('SCENE',name,'snapshot',d['sequence'],'outputs',[(round(c['azimuth_deg'],2),c['experimental'].get('label'),c['separation_ready']) for c in out],flush=True)
(O/'e2e_results.json').write_text(json.dumps({'simulation_only':True,'seed':20261027,'rate_hz':156250,'duration_s':2.56,'propagation':'far field phase-shift of bandlimited FFT resample; no PDM/RTL; optional declared delayed reflections; no measured room impulse response','noise_rms':.00003,'classification_truth_only_used_for_evaluation':True,'cases':results},indent=2))
print('FSTF_E2E_RUN_COMPLETE cases='+str(len(results)))
