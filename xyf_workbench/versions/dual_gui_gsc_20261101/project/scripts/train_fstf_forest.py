"""Fixed small offline forest alternative; same pre-existing blocked split. No board use."""
from pathlib import Path
import numpy as np,json,ctypes,subprocess
R=Path(__file__).resolve().parents[1];O=R/'build/fstf_training_20261027';rows=[json.loads(s) for s in (O/'features.jsonl').read_text().splitlines()];tr=[r for r in rows if r['split']=='train'];X=np.array([r['features'] for r in tr]);Y=np.array([r['class'] for r in tr]);rng=np.random.default_rng(20261027);nodes=[];roots=[]
def grow(ids,depth):
 counts=np.bincount(Y[ids],minlength=6);idx=len(nodes);nodes.append({'feature':-1,'threshold':0.,'left':0,'right':0,'class':int(counts.argmax())})
 if depth>=6 or len(ids)<4 or np.count_nonzero(counts)==1:return idx
 best=None;score0=len(ids)*(1-np.sum((counts/len(ids))**2));bestscore=score0
 for f in sorted(rng.choice(18,4,replace=False)):
  values=np.unique(X[ids,f])
  for t in (values[:-1]+values[1:])/2:
   mask=X[ids,f]<=t;l=ids[mask];rr=ids[~mask]
   if len(l)<2 or len(rr)<2:continue
   score=0
   for v in [l,rr]:
    c=np.bincount(Y[v],minlength=6);score+=len(v)-np.sum(c*c)/len(v)
   if score<bestscore-1e-12:bestscore=score;best=(int(f),float(t),l,rr)
 if best is not None:
  f,t,l,rr=best;nodes[idx].update(feature=f,threshold=t,left=grow(l,depth+1),right=grow(rr,depth+1))
 return idx
for tree in range(64):
 ids=np.concatenate([rng.choice(np.where(Y==c)[0],17,replace=True) for c in range(6)]);roots.append(grow(ids,0))
def pred(v):
 votes=np.zeros(6,dtype=int)
 for root in roots:
  n=root
  while nodes[n]['feature']>=0:
   a=nodes[n];n=a['left'] if v[a['feature']]<=a['threshold'] else a['right']
  votes[nodes[n]['class']]+=1
 return int(votes.argmax()),votes
metrics={}
for split in ['train','validation','test']:
 cm=np.zeros((6,6),int)
 for row in rows:
  if row['split']==split:
   k,v=pred(row['features']);cm[row['class'],k]+=1
 metrics[split]={'confusion_matrix':cm.tolist(),'accuracy':float(np.trace(cm)/cm.sum()),'windows':int(cm.sum()),'missing_classes':[i for i in range(6) if cm[i].sum()==0]}
model={'schema':'FSTF_C9F2_OFFLINE_FOREST_V1','seed':20261027,'trees':64,'max_depth':6,'min_leaf_bootstrap_entries':2,'features_per_split':4,'balanced_bootstrap_per_class':17,'roots':roots,'nodes':nodes,'validated':False,'vote_fraction_is_calibrated_probability':False,'physical_board_tested':False,'production_abi_compatible':False,'class_names':['inner','outer','ball','healthy','looseness','combined']};(O/'forest.json').write_text(json.dumps(model,indent=2))
h=['/* Offline six-class FSTF research model, not production ABI. Votes are not probability. */','#ifndef FSTF_FOREST_H','#define FSTF_FOREST_H','#include <float.h>','static const unsigned fstf_rf_roots[64]={'+','.join(map(str,roots))+'};','typedef struct{int feature;double threshold;unsigned left,right,label;} fstf_rf_node;','static const fstf_rf_node fstf_rf_nodes[]={']
h+=['{%d,%.17g,%d,%d,%d},'%(n['feature'],n['threshold'],n['left'],n['right'],n['class']) for n in nodes];h+=['};','static int fstf_rf_predict(const double *v,unsigned *votes){for(int j=0;j<18;j++)if(!(v[j]>=-DBL_MAX&&v[j]<=DBL_MAX))return -1;for(int c=0;c<6;c++)votes[c]=0;for(int t=0;t<64;t++){unsigned n=fstf_rf_roots[t];while(fstf_rf_nodes[n].feature>=0){const fstf_rf_node *p=&fstf_rf_nodes[n];n=v[p->feature]<=p->threshold?p->left:p->right;}votes[fstf_rf_nodes[n].label]++;}int best=0;for(int c=1;c<6;c++)if(votes[c]>votes[best])best=c;return best;}','#endif'];(O/'fstf_forest.h').write_text('\n'.join(h)+'\n');(O/'forest_predict.c').write_text('#include "fstf_forest.h"\n__declspec(dllexport) int predict(const double *v,unsigned *votes){return fstf_rf_predict(v,votes);}\n')
subprocess.run([r'D:\winlibs\mingw64\bin\gcc.exe','-O2','-shared','-static-libgcc',str(O/'forest_predict.c'),'-o',str(O/'forest_predict.dll')],check=True)
lib=ctypes.CDLL(str(O/'forest_predict.dll'));ptr=ctypes.POINTER(ctypes.c_double);vp=ctypes.POINTER(ctypes.c_uint32);lib.predict.argtypes=[ptr,vp];lib.predict.restype=ctypes.c_int
for row in rows:
 v=np.array(row['features']);votes=np.zeros(6,np.uint32);k=lib.predict(v.ctypes.data_as(ptr),votes.ctypes.data_as(vp));kp,vp0=pred(v);assert k==kp and np.array_equal(votes,vp0)
x=np.zeros(18);x[0]=np.nan;votes=np.zeros(6,np.uint32);assert lib.predict(x.ctypes.data_as(ptr),votes.ctypes.data_as(vp))==-1
(O/'forest_results.json').write_text(json.dumps({'metrics':metrics,'native_matches':len(rows),'nodes':len(nodes),'fixed_hyperparameters':True,'heldout_test_not_used_for_training':True,'recording_disjoint_validation':False,'board_tested':False},indent=2));print('FOREST_PASS',json.dumps(metrics),'nodes',len(nodes))
