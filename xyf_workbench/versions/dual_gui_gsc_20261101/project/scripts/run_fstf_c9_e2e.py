# Simulation only: real FSTF recordings propagated as far-field plane waves.
from pathlib import Path
import numpy as np,json,wave,hashlib,subprocess,itertools,math,time,argparse
from c9_scene_evaluation import angle,match,direction
R=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser();ap.add_argument('--scenes',type=Path);ap.add_argument('--output',type=Path);ap.add_argument('--duration-s',type=float,default=2.56);ap.add_argument('--seed',type=int,default=20261027);ap.add_argument('--candidate-source',type=Path,default=R/'sw/circular9_candidates.c');args=ap.parse_args()
assert 1.1<=args.duration_s<=60
O=args.output.resolve() if args.output else R/'build/fstf_integration_20261027';O.mkdir(parents=True,exist_ok=True)
# Build the actual adapter/task harness on every run; never reuse a stale executable.
cc=r'D:\winlibs\mingw64\bin\gcc.exe'
inc=R/'build/circular9_pipeline_checks/include'
if not (inc/'xtime_l.h').exists():
 import sys
 subprocess.run([sys.executable,str(R/'scripts/check_circular9_pipeline.py')],cwd=R,check=True)
subprocess.run([cc,'-std=c11','-O2','-DC9_CANDIDATES_TEST','-DC9_FSTF_EXPERIMENTAL=1','-I'+str(inc),'-Isw',str(args.candidate_source),'sw/circular9_diagnosis.c','sw/circular9_fstf_e2e_test.c','-pthread','-lm','-o',str(O/'fstf_e2e.exe')],cwd=R,check=True)
DATA=Path(r'F:\RISC-V\26fpga创新设计赛道\测试音频\FSTF_1800rpm_6_fault_types_WAV');labels=['inner','outer','ball','healthy','looseness','combined'];waves={};wave_manifest={}
assert len(list(DATA.glob('*.wav')))==6
for label,p in zip(labels,sorted(DATA.glob('*.wav'))):
 with wave.open(str(p)) as f:assert f.getframerate()==48000 and f.getnchannels()==1 and f.getsampwidth()==2;waves[label]=np.frombuffer(f.readframes(f.getnframes()),'<i2').astype(float)/32768
 wave_manifest[label]={'path':str(p),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
cfg=json.loads((R/'configs/circular9_array.json').read_text());xyz=np.array(cfg['channel_positions_m']);N=round(156250*args.duration_s);IN=round(48000*args.duration_s);freq=np.fft.rfftfreq(N,1/156250);rng=np.random.default_rng(args.seed)
def segment(label,start):
 x=waves[label];ids=np.arange(round(start*48000),round(start*48000)+IN);return x[ids%len(x)],bool(ids[-1]>=len(x))
def source(label,az,rms=.04):return {'label':label,'azimuth_deg':az,'elevation_deg':0,'rms':rms,'start_s':0 if label=='outer' else 15.36 if label in ('inner','ball') else 7.168}
scenes=[{'name':'single_'+label,'sources':[source(label,0)]} for label in labels]
scenes +=[{'name':'dual_normal_inner','sources':[source('healthy',-50),source('inner',50)]},{'name':'dual_swap_inner_normal','sources':[source('inner',-50),source('healthy',50)]},{'name':'dual_loud_normal_weak_ball','sources':[source('healthy',-50,.08),source('ball',50,.02)]}]
if args.scenes:scenes=json.loads(args.scenes.read_text(encoding='utf8'))
results=[]
for scene in scenes:
 receiver_xyz=np.asarray(scene.get('receiver_positions_m',xyz),dtype=float);assert receiver_xyz.shape==(9,3) and np.isfinite(receiver_xyz).all()
 name=scene['name'];mix=rng.normal(0,scene.get('noise_rms',.00003),(N,9));provenance=[]
 for source_index,src in enumerate(scene['sources']):
  x,looped=segment(src['label'],src['start_s'])
  synthetic=src.get('synthetic_kind')=='fan_like'
  if synthetic:
   t=np.arange(IN)/48000;tones=sum(np.sin(2*np.pi*h*t+rng.uniform(0,2*np.pi))/(1+i*.3) for i,h in enumerate([360,720,1080,1440,1800]));noise=rng.normal(size=IN);ns=np.fft.rfft(noise);ff=np.fft.rfftfreq(IN,1/48000);ns[(ff<150)|(ff>2100)]=0;x=tones+.3*np.fft.irfft(ns,n=IN);looped=False
  x=x*(src['rms']/np.sqrt(np.mean(x*x)));spec=np.fft.rfft(x);base=np.zeros(N//2+1,complex);base[:len(spec)]=spec*(N/IN);base[len(spec)-1]*=.5
  if src.get('active_intervals_s'):
   signal=np.fft.irfft(base,n=N);times=np.arange(N)/156250;envelope=np.zeros(N)
   for begin,end in src['active_intervals_s']:
    assert 0<=begin<end<=args.duration_s
    envelope=np.maximum(envelope,np.clip((times-begin)/.005,0,1)*np.clip((end-times)/.005,0,1))
   base=np.fft.rfft(signal*envelope)
  a=np.deg2rad(src['azimuth_deg']);e=np.deg2rad(src['elevation_deg']);u=np.array([np.cos(e)*np.sin(a),np.sin(e),np.cos(e)*np.cos(a)]);arrival=-(receiver_xyz@u)/343
  if scene.get("distance_m"):
   point=u*scene["distance_m"];distance=np.linalg.norm(receiver_xyz-point,axis=1);arrival=(distance-scene["distance_m"])/343
  else:distance=np.ones(9)
  if src.get('trajectory'):
   times=np.arange(N)/156250;knots=src['trajectory'];aa=np.deg2rad(np.interp(times,[k['time_s'] for k in knots],[k['azimuth_deg'] for k in knots]));ee=np.deg2rad(np.interp(times,[k['time_s'] for k in knots],[k.get('elevation_deg',0) for k in knots]));uu=np.stack([np.cos(ee)*np.sin(aa),np.sin(ee),np.cos(ee)*np.cos(aa)],axis=1);signal=np.fft.irfft(base,n=N);indices=np.arange(N)
   for ch in range(9):
    tau=-(uu@receiver_xyz[ch])/343;mix[:,ch]+=np.interp((indices-tau*156250)%N,indices,signal,period=N)
  else:
   for ch in range(9):mix[:,ch]+=(scene["distance_m"]/distance[ch] if scene.get("distance_m") else 1)*np.fft.irfft(base*np.exp(-2j*np.pi*freq*arrival[ch]),n=N)
  for echo in scene.get('reflections',[]):
   if echo['source_index']!=source_index:continue
   ea=np.deg2rad(echo['azimuth_deg']);eu=np.array([np.sin(ea),0,np.cos(ea)]);et=-(receiver_xyz@eu)/343+echo['delay_s']
   for ch in range(9):mix[:,ch]+=echo['gain']*np.fft.irfft(base*np.exp(-2j*np.pi*freq*et[ch]),n=N)
  provenance.append({**src,'source_wav':None if synthetic else wave_manifest[src['label']], 'synthetic_fan_not_measured':synthetic,'looped_for_simulation':looped,'heldout_within_recording':not synthetic and src['label']!='outer','recording_disjoint':False})
 for ch in range(9):
  gain=scene.get('channel_gain',[1]*9)[ch];delay=scene.get('channel_delay_us',[0]*9)[ch]*1e-6
  mix[:,ch]=gain*np.fft.irfft(np.fft.rfft(mix[:,ch])*np.exp(-2j*np.pi*freq*delay),n=N)
 maximum=float(np.max(abs(mix)));clipped=int(np.sum((mix>32767/32768)|(mix< -1)))
 pcm=np.clip(np.rint(mix*32768),-32768,32767).astype('<i2');path=O/(name+'.pcm');pcm.tofile(path);output=O/(name+'.json');start=time.perf_counter()
 p=subprocess.run([str(O/'fstf_e2e.exe'),str(path),str(N),str(output),','.join(str(s['azimuth_deg'])+':'+str(s.get('elevation_deg',0)) for s in scene['sources'])],cwd=R,text=True,capture_output=True);(O/(name+'.log')).write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(name+': '+p.stdout+p.stderr)
 d=json.loads(output.read_text());out=[]
 for c in d['candidates']:
  az=c['azimuth_mdeg']/1000;el=c['elevation_mdeg']/1000;near=min(provenance,key=lambda s:angle({'azimuth_deg':az,'elevation_deg':el},s));diag=c['diagnosis'];exp=diag.get('fstf_experimental',{});out.append({'track_id':c['track_id'],'azimuth_deg':az,'elevation_deg':el,'nearest_truth_label':near['label'],'nearest_truth_angle_error_deg':angle({'azimuth_deg':az,'elevation_deg':el},near),'experimental':exp,'trusted_label':diag['label'],'fault_direction_valid':diag['fault_direction_valid'],'stale':c['stale'],'separation_ready':c['separation_ready']})
  assert diag['label']=='unknown' and diag['fault_direction_valid']==0
  assert exp.get('validated',0)==0
  # Verify raw API contract, not a synthetic replacement status object.
  assert diag['binding']['track_id']==c['track_id'] and diag['binding']['sample_count']==40000
 current=[v for v in out if not v['stale'] and v['separation_ready']]
 assignment=match(current,provenance)
 entry={'one_to_one_matches':assignment,'matched_sources':len(assignment),'all_sources_localized':len(assignment)==len(provenance),'all_sources_classified':len(assignment)==len(provenance) and all(current[v['output']]['experimental'].get('label')==provenance[v['source']]['label'] for v in assignment),'scene':name,'scenario_parameters':scene,'simulated_clipped_samples':clipped,'peak_before_quantization':maximum,'sources':provenance,'pcm_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'snapshot_sequence':d['sequence'],'candidates':out,'proposals':d['proposals'],'scheduler':d['diagnostic_scheduler'],'eligibility':d.get('diagnostic_eligibility'),'host_elapsed_s':time.perf_counter()-start,'source':'simulated_plane_wave_PCM_from_FSTF','hardware_tested':False,'host_mock_clock_metrics_not_real_timing':True};entry['known_direction_control']=json.loads(Path(str(output)+'.known_direction_control.json').read_text());results.append(entry)
 print('SCENE',name,'snapshot',d['sequence'],'outputs',[(round(c['azimuth_deg'],2),c['experimental'].get('label'),c['separation_ready']) for c in out],flush=True)
(O/'e2e_results.json').write_text(json.dumps({'candidate_source_sha256':hashlib.sha256(args.candidate_source.read_bytes()).hexdigest(),'simulation_only':True,'seed':args.seed,'rate_hz':156250,'duration_s':args.duration_s,'propagation':'FFT fractional-delay propagation; optional spherical near field, declared interpolated trajectories, gain/delay errors and reflections; no PDM/RTL or measured room impulse response','noise_rms':.00003,'classification_truth_only_used_for_evaluation':True,'cases':results},indent=2))
print('FSTF_E2E_RUN_COMPLETE cases='+str(len(results)))
