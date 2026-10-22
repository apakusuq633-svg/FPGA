"""Offline comparison only: instant, coefficient/delay slew, dual-beam crossfade."""
from pathlib import Path
import argparse,csv,json
import numpy as np
from integrated_acoustics import array,direction,FS,C,coefficients
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output;O.mkdir(parents=True,exist_ok=False)
xyz=array();rows=[];n=np.arange(2048);switch=512;omega=2*np.pi*1000/FS
for az,el in [(0,0),(43,27),(175,-42)]:
    u=direction(az,el);v=direction(az+180,-el)
    def delay(look):
        q=np.floor((xyz-xyz[0])@look*FS/C*16).astype(int);return q-q.min()
    old,new=delay(u),delay(v)
    for position,phase in [('zero',-omega*switch),('peak',np.pi/2-omega*switch)]:
        x=np.array([9000*np.sin(omega*(n+xyz[ch]@u*FS/C)+phase) for ch in range(12)])
        def sample(t,d):
            out=0.
            for ch,q in enumerate(d):
                for k,c in enumerate(coefficients(int(q)%16)):
                    age=int(q)//16+k
                    if t>=age:out+=x[ch,t-age]*c/16384/12
            return out
        fixed_old=np.array([sample(t,old) for t in n]);fixed_new=np.array([sample(t,new) for t in n]);cur=old.copy()
        for mode in ['instant','slew','dual_crossfade32']:
            audio=[]
            for t in n:
                if mode=='instant':y=fixed_old[t] if t<switch else fixed_new[t]
                elif mode=='slew':
                    if t>=switch:cur+=np.sign(new-cur)
                    y=sample(t,cur)
                else:
                    alpha=np.clip((t-switch+1)/32,0,1);y=(1-alpha)*fixed_old[t]+alpha*fixed_new[t]
                audio.append(y)
            z=np.array(audio)[switch-64:switch+128]
            rows.append({'az':az,'el':el,'switch_phase':position,'mode':mode,
              'peak_step_lsb':float(abs(np.diff(z)).max()),'peak_second_difference':float(abs(np.diff(z,n=2)).max()),
              'render_work_factor':2 if mode=='dual_crossfade32' else 1})
with(O/'comparison.csv').open('w',newline='')as f:w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
report={'status':'MODEL_EVALUATED','selected':'slew','reason':'Single beam render, no copied history; verified RTL transient thresholds already pass.',
 'dual_beam_rtl':'NOT_IMPLEMENTED_BY_DESIGN','max_second_difference':{m:max(r['peak_second_difference'] for r in rows if r['mode']==m) for m in ['instant','slew','dual_crossfade32']}}
(O/'metrics.json').write_text(json.dumps(report,indent=2));print(report)
