"""Read-only analysis of recorded simulations; no retraining or board access."""
from pathlib import Path
import json,ctypes,hashlib,subprocess
import numpy as np
from c9_scene_evaluation import angle,match
R=Path(__file__).resolve().parents[1];O=R/'build/offline_followup_20261027';O.mkdir(exist_ok=True)
roots=[R/'build/fstf_integration_20261027',R/'build/offline_multisource_20261027/stress',O/'robustness']
labels=['inner','outer','ball','healthy','looseness','combined'];counts={'centroid':0,'forest':0,'evaluated':0};comparisons=[];stages=[]
# Recompile current production feature extractor, leaving model weights fixed.
src=O/'extract.c';src.write_text('#include "circular9_diagnosis.h"\n#include <string.h>\n__declspec(dllexport) void extract(const double *x,double *v){c9_diag_report r;c9_diagnose(x,30,0,&r);memcpy(v,r.features,18*sizeof(double));}\n')
subprocess.run([r'D:\winlibs\mingw64\bin\gcc.exe','-std=c11','-O2','-shared','-static-libgcc','-Isw',str(src),'sw/circular9_diagnosis.c','-lm','-o',str(O/'extract.dll')],cwd=R,check=True)
pointer=ctypes.POINTER(ctypes.c_double)
extract=ctypes.CDLL(str(O/'extract.dll'));extract.extract.argtypes=[pointer,pointer]
cent=ctypes.CDLL(str(R/'build/fstf_training_20261027/predict.dll'));cent.predict.argtypes=[pointer,pointer];cent.predict.restype=ctypes.c_int
rf=ctypes.CDLL(str(R/'build/fstf_training_20261027/forest_predict.dll'));rf.predict.argtypes=[pointer,ctypes.POINTER(ctypes.c_uint32)];rf.predict.restype=ctypes.c_int
for root in roots:
 data=json.loads((root/'e2e_results.json').read_text())
 for case in data['cases']:
  name=case['scene'];sources=case['sources'];trace=[json.loads(s) for s in Path(str(root/(name+'.json'))+'.trace.jsonl').read_text().splitlines()]
  for si,truth in enumerate(sources):
   def near(p):return angle({'azimuth_deg':p['az']/1000,'elevation_deg':p['el']/1000},truth)<12
   stage={'suite':str(root.relative_to(R)),'scene':name,'source_index':si,'label':truth['label'],'windows':len(trace)}
   stage['any_band_peak_near']=sum(any(near(p) for b in t['bands'] for p in b) for t in trace)
   stage['direct_supported_peak_near']=sum(any(near(p) and p['quality']>=3 and p['support']>=3 for b in t['bands'] for p in b) for t in trace)
   stage['selected_near']=sum(any(near(p) for p in t['selected']) for t in trace)
   stage['observed_track_near']=sum(any(near(p) and p['state']==1 for p in t['tracks']) for t in trace)
   stage['final_current_ready_near']=sum(angle(p,truth)<12 and not p['stale'] and p['separation_ready'] for p in case['candidates'])
   stage['known_direction_control']=case['known_direction_control'];stages.append(stage)
  outputs=case['candidates'];current=[(i,v) for i,v in enumerate(outputs) if not v['stale'] and v['separation_ready']]
  pairs=match([v for _,v in current],sources)
  for pair in pairs:
   i,v=current[pair['output']];f=Path(str(root/(name+'.json'))+f'.audio{i}.f64')
   x=np.fromfile(f,dtype=np.float64);assert len(x)==40000
   features=np.zeros(18);extract.extract(x.ctypes.data_as(pointer),features.ctypes.data_as(pointer));assert np.isfinite(features).all()
   distances=np.zeros(6);votes=np.zeros(6,np.uint32)
   c=cent.predict(features.ctypes.data_as(pointer),distances.ctypes.data_as(pointer));r=rf.predict(features.ctypes.data_as(pointer),votes.ctypes.data_as(ctypes.POINTER(ctypes.c_uint32)))
   truth=sources[pair['source']]['label'];counts['evaluated']+=1;counts['centroid']+=labels[c]==truth;counts['forest']+=labels[r]==truth
   comparisons.append({'suite':str(root.relative_to(R)),'scene':name,'source_index':pair['source'],'truth':truth,'centroid':labels[c],'forest':labels[r],'forest_votes':votes.tolist(),'angle_error_deg':pair['error_deg'],'audio_sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
result={'simulation_only':True,'recording_disjoint':False,'no_retraining':True,'metrics_conditional_on_current_ready_and_matched_direction':True,'counts':counts,'comparison':comparisons,'stages':stages,'source_sha256':{n:hashlib.sha256((R/n).read_bytes()).hexdigest() for n in ['scripts/run_fstf_c9_e2e.py','scripts/c9_scene_evaluation.py','sw/circular9_candidates.c','sw/circular9_timing_model_test.c','sw/circular9_fstf_e2e_test.c']}}
(O/'failure_and_model_audit.json').write_text(json.dumps(result,indent=2));print('FOLLOWUP_AUDIT_COMPLETE',counts)
for s in stages:
 if s['scene'] in ['angle_15','angle_30','angle_70','dual_loud_normal_weak_ball','three_sources']:
  print(s['scene'],s['label'],'peaks',s['any_band_peak_near'],'selected',s['selected_near'],'observed',s['observed_track_near'],'of',s['windows'])
