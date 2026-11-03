"""Offline-only FSTF baseline. No board access, no production model override.
Uses production C9F2 C extractor; blocked time splits are not recording-disjoint.
"""
from pathlib import Path
import ctypes,hashlib,json,os,subprocess,wave,math,csv
import numpy as np
R=Path(__file__).resolve().parents[1]
SOURCE=Path(r'F:\RISC-V\26fpga创新设计赛道\测试音频\FSTF_1800rpm_6_fault_types_WAV')
O=R/'build/fstf_training_20261027';O.mkdir(exist_ok=True)
GCC=Path(r'D:\winlibs\mingw64\bin\gcc.exe')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
labels=['inner','outer','ball','healthy','looseness','combined']
wrapper=O/'extract.c'
wrapper.write_text('#include "circular9_envelope.h"\n__declspec(dllexport) int extract(const double *x,double *v,double *meta){c9_diag_extraction e;int ok=c9_env_extract(x,30.0,v,&e);meta[0]=e.status;meta[1]=e.carrier_rms;meta[2]=e.modulation_rms;meta[3]=e.fft_count;return ok;}\n')
cmd=[str(GCC),'-O2','-shared','-static-libgcc','-Isw',str(wrapper),'-o',str(O/'extract.dll'),'-lm']
p=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/'compile.log').write_text(p.stdout+p.stderr);p.check_returncode()
lib=ctypes.CDLL(str(O/'extract.dll'));ptr=ctypes.POINTER(ctypes.c_double);lib.extract.argtypes=[ptr,ptr,ptr];lib.extract.restype=ctypes.c_int
# Windowed sinc rational resampling: explicit anti-alias low-pass and DC unity.
# No per-recording renormalization. Fs_out=78125/2 exactly; phase period625.
def resample(x,fs):
 target=39062.5;n=int(math.floor(len(x)*target/fs));out=np.empty(n);half=64;cut=.45*min(1,target/fs);taps=np.arange(-half,half+1);cache={}
 for start in range(0,n,8192):
  ids=np.arange(start,min(start+8192,n));pos=ids*fs/target;ix=np.floor(pos).astype(int);frac=pos-ix
  # fractional phase keyed by exact integer remainder, not accumulated floating time
  delta=taps[None,:]-frac[:,None];w=2*cut*np.sinc(2*cut*delta)*np.where(abs(delta)<=half,.5+.5*np.cos(np.pi*delta/half),0);w/=w.sum(axis=1,keepdims=True)
  out[start:start+len(ids)]=(x[np.clip(ix[:,None]+taps[None,:],0,len(x)-1)]*w).sum(axis=1)
 return out
records=[];audit=[]
for ci,path in enumerate(sorted(SOURCE.glob('*.wav'))):
 with wave.open(str(path)) as w:
  fs=w.getframerate();assert w.getnchannels()==1 and w.getsampwidth()==2;b=w.readframes(w.getnframes())
 x=np.frombuffer(b,dtype='<i2').astype(float)/32768.;duration=len(x)/fs;y=resample(x,fs);available=len(y)/39062.5
 audit.append({'label':labels[ci],'file':str(path),'sha256':sha(path),'sample_rate_hz':fs,'seconds':duration,'peak':float(abs(x).max()),'rms':float(np.sqrt(np.mean(x*x))),'rpm':1800,'rpm_source':'user_confirmed_all_files','label_source':'filename; independent original label audit pending'})
 if duration<4.096:parts=[('train',0,available)]
 else:
  unit=1.024;train_end=math.floor(duration*.5/unit)*unit;val_begin=train_end+unit;val_end=val_begin+max(1,math.floor(duration*.15/unit))*unit;test_begin=val_end+unit
  parts=[('train',0,train_end),('validation',val_begin,min(val_end,available)),('test',test_begin,available)]
 for split,begin,end in parts:
  step=.512 if split=='train' else 1.024;start=begin
  while start+1.024<=end+1e-9:
   i=round(start*39062.5);a=np.ascontiguousarray(y[i:i+40000]);assert len(a)==40000;v=np.zeros(18);meta=np.zeros(4)
   ok=lib.extract(a.ctypes.data_as(ptr),v.ctypes.data_as(ptr),meta.ctypes.data_as(ptr));assert ok and np.isfinite(v).all()
   records.append({'label':labels[ci],'class':ci,'split':split,'start_s':start,'end_s':start+1.024,'source_sha256':sha(path),'features':v.tolist(),'extraction_status':int(meta[0]),'carrier_rms':meta[1],'modulation_rms':meta[2]});start+=step
 print('EXTRACTED',path.name,'windows',sum(z['class']==ci for z in records),flush=True)
# Assert split intervals do not overlap and have >=1.024s guard within each file.
for ci in range(6):
 for a in records:
  if a['class']!=ci:continue
  for b in records:
   if b['class']==ci and a['split']!=b['split']:
    assert max(a['start_s'],b['start_s'])-min(a['end_s'],b['end_s'])>=1.024-1e-8
