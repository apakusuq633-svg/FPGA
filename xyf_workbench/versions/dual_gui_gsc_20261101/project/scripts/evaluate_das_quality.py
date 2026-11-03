from pathlib import Path
import argparse,json,csv
import numpy as np
from integrated_acoustics import FS,C,array,direction,source,shift,das
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args();O=a.output;O.mkdir(parents=True,exist_ok=False)
(O/'acceptance.json').write_text(json.dumps({'target_gain_error_db_max':.3,'no_claim_of_positive_snr_for_every_direction':True,'seed':20261015,'band_hz':[300,7800]},indent=2))
xyz=array();rows=[]
for k,(az,el) in enumerate([(0,0),(43,27),(175,-42),(302,65),(358,-1),(180,0)]):
    u=direction(az,el);v=direction(az+115,-el);x=source(8192,20261015+k);i=source(8192,731+k)
    tau=-xyz@u*FS/C;ti=-xyz@v*FS/C;delays=tau.max()-tau
    desired=np.array([shift(x,t) for t in tau]);interferer=np.array([shift(i,t)*.7 for t in ti])
    for mode in ['integer','linear','cubic']:
        y=das(desired,delays,mode)[128:-128];z=das(interferer,delays,mode)[128:-128]
        ideal=shift(x,tau.max()+(1 if mode=='cubic' else 0))[128:-128]
        gain=np.dot(y,ideal)/np.dot(ideal,ideal)
        rows.append({'az':az,'el':el,'mode':mode,'input_snr_db':float(10*np.log10(1/.49)),
          'output_snr_db':float(10*np.log10(np.mean(y*y)/np.mean(z*z))),
          'snr_improvement_db':float(10*np.log10(np.mean(y*y)/np.mean(z*z))-10*np.log10(1/.49)),
          'target_gain_db':float(20*np.log10(abs(gain))),
          'target_distortion_rms_relative':float(np.sqrt(np.mean((y-ideal)**2)/np.mean(ideal**2)))})
with(O/'quality.csv').open('w',newline='')as f:w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
assert all(abs(r['target_gain_db'])<=.3 for r in rows if r['mode']=='cubic')
summary={mode:{'worst_target_distortion':max(r['target_distortion_rms_relative'] for r in rows if r['mode']==mode),
 'snr_improvement_db_min':min(r['snr_improvement_db'] for r in rows if r['mode']==mode),
 'snr_improvement_db_max':max(r['snr_improvement_db'] for r in rows if r['mode']==mode)} for mode in ['integer','linear','cubic']}
(O/'metrics.json').write_text(json.dumps({'status':'PASS','synthetic_only':True,'comparison':summary},indent=2));print(summary)
