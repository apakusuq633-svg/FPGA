"""Replay independently calibrated synthetic captures through the complete RV32 RTL."""
from pathlib import Path
import argparse,json,os,re,subprocess
import numpy as np
from pdm12_calibration import validate,calibration_luts
from integrated_acoustics import gcc_srp,GRID,error
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--calibration',type=Path,required=True);p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
D=a.calibration.resolve();doc=json.loads((D/'test_only_fitted.json').read_text());v=validate(doc,True)
capture=np.load(D/'synthetic_capture.npz',allow_pickle=False);lut,steer=calibration_luts(doc,True)
np.savetxt(O/'calibrated_lut.hex',lut.reshape(-1),fmt='%08x')
# Decode the lag format to an independently evaluated floating PHAT/IFFT scorer.
lo=lut//16;lo=np.where(lo>=16,lo-32,lo);q=lo*16+lut%16
results=[];b=doc['body']
for i in range(4):
    pcm=capture['pcm'][i].astype(np.int64)
    product=(pcm-np.array(b['dc_offset'])[:,None])*np.array(b['gain_q14'])[:,None]*np.array(b['polarity'])[:,None]
    corrected=np.where(product>=0,product//16384,-((-product)//16384))
    corrected=(np.clip(corrected,-8388608,8388607)>>8).astype(np.int16)
    corrected.T.tofile(O/f'pcm{i}.bin')
    scores,_=gcc_srp(corrected,q);floating_peak=int(scores.argmax())
    env=os.environ.copy();env.update(ACOUSTIC_PCM=str(O/f'pcm{i}.bin'),ACOUSTIC_LUT=str(O/'calibrated_lut.hex'))
    cmd=['python3','scripts/check_localizer12_safety.py','--reuse-model','--windows','1','--output',str(a.model.resolve()),'--report-name',f'calibrated{i}']
    with (O/f'case{i}_driver.log').open('w') as f:run=subprocess.run(cmd,cwd=R,env=env,stdout=f,stderr=subprocess.STDOUT)
    assert run.returncode==0,(O/f'case{i}_driver.log').read_text()
    summary=json.loads((a.model.resolve()/f'calibrated{i}_summary.json').read_text())
    row=summary['results'][0];text=(R/row['log']).read_text()
    m=re.search(r'ACOUSTIC_RESULT grid=(\d+) score=(-?\d+) all_scores_checked=1024',text);assert m
    peak=int(m[1]);angle=error(GRID[peak],capture['directions'][i])
    assert row['status']=='PASS' and angle<=18
    assert row['raw_drop']==row['window_drop']==row['audio_drop']==0
    results.append({'case':i,'rtl_grid':peak,'floating_grid':floating_peak,'angle_error_deg':angle,
                    'all_scores_checked':1024,'scope':'TEST_ONLY','rtl_result':row})
(O/'metrics.json').write_text(json.dumps({'status':'PASS','scope':'TEST_ONLY','cases':results},indent=2))
print('M7_CALIBRATED_RTL_PASS',json.dumps([{k:r[k] for k in ('case','rtl_grid','floating_grid','angle_error_deg','all_scores_checked')} for r in results]))
