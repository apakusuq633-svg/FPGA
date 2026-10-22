"""Independent fixed-point references for geometry-free twelve-channel signals."""
from pathlib import Path
import sys,json,ctypes,subprocess
import numpy as np
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'build/pdm12_numeric';OUT.mkdir(exist_ok=True)
sys.path.insert(0,str(ROOT/'scripts/golden'))
from fw_fft_model import twiddle_q14,fft_fixed
from fw_gcc_model import ifft_fixed
from fw_acou_model import cplx_op,vphat,pack
from pdm12_geometry import PAIRS
re,im=twiddle_q14();win=8192-(re[np.minimum(np.arange(1024),1024-np.arange(1024))]>>1)
def words(x):return [pack(x[k],x[k+1]) for k in range(0,len(x),2)]
def save(name,v,width=8):(OUT/name).write_text(''.join(f'{int(x)&((1<<(width*4))-1):0{width}x}\n' for x in v))
pcm=[];spectra=[];phis=[];cross=[];corr=[];scalar_deltas=[];statistics=[]
rng=np.random.default_rng(20261014);noise=rng.integers(-12000,12001,1024,dtype=np.int64)
library=OUT/'scalar.so'
subprocess.run(['gcc','-O2','-shared','-fPIC','-DFW_SIMD_PHAT_MODEL=1','-DFW_GCC_AUDIT=1',
 'sw/fw/fw_fft.c','sw/fw/fw_gcc.c','sw/fw/fw_tables.c','-o',str(library)],cwd=ROOT,check=True)
lib=ctypes.CDLL(str(library));p=ctypes.POINTER(ctypes.c_int16)
lib.fft_init();lib.gcc_cached_ring.argtypes=[p,p,p];lib.gcc_audit_phi.argtypes=[p]
lib.gcc_cached_pair.argtypes=[p,p,p]
ptr=lambda a:a.ctypes.data_as(p)
for frame in range(4):
    channels=[]
    for ch in range(12):
        raw=np.roll(noise,ch-6).copy()
        if frame==1:raw=raw//512+20000 if ch!=11 else np.full(1024,1234,dtype=np.int64)
        if frame==2:raw=rng.integers(-32768,32768,1024,dtype=np.int64)
        if frame==3:raw=np.zeros(1024,dtype=np.int64)
        pcm.extend(raw)
        energy=int(np.sum(raw*raw));statistics.extend([int(raw.sum())&0xffffffff,energy&0xffffffff,energy>>32,
            int(np.abs(raw).max()),int(np.sum((raw==-32768)|(raw==32767)))])
        mean=int(int(raw.sum())/1024);center=raw-mean;peak=int(np.abs(center).max());bound=peak;left=right=0
        while bound and bound<8192 and left<14:bound*=2;left+=1
        while bound>32767:bound=(bound+1)//2;right+=1
        prepared=(((center*(1<<left))>>right).astype(np.int16).astype(np.int64)*win)>>14
        spectrum=fft_fixed(prepared,re,im)
        channels.append(np.array([pack(int(z.real),int(z.imag)) for z in spectrum],dtype=np.uint32))
        spectra.extend(channels[-1])
    for a,b in PAIRS:
        z=cplx_op(channels[a][6:214],channels[b][6:214],True);cross.extend(z)
        phi=np.zeros(513,dtype=np.uint32);phi[6:214]=vphat(z);phis.extend(phi)
        pr=phi.astype(np.int64)&65535;pr=(pr+32768)%65536-32768
        pi=(phi.astype(np.int64)>>16);pi=(pi+32768)%65536-32768
        full=ifft_fixed(pr,pi,re,im).astype(np.int16);corr.extend(words(full))
        aa=channels[a].view(np.int16).copy();bb=channels[b].view(np.int16).copy();got=np.zeros(1024,dtype=np.int16);got_phi=np.zeros(1026,dtype=np.int16)
        lib.gcc_cached_ring(ptr(aa),ptr(bb),ptr(got));lib.gcc_audit_phi(ptr(got_phi))
        assert np.array_equal(got_phi.view(np.uint32),phi),'scalar PHAT vs independent LUT model'
        assert np.array_equal(got,full),'scalar full IFFT vs independent fixed model'
        exact=np.zeros(1024,dtype=np.int16);lib.gcc_cached_pair(ptr(aa),ptr(bb),ptr(exact))
        scalar_deltas.append({'frame':frame+1,'a':a,'b':b,
            'max_corr_lsb':int(np.abs(got.astype(np.int64)-exact).max()),
            'lut_peak_index':int(np.argmax(np.abs(got.astype(np.int64)))),
            'exact_div_peak_index':int(np.argmax(np.abs(exact.astype(np.int64))))})
save('pcm.hex',pcm,4);save('spectra.hex',spectra);save('phi.hex',phis);save('cross.hex',cross);save('full_corr.hex',corr);save('stats.hex',statistics)
(OUT/'vectors.json').write_text(json.dumps({'role':'TEST_SIGNAL_DELAYS','physical_geometry':None,'frames':4,
 'pairs':PAIRS,'scenarios':['delayed broadband','weak+DC and constant channel','independent full-range PCM','silence'],
 'scalar_python_errors':0,'lut_vs_exact_division':scalar_deltas,
 'max_lut_vs_exact_corr_lsb':max(p['max_corr_lsb'] for p in scalar_deltas),
 'ring_output_lags':list(range(16))+list(range(-16,0))},indent=2)+'\n')
print('PDM12_NUMERIC_VECTORS_PASS frames=4 pairs=264 scalar_python_error=0 no_geometry=1')
