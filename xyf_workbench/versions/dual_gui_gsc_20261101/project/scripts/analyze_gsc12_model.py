"""Diagnose achievable causal cancellation/conditioning without changing acceptance."""
from pathlib import Path
import argparse,json
import numpy as np
from gsc12_golden import frontend
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False);results=[]
for k in range(3):
    d=np.load(a.input/f'case{k}.npz',allow_pickle=False)
    _,beam,refs=frontend(d['noise_raw'],d['delays_q16'],d['fir'])
    for taps in (4,8,16,32):
        x=np.zeros((len(beam),11*taps),float)
        for ch in range(11):
            for t in range(taps):x[t:,ch*taps+t]=refs[:len(beam)-t,ch]
        train=x[128:12000];target=beam[128:12000].astype(float)
        w,_,_,sv=np.linalg.lstsq(train,target,rcond=1e-5)
        pred=x[-8192:]@w;error=beam[-8192:].astype(float)-pred
        results.append({'case':k,'taps':taps,'unconstrained_noise_gain_db':float(10*np.log10(np.mean(error**2)/np.mean(beam[-8192:].astype(float)**2))),
          'weight_abs_max':float(abs(w).max()),'weight_l1':float(abs(w).sum()),'weight_l2':float(np.linalg.norm(w)),
          'singular_value_ratio':float(sv[0]/sv[-1])})
        print(results[-1],flush=True)
(a.output/'metrics.json').write_text(json.dumps(results,indent=2))
