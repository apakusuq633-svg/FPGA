"""Quantify a half-PDM-bit offset and one-PCM-sample fault on TEST_ONLY geometry."""
from pathlib import Path
import argparse,json
import numpy as np
from integrated_acoustics import array,lut_for,scene,direction,gcc_srp,GRID,error,FS,C,das,shift
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output;O.mkdir(parents=True,exist_ok=False)
# Acceptance is frozen before generating scenes. Fault sensitivity is an observation,
# not a claim that every source/grid location detects a wiring fault.
acceptance={'scope':'TEST_ONLY','channels':12,'nfft':1024,'hop':512,'pairs':66,'grid':1024,
 'half_bit_seconds':200e-9,'same_phase_tdoa_bias_samples':0,
 'cross_phase_tdoa_bias_samples':200e-9*FS,'das_8khz_loss_db_max':0.001,
 'hardware':'DEFERRED_HARDWARE','scenario_count':24}
(O/'acceptance.json').write_text(json.dumps(acceptance,indent=2))
xyz=array();q,_=lut_for(xyz);rows=[]
for i in range(24):
    u=direction(i*15,(-40,0,40)[i%3]);x=scene(xyz,u,20261016+i,snr=80).astype(float)
    delays=-(xyz@u)*FS/C;steer=delays.max()-delays
    for name,offset in [('baseline',0),('half_bit',200e-9*FS),('one_pcm_fault',1)]:
        y=x.copy()
        for ch in range(1,12,2):y[ch]=shift(y[ch],offset)
        scores,corr=gcc_srp(y,q);peak=int(scores.argmax())
        audio=das(y,steer,'cubic')[64:]
        rows.append({'scene':i,'mode':name,'grid_peak':peak,'angle_error_deg':error(GRID[peak],u),
          'tdoa_integer_peaks':np.argmax(corr,axis=1).tolist(),'das_rms':float(np.sqrt(np.mean(audio**2)))})
freq=np.linspace(300,8000,1000)
# Equal target on six A and six B channels: H=(1+exp(-jw*dt))/2.
loss=float(np.max(-20*np.log10(np.abs((1+np.exp(-2j*np.pi*freq*200e-9))/2))))
assert loss<=acceptance['das_8khz_loss_db_max']
summary={'status':'PASS_MODEL','hardware':'DEFERRED_HARDWARE','das_half_bit_worst_loss_db':loss,
 'half_bit_offset_pcm_samples':200e-9*FS,'equivalent_path_mm':200e-9*C*1000,
 'grid_changes_half_bit':sum(rows[3*i]['grid_peak']!=rows[3*i+1]['grid_peak'] for i in range(24)),
 'grid_changes_one_pcm':sum(rows[3*i]['grid_peak']!=rows[3*i+2]['grid_peak'] for i in range(24)),
 'scenes':rows}
(O/'results.json').write_text(json.dumps(summary,indent=2));print(json.dumps({k:v for k,v in summary.items() if k!='scenes'}))
