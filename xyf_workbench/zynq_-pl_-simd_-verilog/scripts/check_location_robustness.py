"""Deterministic acoustic stress cases; numerical simulation, never a board claim."""
from pathlib import Path
import argparse,ctypes,json,math,os,shutil,subprocess
import numpy as np
from build_live16 import ROOT,geometry

OUT=ROOT/'build/location_robustness'

def profile(channels):
    if channels==16:
        mics,grids,pairs,lut,_,_=geometry()
        return np.array(mics),np.array(grids),pairs,np.array(lut).reshape(120,1024),32
    cfg=json.loads((ROOT/'configs/debug4_geometry.json').read_text())
    xy=np.array(cfg['microphones_mm'])/1000
    coords=np.floor(xy*16384+.5).astype(int)
    grids=np.array([(-.2+.4*x/15,-.2+.4*y/15,.3) for y in range(16) for x in range(16)])
    distances=[]
    for y in range(16):
        for x in range(16):
            px=-3277+x*6554//15;py=-3277+y*6554//15
            distances.append([math.isqrt((px-mx)**2+(py-my)**2+4915**2) for mx,my in coords])
    distances=np.array(distances);pairs=[(0,1),(0,2),(0,3),(1,3)]
    lut=np.array([((distances[:,a]-distances[:,b])*456>>12)&16383 for a,b in pairs])
    return xy,grids,pairs,lut,16

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--baseline-only',action='store_true')
    args=parser.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    cc=os.environ.get('CC') or shutil.which('gcc')
    if not cc:raise SystemExit('gcc not found: install GCC or set CC')
    compiler=Path(cc)
    os.environ['PATH']=str(compiler.parent)+os.pathsep+os.environ['PATH']
    dll=OUT/('location.dll' if os.name=='nt' else 'location.so')
    files=['sw/fw/fw_fft.c','sw/fw/fw_gcc.c','sw/fw/fw_tables.c']
    if not args.baseline_only:files+=['scripts/golden/location_quality_host.c']
    subprocess.run([str(compiler),'-std=c11','-O2','-shared','-Wall','-Wextra','-Werror','-Isw/fw',*files,'-o',str(dll)],cwd=ROOT,check=True)
    lib=ctypes.CDLL(str(dll));p16=ctypes.POINTER(ctypes.c_int16)
    lib.gcc_spectrum.argtypes=[p16,p16];lib.gcc_cached_pair.argtypes=[p16,p16,p16]
    if not args.baseline_only:
        lib.location_prepare_host.argtypes=[p16,ctypes.c_uint]
        lib.location_input_host.argtypes=[ctypes.c_int32,ctypes.c_uint64,ctypes.c_uint32]
        lib.location_quality_host.argtypes=[ctypes.POINTER(ctypes.c_int32),ctypes.c_uint,ctypes.c_uint,ctypes.c_uint,ctypes.POINTER(ctypes.c_uint32),ctypes.POINTER(ctypes.c_int32)]
    ptr=lambda x:x.ctypes.data_as(p16)
    rng=np.random.default_rng(20261013);N=4096;bins=np.arange(N//2+1)
    spectrum=np.zeros(N//2+1,dtype=complex)
    spectrum[24:837]=rng.normal(size=813)+1j*rng.normal(size=813)
    spectrum*=1/max(abs(np.fft.irfft(spectrum)))
    records=[]
    for channels in (4,16):
        mics,grids,pairs,lut,w=profile(channels)
        def source(grid,amplitude=18000):
            arrival=np.linalg.norm(grids[grid]-np.c_[mics,np.zeros(channels)],axis=1)*39062.5/343
            arrival-=arrival.min()
            return np.stack([np.rint(np.fft.irfft(spectrum*amplitude*np.exp(-2j*np.pi*bins*d/N))[1024:2048]) for d in arrival])
        def scores(frame,improved=False):
            cached=np.zeros((channels,1026),dtype=np.int16)
            for ch in range(channels):
                x=frame[ch].astype(np.int16).copy()
                if improved:lib.location_prepare_host(ptr(x),len(x))
                else:
                    peak=int(max(abs(x.astype(np.int32))));shift=0
                    while peak and peak<8192 and shift<14:peak*=2;shift+=1
                    x=(x.astype(np.int32)*(1<<shift)).astype(np.int16)
                lib.gcc_spectrum(ptr(x),ptr(cached[ch]))
            acc=np.zeros(w*w,dtype=np.int64)
            for pair,(a,b) in enumerate(pairs):
                r=np.zeros(1024,dtype=np.int16);lib.gcc_cached_pair(ptr(cached[a]),ptr(cached[b]),ptr(r))
                if channels==16:
                    r=np.r_[r[:16],r[1008:]];mask=31
                else:mask=1023
                idx=lut[pair]>>4;frac=lut[pair]&15
                v0=r[idx].astype(np.int64);v1=r[(idx+1)&mask].astype(np.int64)
                acc+=v0+(((v1-v0)*frac)>>4)
            return acc
        positions=(w*w-1,0,w-1,w*(w-1),w*(w//2)+w//2,w*(3*w//4)+w//3)
        cases=[]
        for grid in positions:
            cases.append((f'clean_{grid}',source(grid),grid,'source'))
        grid=positions[-1]
        cases += [('quiet_source',source(grid,30),grid,'source'),
                  ('dc_source',np.clip(source(grid,30)+10000,-32768,32767),grid,'source'),
                  ('silence',np.zeros((channels,1024)),None,'invalid'),
                  ('dc_only',np.full((channels,1024),10000),None,'invalid')]
        for k in range(24):
            cases.append((f'independent_noise_{k}',np.rint(rng.normal(0,30,(channels,1024))),None,'invalid'))
        for k in range(8):
            noise=rng.normal(0,20,(channels,1024))
            hum=300*np.sin(2*np.pi*60*np.arange(1024)/39062.5+rng.uniform(0,6.28))
            cases.append((f'hum_noise_{k}',np.rint(noise+hum),None,'invalid'))
        heldout=np.random.default_rng(99173+channels)
        for k in range(24):
            cases.append((f'heldout_noise_{k}',np.rint(heldout.normal(0,30,(channels,1024))),None,'invalid'))
        signal=source(grid,6000)
        sigma=float(np.sqrt(np.mean(signal*signal)/10))
        for k in range(8):
            cases.append((f'source_snr10_{k}',np.rint(signal+heldout.normal(0,sigma,signal.shape)),grid,'source'))
        broken=source(grid);broken[0]=0
        cases.append(('inactive_channel',broken,None,'invalid'))
        for name,frame,target,kind in cases:
            if channels==4 and name==f'clean_{grid}':
                (OUT/'debug4_pcm.hex').write_text(''.join(f'{int(v)&65535:04x}\n' for v in frame.astype(np.int16).T.reshape(-1)))
            before=scores(frame);best=int(before.argmax())
            radius=max(1,w//8)
            ys,xs=np.divmod(np.arange(w*w),w);gy,gx=divmod(best,w)
            far=before[(abs(xs-gx)>radius)|(abs(ys-gy)>radius)]
            runner=int(far.max());top=int(before[best]);second=int(np.partition(before,-2)[-2])
            contrast=max(0,(top-max(0,runner))*1000//max(1,top))
            rec={'channels':channels,'case':name,'kind':kind,'target_grid':target,
                 'old_grid':best,'old_valid':top>0 and top>second,'best':top,'second':second,
                 'nonlocal':runner,'contrast_permille':contrast,'score_per_pair':top/len(pairs)}
            if target is not None:rec['old_error_mm']=float(np.linalg.norm(grids[best]-grids[target])*1000)
            if not args.baseline_only:
                after=scores(frame,True)
                new_grid=int(after.argmax());values=after.astype(np.int32)
                quality=ctypes.c_uint32();nonlocal_score=ctypes.c_int32()
                reason=lib.location_quality_host(values.ctypes.data_as(ctypes.POINTER(ctypes.c_int32)),w,len(pairs),new_grid,ctypes.byref(quality),ctypes.byref(nonlocal_score))
                for x in frame.astype(np.int16).astype(np.int64):
                    reason|=lib.location_input_host(int(x.sum()),int((x*x).sum()),int(np.count_nonzero((x==32767)|(x==-32768))))
                rec.update(new_grid=new_grid,new_valid=not reason,new_reason=reason,new_contrast=quality.value,
                           new_best=int(after[new_grid]),new_score_per_pair=int(after[new_grid])/len(pairs))
                if target is not None:rec['new_error_mm']=float(np.linalg.norm(grids[new_grid]-grids[target])*1000)
            records.append(rec)
        source_rows=[r for r in records if r['channels']==channels and r['kind']=='source']
        invalid_rows=[r for r in records if r['channels']==channels and r['kind']=='invalid']
        print(json.dumps({'channels':channels,'source':source_rows,
          'noise_false_valid':sum(r['old_valid'] for r in invalid_rows),'noise_count':len(invalid_rows),
          'noise_score_per_pair_range':[min(r['score_per_pair'] for r in invalid_rows),max(r['score_per_pair'] for r in invalid_rows)],
          'noise_contrast_range':[min(r['contrast_permille'] for r in invalid_rows),max(r['contrast_permille'] for r in invalid_rows)]},indent=2))
        if not args.baseline_only:
            print('AFTER',channels,'noise_false_valid',sum(r['new_valid'] for r in invalid_rows),'/',len(invalid_rows))
            assert not any(r['new_valid'] for r in invalid_rows),invalid_rows
            assert all(r['new_valid'] and r['new_error_mm']<=30 for r in source_rows),source_rows
    (OUT/('baseline.json' if args.baseline_only else 'comparison.json')).write_text(json.dumps(records,indent=2)+'\n')
    print('LOCATION_BASELINE_PASS' if args.baseline_only else 'LOCATION_ROBUSTNESS_PASS')

if __name__=='__main__':main()