train=[z for z in records if z['split']=='train'];X=np.array([z['features'] for z in train]);Y=np.array([z['class'] for z in train]);center=np.array([X[Y==i].mean(0) for i in range(6)]);scale=np.maximum(X.std(0),1.)
def predict(v):
 d=np.mean(((np.array(v)-center)/scale)**2,axis=1);return int(d.argmin()),d
metrics={}
for split in ['train','validation','test']:
 rows=[z for z in records if z['split']==split];cm=np.zeros((6,6),int)
 for z in rows:
  pr,dist=predict(z['features']);z['predicted_class']=pr;z['distances']=dist.tolist();cm[z['class'],pr]+=1
 supported=np.where(cm.sum(1)>0)[0];recall=[cm[i,i]/cm[i].sum() for i in supported]
 metrics[split]={'windows':len(rows),'confusion_matrix':cm.tolist(),'accuracy':float(np.trace(cm)/cm.sum()) if cm.sum() else None,'balanced_accuracy_supported_classes':float(np.mean(recall)) if recall else None,'supported_classes':[labels[i] for i in supported],'missing_classes':[labels[i] for i in range(6) if i not in supported]}
model={'schema':'FSTF_C9F2_OFFLINE_NEAREST_CENTROID_V1','version':1,'feature_contract':'C9F2','sample_rate_hz':39062.5,'samples':40000,'shaft_hz':30,'class_names':labels,'center':center.tolist(),'scale':scale.tolist(),'validated':False,'recording_disjoint_validation':False,'production_abi_compatible':False,'physical_board_tested':False,'rationale':'fixed standardized nearest-centroid baseline; no tuning on validation/test; distance is not probability'}
(O/'model.json').write_text(json.dumps(model,indent=2)+'\n')
h=['/* OFFLINE EXPERIMENT ONLY: not c9_diag_model ABI; not board-validated. */','#ifndef FSTF_C9_BASELINE_H','#define FSTF_C9_BASELINE_H','#include <float.h>','#define FSTF_CLASSES 6','#define FSTF_FEATURES 18','static const double fstf_center[6][18]={']
h+=['{'+','.join(format(v,'.17g') for v in row)+'},' for row in center];h+=['};','static const double fstf_scale[18]={'+','.join(format(v,'.17g') for v in scale)+'};','static const char *const fstf_names[6]={'+','.join(json.dumps(s) for s in labels)+'};','static int fstf_predict(const double *x,double *dist){int best=0;for(int j=0;j<18;j++)if(!(x[j]<=DBL_MAX&&x[j]>=-DBL_MAX))return -1;for(int c=0;c<6;c++){double d=0;for(int j=0;j<18;j++){double v=(x[j]-fstf_center[c][j])/fstf_scale[j];d+=v*v/18;}dist[c]=d;if(c&&d<dist[best])best=c;}return best;}','#endif']
(O/'fstf_baseline.h').write_text('\n'.join(h)+'\n')
(O/'predict.c').write_text('#include "fstf_baseline.h"\n__declspec(dllexport) int predict(const double *x,double *d){return fstf_predict(x,d);}\n')
subprocess.run([str(GCC),'-O2','-shared','-static-libgcc',str(O/'predict.c'),'-o',str(O/'predict.dll')],check=True)
pl=ctypes.CDLL(str(O/'predict.dll'));pl.predict.argtypes=[ptr,ptr];pl.predict.restype=ctypes.c_int;worst=0
for z in records:
 v=np.array(z['features']);d=np.zeros(6);k=pl.predict(v.ctypes.data_as(ptr),d.ctypes.data_as(ptr));assert k==z['predicted_class'];worst=max(worst,float(np.max(abs(d-np.array(z['distances'])))))
# Reject NaN at native exported inference boundary.
v=np.zeros(18);v[0]=np.nan;d=np.zeros(6);assert pl.predict(v.ctypes.data_as(ptr),d.ctypes.data_as(ptr))==-1
(O/'features.jsonl').write_text(''.join(json.dumps(z)+'\n' for z in records))
with (O/'features.csv').open('w',newline='') as f:
 w=csv.writer(f);w.writerow(['label','split','start_s','end_s']+['f'+str(i) for i in range(18)]);w.writerows([[z['label'],z['split'],z['start_s'],z['end_s']]+z['features'] for z in records])
report={'audio':audit,'metrics':metrics,'native_prediction_matches':len(records),'max_native_distance_difference':worst,'resampler':'129 tap Hann-windowed sinc, cutoff0.45*min(1,target/source) cycles/source_sample, DC normalized, exact rational time positions; not recording peak renormalized','source_lineage_warning':'WAV README assumes original44100Hz; true original Fs remains unconfirmed; mono source WAV, not C9S3 separated array capture','outer_independent_validation_impossible':True,'board_accessed':False,'production_changed':False,'source_sha256':{str(p.relative_to(R)):sha(p) for p in [Path(__file__),R/'sw/circular9_envelope.h',R/'sw/circular9_diagnosis.h',R/'sw/bearing_6004_2zr.h',R/'sw/ps_env_pipeline.h']}}
(O/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(metrics,indent=2));print('FSTF_OFFLINE_BASELINE_PASS windows='+str(len(records))+' native_matches='+str(len(records)))
