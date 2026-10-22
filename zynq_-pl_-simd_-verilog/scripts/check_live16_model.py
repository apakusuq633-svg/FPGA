"""Create acoustic vectors and compare cached spectra against pairwise firmware."""
from pathlib import Path
import ctypes,json,os,subprocess
import numpy as np
from build_live16 import ROOT,OUT,geometry
def main():
    dest=OUT.parent;dest.mkdir(parents=True,exist_ok=True)
    gcc=Path('D:/winlibs/mingw64/bin/gcc.exe');os.environ['PATH']=str(gcc.parent)+os.pathsep+os.environ['PATH']
    lib=dest/'golden.dll'
    subprocess.run([str(gcc),'-std=c11','-O2','-shared','-Wall','-Wextra','-Werror','-Isw/fw',
                    'sw/fw/fw_fft.c','sw/fw/fw_gcc.c','sw/fw/fw_tables.c','scripts/golden/location_quality_host.c','-o',str(lib)],cwd=ROOT,check=True)
    model=ctypes.CDLL(str(lib));p16=ctypes.POINTER(ctypes.c_int16)
    def ptr(x):return x.ctypes.data_as(p16)
    mics,grids,pairs,lut,steer,maxlag=geometry();lut=np.array(lut).reshape(120,1024)
    model.gcc_spectrum.argtypes=[p16,p16];model.gcc_cached_pair.argtypes=[p16,p16,p16]
    model.location_prepare_host.argtypes=[p16,ctypes.c_uint]
    rng=np.random.default_rng(16032);N=4096
    freq=np.zeros(N//2+1,dtype=np.complex128)
    freq[24:837]=rng.normal(size=813)+1j*rng.normal(size=813)
    source=np.fft.irfft(freq);freq*=18000/max(abs(source))
    cases=[]
    for case,grid in enumerate((773,250)):
        pos=np.array(grids[grid]);micpos=np.array([(x,y,0) for x,y in mics])
        arrival=np.linalg.norm(pos-micpos,axis=1)*39062.5/343;arrival-=arrival.min()
        frame=np.stack([np.rint(np.fft.irfft(freq*np.exp(-2j*np.pi*np.arange(N//2+1)*d/N))[1024:2048]).astype(np.int16) for d in arrival])
        spectra=np.zeros((16,1026),dtype=np.int16)
        for ch in range(16):
            x=frame[ch].copy();model.location_prepare_host(ptr(x),len(x))
            model.gcc_spectrum(ptr(x),ptr(spectra[ch]))
        acc=np.zeros(1024,dtype=np.int64);short=np.zeros((120,32),dtype=np.int16)
        for pair,(a,b) in enumerate(pairs):
            corr=np.zeros(1024,dtype=np.int16);model.gcc_cached_pair(ptr(spectra[a]),ptr(spectra[b]),ptr(corr))
            short[pair,:16]=corr[:16];short[pair,16:]=corr[1008:]
            idx=lut[pair]>>4;frac=lut[pair]&15
            v0=short[pair,idx].astype(np.int64);v1=short[pair,(idx+1)&31].astype(np.int64)
            acc+=v0+(((v1-v0)*frac)>>4)
            # The compact ring must equal the full 1024-sample lookup at every grid.
            signedidx=np.where(idx>=16,idx-32,idx)&1023
            full0=corr[signedidx].astype(np.int64);full1=corr[(signedidx+1)&1023].astype(np.int64)
            assert np.array_equal(v0+(((v1-v0)*frac)>>4),full0+(((full1-full0)*frac)>>4))
        best=int(acc.argmax());distance=float(np.linalg.norm(np.array(grids[best])-pos))
        assert distance<=0.03,(grid,best,distance)
        # Pairwise path and cached path must produce the same GCC for a distant pair.
        xa=frame[7].copy();xb=frame[15].copy()
        for x in (xa,xb):
            model.location_prepare_host(ptr(x),len(x))
        model.gcc_load_a(ptr(xa));model.gcc_load_b(ptr(xb));old=np.zeros(1024,dtype=np.int16);lag=ctypes.c_int32()
        model.gcc_finish(ptr(old),ctypes.byref(lag));new=np.zeros(1024,dtype=np.int16)
        model.gcc_cached_pair(ptr(spectra[7]),ptr(spectra[15]),ptr(new));assert np.array_equal(old,new)
        def hexfile(name,values,width): (dest/name).write_text(''.join(f'{int(v)&((1<<(4*width))-1):0{width}x}\n' for v in values))
        hexfile(f'scene{case}_pcm.hex',frame.T.reshape(-1),4)
        hexfile(f'scene{case}_r.hex',short.reshape(-1),4)
        hexfile(f'scene{case}_p.hex',acc,8)
        packed=(spectra[:,0::2].astype(np.int64)&65535)|((spectra[:,1::2].astype(np.int64)&65535)<<16)
        hexfile(f'scene{case}_spectra.hex',packed.reshape(-1),8)
        delays=steer[:];vals=np.array(delays).reshape(16,1024)[:,best];q=np.where(vals>>4>=512,vals-16384,vals)<<12
        comp=q-q.min();hexfile(f'scene{case}_comp.hex',comp,8)
        cases.append({'source_grid':grid,'expected_grid':best,'error_mm':distance*1000,
                      'best':int(acc[best]),'second':int(np.partition(acc,-2)[-2]),'comp_q16':comp.tolist()})
        print(f'LIVE16_MODEL_PASS case={case} source_grid={grid} best_grid={best} error_mm={distance*1000:.3f} score={acc[best]}')
    (dest/'scenes.json').write_text(json.dumps(cases,indent=2)+'\n')
if __name__=='__main__':main()
