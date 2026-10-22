"""Freeze and evaluate representative M8 TEST_ONLY scenes before C implementation."""
from pathlib import Path
import argparse,hashlib,json
import numpy as np
from integrated_acoustics import GRID,array,direction,FS,C,angles
from gsc12_golden import frontend,nlms,fixed_output
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--integrate-refs',action='store_true');a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
fir_path=R/'build/fw_fir_coeff.hex'
fir=np.array([int(t,16) for t in fir_path.read_text().split()],dtype=np.uint16).view(np.int16)
assert len(fir)==32
acceptance={'scope':'TEST_ONLY','seed':20261016,'sample_rate_hz':FS,'n':32768,'channels':12,
 'target_grids':[585,431,704],'band_hz':[300,6000],'mu_q15':8192,'epsilon':1<<20,
 'snr_improvement_db_min':3,'target_gain_db_min':-1,'target_relative_error_max':.2,
 'evaluation_tail_samples':8192,'fir_sha256':hashlib.sha256(fir_path.read_bytes()).hexdigest(),
 'hardware':'DEFERRED_HARDWARE'}
acceptance['reference_leaky_integrator']=a.integrate_refs
(O/'acceptance.json').write_text(json.dumps(acceptance,indent=2))
results=[];n=acceptance['n'];freq=np.fft.rfftfreq(n);mask=(freq*FS>=300)&(freq*FS<=6000)
def signal(rng):
    s=np.zeros(len(freq),complex);s[mask]=rng.normal(size=mask.sum())+1j*rng.normal(size=mask.sum())
    x=np.fft.irfft(s,n);return x/np.std(x)
def power(x):return float(np.mean(np.asarray(x,dtype=float)**2))
for k,grid in enumerate(acceptance['target_grids']):
    rng=np.random.default_rng(20261016+k);u=GRID[grid];az,el=angles(u);v=direction(az+100,-el)
    target=signal(rng)*1500;noise=signal(rng)*6000
    tau=-array()@u*FS/C;ntau=-array()@v*FS/C
    delays=(np.floor((tau.max()-tau)*16)*4096).astype(np.uint32)
    def field(x,t):return np.array([np.fft.irfft(np.fft.rfft(x)*np.exp(-2j*np.pi*freq*d),n) for d in t]).T
    tfield=field(target,tau);nfield=field(noise,ntau)
    raw=np.rint(tfield+nfield).astype(np.int64)
    assert abs(raw).max()<32767,'representative scene clipped before quantization'
    raw=raw.astype(np.int16);traw=np.rint(tfield).astype(np.int16);nraw=np.rint(nfield).astype(np.int16)
    das,beam,refs=frontend(raw,delays,fir,integrate_refs=a.integrate_refs)
    _,tb,trefs=frontend(traw,delays,fir,integrate_refs=a.integrate_refs);_,nb,nrefs=frontend(nraw,delays,fir,integrate_refs=a.integrate_refs)
    out,w,stats=nlms(beam,refs)
    tout=fixed_output(tb,trefs,w);nout=fixed_output(nb,nrefs,w)
    tail=slice(-8192,None)
    before=10*np.log10(power(tb[tail])/power(beam[tail].astype(float)-tb[tail]))
    after=10*np.log10(power(tb[tail])/power(out[tail].astype(float)-tb[tail]))
    target_gain=10*np.log10(power(tout[tail])/power(tb[tail]))
    distortion=float(np.sqrt(power(tout[tail].astype(float)-tb[tail])/power(tb[tail])))
    blocks=[]
    for start in range(1024,n,1024):
        sl=slice(start,start+1024)
        improvement=10*np.log10(power(beam[sl].astype(float)-tb[sl])/power(out[sl].astype(float)-tb[sl]))
        blocks.append(float(improvement))
    converged=next((i+1 for i in range(len(blocks)-2) if min(blocks[i:i+3])>=3),None)
    passed=after-before>=3 and target_gain>=-1 and distortion<=.2 and stats['divergence']==0
    row={'case':k,'grid':grid,'status':'PASS' if passed else 'FAIL','snr_before_db':float(before),'snr_after_db':float(after),
       'snr_improvement_db':float(after-before),'target_gain_db':float(target_gain),'target_relative_rms_error':distortion,
       'noise_gain_db':float(10*np.log10(power(nout[tail])/power(nb[tail]))),
       'convergence_seconds':None if converged is None else converged*1024/FS,
       'block_snr_improvements_db':blocks,'stats':stats}
    results.append(row)
    np.savez(O/f'case{k}.npz',raw=raw,target_raw=traw,noise_raw=nraw,delays_q16=delays,fir=fir,
             das=das,beam=beam,refs=refs,expected=out,weights=w,target_beam=tb)
    (O/'metrics.json').write_text(json.dumps({'status':'PASS' if all(r['status']=='PASS' for r in results) else 'FAIL','scope':'TEST_ONLY','cases':results},indent=2))
    print(json.dumps({key:value for key,value in row.items() if key!='block_snr_improvements_db'}),flush=True)
assert len(results)==3 and all(r['status']=='PASS' for r in results),'Frozen GSC Golden criteria failed; retain all failed evidence'
print('GSC12_GOLDEN_PASS')
