"""Independent SIM_GEOMETRY_ONLY physical scenes, floating SRP, and DAS A/B.

Run from WSL: python3 scripts/integrated_acoustics.py --output <new directory>.
Acceptance is written before generation. No production configuration is written.
"""
from pathlib import Path
import argparse, csv, hashlib, itertools, json, math
import numpy as np

FS=39062.5; C=343.; N=1024; PAIRS=np.array(list(itertools.combinations(range(12),2)))
def direction(az,el):
    az,el=np.deg2rad([az,el]); return np.array([np.cos(el)*np.cos(az),np.cos(el)*np.sin(az),np.sin(el)])
def angles(u):return float(np.rad2deg(np.arctan2(u[1],u[0]))%360),float(np.rad2deg(np.arcsin(u[2])))
def error(u,v):return float(np.rad2deg(np.arccos(np.clip(np.dot(u,v),-1,1))))
def array():
    # Explicit test array: three adjacent perpendicular faces, NOT physical coordinates.
    return np.array([(0,a,b) for a in (.01,.03) for b in (.01,.03)]+
                    [(a,0,b) for a in (.01,.03) for b in (.01,.03)]+
                    [(a,b,0) for a in (.01,.03) for b in (.01,.03)])
GRID=np.array([direction(az*360/32,-90+el*180/31) for el in range(32) for az in range(32)])
def lut_for(xyz):
    tau=-(xyz[PAIRS[:,0]]-xyz[PAIRS[:,1]])@GRID.T*FS/C
    q=np.floor(tau*16).astype(int)
    assert np.all(q//16>=-16) and np.all(q//16<=14)
    return q, ((q//16)%32)*16+(q%16)
def source(n,seed,band=(300,7800)):
    rng=np.random.default_rng(seed); freq=np.fft.rfftfreq(n,1/FS)
    z=rng.normal(size=freq.size)+1j*rng.normal(size=freq.size)
    z[(freq<band[0])|(freq>band[1])]=0
    x=np.fft.irfft(z,n); return x/np.std(x)
def shift(x,delay):return np.fft.irfft(np.fft.rfft(x)*np.exp(-2j*np.pi*np.fft.rfftfreq(len(x))*delay),len(x))
def scene(xyz,u,seed,snr=40,reflection=0.,interferer=0.,gain=0.,skew=0.,speed=C,near=None,polarity=False,permuted=False,long=False,speech=False):
    n=16384 if long else 8192; x=source(n,seed)
    if speech:
        t=np.arange(n)/FS;voiced=np.zeros(n)
        for h in range(1,55):
            f=137*h;weight=sum(np.exp(-.5*((f-center)/width)**2) for center,width in [(650,130),(1350,180),(2700,300),(4500,450)])/(h**.5)
            voiced+=weight*np.sin(2*np.pi*f*t+.19*h)
        envelope=.25+.75*np.sin(2*np.pi*3.7*t)**2
        x=(voiced/np.std(voiced)+.3*x)*envelope;x/=np.std(x)
    if near is not None:near=u*near
    tau=(-xyz@u if near is None else np.linalg.norm(near-xyz,axis=1))*FS/speed
    pcm=np.array([shift(x,t) for t in tau])
    rng=np.random.default_rng(seed+991)
    if reflection:pcm+=reflection*np.array([shift(x,31-t) for t in tau])
    if interferer:
        v=direction(angles(u)[0]+100,-angles(u)[1]); noise=source(n,seed+8)
        pcm+=interferer*np.array([shift(noise,t) for t in -xyz@v*FS/C])
    if gain:pcm*=rng.uniform(1-gain,1+gain,(12,1))
    if skew:pcm=np.array([shift(pcm[ch],rng.uniform(-skew,skew)) for ch in range(12)])
    pcm+=rng.normal(size=pcm.shape)*10**(-snr/20)
    if polarity:pcm[3]*=-1
    if permuted:pcm=pcm[np.roll(np.arange(12),3)]
    return np.rint(np.clip(pcm[:,2048:10240 if long else 4096]*3500,-32768,32767)).astype(np.int16)
def gcc_srp(pcm,q):
    x=pcm[:,:N].astype(float);x-=x.mean(axis=1,keepdims=True)
    spec=np.fft.rfft(x*np.hanning(N)); cross=spec[PAIRS[:,0]]*np.conj(spec[PAIRS[:,1]])
    cross/=np.maximum(np.abs(cross),1e-12)
    # Match existing useful spectral band, while computing complete 1024-point IFFTs.
    cross[:,:6]=0;cross[:,214:]=0
    corr=np.fft.irfft(cross,n=N)
    lo=q//16;f=(q%16)/16
    scores=np.sum(corr[np.arange(66)[:,None],lo%N]*(1-f)+corr[np.arange(66)[:,None],(lo+1)%N]*f,axis=0)
    return scores,corr
def coefficients(frac):
    f=frac/16
    c=np.array([-f*(1-f)*(2-f)/6,(1+f)*(1-f)*(2-f)/2,(1+f)*f*(2-f)/2,-(1+f)*f*(1-f)/6])
    z=np.rint(c*16384).astype(int);z[1]+=16384-z.sum();return z
def das(x,delays,mode):
    n=x.shape[1];out=np.zeros(n)
    for ch,d in enumerate(delays):
        di=int(np.floor(d));f=int(np.floor((d-di)*16))
        if mode=='integer':taps=[(di,1.)]
        elif mode=='linear':taps=[(di,1-f/16),(di+1,f/16)]
        else:taps=[(di+k,c/16384) for k,c in enumerate(coefficients(f))]
        for age,c in taps:
            if age<n:out[age:]+=x[ch,:n-age]*c/12
    return out
def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    O=a.output;O.mkdir(parents=True,exist_ok=False)
    acceptance={'scope':'SIM_GEOMETRY_ONLY','seed':20261015,'fs_hz':FS,'speed_m_s':C,'nfft':N,'hop':512,'pairs':66,'grid':1024,
      'clean_max_angle_deg':18,'clean_p90_deg':12,'snr20_max_angle_deg':22,
      'fixed_vs_rtl_scores':'bit exact all 1024 scores','das_band_hz':[300,8000],
      'cubic_rms_complex_error_ratio_max':0.65,'normal_sample_drops':0,
      'switch_peak_step_lsb_max':4096,'switch_short_energy_ratio_max':2.0,
      'stress_errors_max':0,'timing_wns_min':0,'timing_whs_min':0}
    (O/'acceptance.json').write_text(json.dumps(acceptance,indent=2))
    xyz=array();q,lut=lut_for(xyz)
    geometry={'role':'SIM_GEOMETRY_ONLY','production_geometry_enabled':False,'mic_xyz_m':xyz.tolist(),
      'channel_to_mic':list(range(12)),'origin':'intersection of three test planes','axes':'right-handed X/Y/Z',
      'azimuth':'atan2(y,x), degrees [0,360)','elevation':'asin(z), degrees [-90,90]',
      'propagation_samples':'-dot(mic_xyz, source_unit_vector)*Fs/c','delay_pair':'arrival_i-arrival_j',
      'pairs':PAIRS.tolist(),'grid_directions':GRID.tolist(),'unique_directions':962}
    (O/'geometry.json').write_text(json.dumps(geometry,indent=2))
    np.savetxt(O/'lut.hex',lut.reshape(-1),fmt='%08x')
    # Signed Q4 mic-to-reference lags for the existing steering engine.
    # tau_0m = arrival_0 - arrival_m, opposite to each microphone's arrival offset.
    st=np.floor((xyz-xyz[0])@GRID.T*FS/C*16).astype(int)
    np.savetxt(O/'steer_lut.hex',(((st//16)&1023)*16+(st%16)).reshape(-1),fmt='%08x')
    compensation=(st-st.min(axis=0,keepdims=True))*4096
    np.savetxt(O/'comp_expected.hex',compensation.reshape(-1),fmt='%08x')
    rng=np.random.default_rng(20261015); rows=[]; outputs=[]
    configs=[('clean',{}),('snr20',{'snr':20}),('snr0',{'snr':0}),('reflection',{'reflection':.35}),
      ('dual_source',{'interferer':.6}),('gain_skew',{'gain':.15,'skew':.15}),('speed',{'speed':335}),
      ('nearfield_mismatch',{'near':.2}),('polarity_fault',{'polarity':True}),('channel_permutation',{'permuted':True})]
    configs.append(('synthetic_speech',{'speech':True}))
    for k in range(48):
        az=float(rng.uniform(0,360));el=float(rng.uniform(-72,72));u=direction(az,el)
        for name,opts in configs:
            pcm=scene(xyz,u,20261015+k,**opts);scores,corr=gcc_srp(pcm,q);best=int(np.argmax(scores));pred=GRID[best]
            row={'case':k,'scenario':name,'az_true':az,'el_true':el,'grid':best,'az_est':angles(pred)[0],
               'el_est':angles(pred)[1],'angle_error_deg':error(u,pred),'grid_quantization_deg':min(error(u,g) for g in GRID)}
            rows.append(row)
            if k<4 and name=='clean':
                long_pcm=scene(xyz,u,20261015+k,long=True)
                long_pcm.T.tofile(O/f'pcm_{k}.bin');np.savetxt(O/f'pcm_{k}.hex',long_pcm.T.reshape(-1).astype(np.uint16),fmt='%04x')
                outputs.append({'pcm':f'pcm_{k}.bin','truth':u.tolist(),'floating_grid':best})
    # Geometry observability diagnostics: rank 1/2/3; plane mirror identical delays.
    planar=xyz.copy();planar[:,2]=0;linear=planar.copy();linear[:,1]=0
    obs={'linear_rank':int(np.linalg.matrix_rank(linear-linear.mean(0))),
      'planar_rank':int(np.linalg.matrix_rank(planar-planar.mean(0))),
      'spatial_rank':int(np.linalg.matrix_rank(xyz-xyz.mean(0))),
      'planar_mirror_max_delay_diff':float(np.max(np.abs(planar@(direction(43,35)-direction(43,-35)))))}
    quant=[min(error(direction(float(az),float(el)),g) for g in GRID) for az,el in zip(rng.uniform(0,360,2000),rng.uniform(-90,90,2000))]
    # Frequency-domain delay error, compare same causal group delay across schemes.
    w=2*np.pi*np.linspace(300,8000,400)/FS;quality={}
    for mode in ['integer','linear','cubic']:
        errors=[]
        for f in range(16):
            if mode=='integer':h=np.ones_like(w,dtype=complex);target=np.exp(-1j*w*f/16)
            elif mode=='linear':h=(1-f/16)+(f/16)*np.exp(-1j*w);target=np.exp(-1j*w*f/16)
            else:h=np.exp(-1j*w[:,None]*np.arange(4))@(coefficients(f)/16384);target=np.exp(-1j*w*(1+f/16))
            errors.extend(abs(h-target)**2)
        quality[mode]=float(np.sqrt(np.mean(errors)))
    metrics={}
    for name,_ in configs:
        v=np.array([r['angle_error_deg'] for r in rows if r['scenario']==name]);metrics[name]={
          'p50':float(np.percentile(v,50)),'p90':float(np.percentile(v,90)),'p99':float(np.percentile(v,99)),
          'max':float(v.max()),'success_within_18deg':float(np.mean(v<=18))}
    passed=(metrics['clean']['max']<=acceptance['clean_max_angle_deg'] and metrics['clean']['p90']<=acceptance['clean_p90_deg']
      and metrics['snr20']['max']<=acceptance['snr20_max_angle_deg'] and quality['cubic']/quality['linear']<=.65
      and obs['spatial_rank']==3 and obs['planar_mirror_max_delay_diff']<1e-12)
    with (O/'scenarios.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=rows[0]);writer.writeheader();writer.writerows(rows)
    result={'status':'PASS' if passed else 'FAIL','scenarios':len(rows),'angles':metrics,'observability':obs,
      'grid_quantization_deg':{'p99':float(np.percentile(quant,99)),'max_measured':max(quant)},
      'das_complex_rms_error':quality,'rtl_cases':outputs,'hardware':'DEFERRED_HARDWARE'}
    (O/'metrics.json').write_text(json.dumps(result,indent=2))
    (O/'manifest.json').write_text(json.dumps({x.name:hashlib.sha256(x.read_bytes()).hexdigest() for x in O.iterdir() if x.is_file()},indent=2))
    print(json.dumps(result,indent=2));raise SystemExit(not passed)
if __name__=='__main__':main()
