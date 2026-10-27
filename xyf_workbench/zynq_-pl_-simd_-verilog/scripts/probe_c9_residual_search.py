"""Research-only full-grid residual Bartlett; never loaded by firmware.
No source truth selects peer/peaks. Truth is used only for final error scoring."""
from pathlib import Path
import subprocess,json,time,sys
import numpy as np
from c9_scene_evaluation import angle
R=Path(__file__).resolve().parents[1];O=R/'build/offline_closure_20261027/residual_research';O.mkdir(parents=True,exist_ok=True)
exe=O/'probe.exe';subprocess.run([r'D:\winlibs\mingw64\bin\gcc.exe','-std=c11','-O2','-Isw','sw/circular9_observation_probe_test.c','-lm','-o',str(exe)],cwd=R,check=True)
G=[{'azimuth_deg':-90+(g%32+.5)*180/32,'elevation_deg':-90+(g//32+.5)*180/32} for g in range(1024)]
def peaks(score):
 order=np.argsort(score)[::-1];out=[]
 for g in order:
  if score[g]<0:break
  if all(angle(G[g],p)>25 for p in out):out.append({**G[g],'grid':int(g),'score':float(score[g])})
  if len(out)==3:break
 return out
cases=[]
for folder,names in [('fstf_integration_20261027',['dual_loud_normal_weak_ball','single_healthy']),('offline_multisource_20261027/stress',['angle_15','angle_70','three_sources','silence','noise_only'])]:
 root=R/'build'/folder;results=json.loads((root/'e2e_results.json').read_text())['cases']
 for name in names:
  case=next((c for c in results if c['scene']==name),None)
  if case is None:continue
  for offset in [0,320000]:
   binary=O/f'{name}_{offset}.bin';subprocess.run([str(exe),str(root/(name+'.pcm')),str(offset),str(binary)],cwd=R,check=True,capture_output=True)
   b=binary.read_bytes();h=np.frombuffer(b[:16],'<u4');f=int(h[0]);count=int(h[1]);invalid=int(h[2]);entry={'scene':name,'offset':offset,'invalid':invalid,'input_candidates':count,'synthetic_input':True}
   if not f or not count or invalid:entry['no_supported_peer']=True;cases.append(entry);continue
   X=np.frombuffer(b,dtype='<c16',count=8*9*202,offset=16).reshape(8,9,202)[:f];Q=np.frombuffer(b,dtype='<f8',offset=16+8*9*202*16).reshape(1025,9)
   bins=np.arange(8,210);sel=(bins*39062.5/1024>=4600)&(bins*39062.5/1024<=8000);energy=(abs(X)**2).sum(axis=(0,1));sel&=energy>energy[sel].max()*.001
   k=bins[sel];x=X[:,:,sel];q=Q[:1024];qp=Q[1024];weights=np.exp(-2j*np.pi*q[:,:,None]*k[None,None,:]/(64*1024));peer=np.exp(-2j*np.pi*qp[:,None]*k[None,:]/(64*1024));y=np.einsum('ck,fck->fk',peer,x)
   residual=x-np.conj(peer)[None,:,:]*y[:,None,:]/9;cross=np.sum(weights*np.conj(peer)[None,:,:],axis=1);norm=9-abs(cross)**2/9
   # Reuse existing norm limit; this exploratory full scan has no production gate.
   safe=norm>=.125;start=time.perf_counter();beam=np.einsum('gck,fck->gfk',weights,residual);power=(abs(beam)**2).sum(axis=1)/np.maximum(norm,.125)
   re=(abs(residual)**2).sum(axis=(0,1));value=np.where(safe,(8*power-re[None,:])/np.maximum(7*re[None,:],1e-20),0);score=np.sum(value*safe,axis=1)/np.maximum(safe.sum(axis=1),1)
   score[safe.sum(axis=1)<4]=-1;score[np.array([angle(g,G[int(h[3])])<25 for g in G])]=-1;found=peaks(score);entry.update(residual_peaks=found,host_seconds=time.perf_counter()-start,bins=int(len(k)),truth_errors=[min((angle(s,p) for p in found),default=180) for s in case['sources']],grid_candidates=1024,production_changed=False)
   cases.append(entry);print(name,offset,[(round(v['azimuth_deg'],1),round(v['elevation_deg'],1)) for v in found],entry['truth_errors'],flush=True)
(O/'results.json').write_text(json.dumps({'research_only':True,'board_tested':False,'ARM_timing_measured':False,'no_threshold_tuning':True,'method':'full-grid rank8 residual coherence; original candidate0 is peer, no truth used for selection; highband only;25deg peer exclusion','limitation':'cannot infer source count from3 peaks; no production observation/quality/trajectory gates; optional peaks are research proposals only','cases':cases},indent=2));print('RESIDUAL_RESEARCH_COMPLETE',len(cases))
