"""Four periodic overlapping windows, full fixed-point FFT/GCC/SRP golden."""
from pathlib import Path
import sys,json
import numpy as np
R=Path(__file__).resolve().parents[1];O=R/'build/strict_overlap/vectors';O.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(R/'scripts/golden'))
from fw_fft_model import twiddle_q14,fft_fixed
from fw_gcc_model import ifft_fixed
from fw_acou_model import cplx_op,vphat,pack
from pdm12_geometry import PAIRS
re,im=twiddle_q14();hann=8192-(re[np.minimum(np.arange(1024),1024-np.arange(1024))]>>1)
rng=np.random.default_rng(20261015);base=rng.integers(-14000,14001,2048,dtype=np.int64)
pcm=np.stack([np.roll(base,ch-5)+ch*41 for ch in range(12)],axis=1)
pcm[:,10]=(np.arange(2048)%2)*65535-32768
pcm[:,11]=1234
def save(name,v,w=8):(O/name).write_text(''.join(f'{int(x)&((1<<(4*w))-1):0{w}x}\n' for x in v))
save('pcm.hex',pcm.reshape(-1),4);save('hann.hex',hann,4)
lut=[int(x,16) for x in (R/'build/pdm12_test_srp/lut.hex').read_text().split()]
save('lut.hex',lut)
spectra=[];phis=[];correlations=[];scores=[];stats=[];prepared_all=[]
for f in range(4):
 channels=[];rs=[]
 for ch in range(12):
  raw=pcm[(np.arange(1024)+f*512)%2048,ch]
  s=int(raw.sum());e=int((raw*raw).sum());stats.extend([s&0xffffffff,e&0xffffffff,e>>32,int(np.abs(raw).max()),int(((raw==-32768)|(raw==32767)).sum())])
  mean=abs(s)//1024*(-1 if s<0 else 1);center=raw-mean
  bound=int(np.abs(center).max());left=right=0
  while bound and bound<8192 and left<14:bound*=2;left+=1
  while bound>32767:bound=(bound+1)//2;right+=1
  prepared=(((center*(1<<left))>>right).astype(np.int16).astype(np.int64)*hann)>>14
  prepared_all.extend(prepared)
  z=fft_fixed(prepared,re,im);p=np.array([pack(int(v.real),int(v.imag)) for v in z],dtype=np.uint32)
  channels.append(p);spectra.extend(p)
 for a,b in PAIRS:
  phi=np.zeros(513,dtype=np.uint32);phi[6:214]=vphat(cplx_op(channels[a][6:214],channels[b][6:214],True));phis.extend(phi)
  pr=(phi.astype(np.int64)&65535);pr=(pr+32768)%65536-32768
  pi=phi.astype(np.int64)>>16;pi=(pi+32768)%65536-32768
  corr=ifft_fixed(pr,pi,re,im).astype(np.int16);rs.append(corr.astype(np.int64))
  correlations.extend(pack(int(corr[k]),int(corr[k+1])) for k in range(0,1024,2))
 for g in range(1024):
  acc=0
  for p,r in enumerate(rs):
   v=lut[p*1024+g];k=v>>4;j=(k+1)&31
   a=int(r[k if k<16 else k+992]);b=int(r[j if j<16 else j+992]);acc+=a+(((b-a)*(v&15))>>4)
  scores.append(acc&0xffffffff)
for name,data in [('spectra',spectra),('phi',phis),('correlation',correlations),('scores',scores),('stats',stats)]:save(name+'.hex',data)
save('prepared.hex',prepared_all,4)
(O/'manifest.json').write_text(json.dumps({'role':'TEST_GEOMETRY_ONLY','physical_geometry':None,'period_samples':2048,'window':1024,'hop':512,'channels':12,'pairs':66,'golden_windows':4,'seed':20261015},indent=2))
print('OVERLAP_VECTORS_PASS four_windows=0_512_1024_1536 full12_fft66_gcc1024_srp')
