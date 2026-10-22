"""Independent integer polynomial coefficients and sample vectors for cubic RTL."""
from pathlib import Path
import argparse,json,subprocess
import numpy as np
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--generate-coeff',action='store_true');a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=True)
def coeff(f):
    # Exact rationals at f/16; round nearest ties to even, DC normalized.
    from fractions import Fraction
    t=Fraction(f,16)
    c=[-t*(1-t)*(2-t)/6,(1+t)*(1-t)*(2-t)/2,(1+t)*t*(2-t)/2,-(1+t)*t*(1-t)/6]
    v=[round(x*16384) for x in c];v[1]+=16384-sum(v);return v
if a.generate_coeff:
    lines=['function signed [15:0] lagrange_coeff;','input [3:0] frac; input [1:0] which;','begin case ({frac,which})']
    for f in range(16):
        for k,c in enumerate(coeff(f)):lines.append(f"6'd{f*4+k}:lagrange_coeff={'-' if c<0 else ''}16'sd{abs(c)};")
    lines+=['default:lagrange_coeff=0;','endcase end endfunction']
    (R/'rtl/beamformer/das_lagrange_coeff.vh').write_text('\n'.join(lines)+'\n')
rng=np.random.default_rng(20261015);x=rng.integers(-32768,32768,(2048,12),dtype=np.int16)
x[100:104]=32767;x[104:108]=-32768;x[108:112]=0
expected=[]
for n in range(len(x)):
    delays=[m*3*16+(m*7+n//128)%16 for m in range(12)]
    total=0
    for ch,d in enumerate(delays):
        s=sum(int(x[n-d//16-k,ch])*c if n>=d//16+k else 0 for k,c in enumerate(coeff(d%16)))
        y=(s+8192)//16384 if s>=0 else -((-s+8192)//16384)
        total+=min(32767,max(-32768,y))
    z=total+6;expected.append(z//12)
np.savetxt(O/'pcm.hex',x.reshape(-1).astype(np.uint16),fmt='%04x')
np.savetxt(O/'expected.hex',np.array(expected).astype(np.uint16),fmt='%04x')
bench=(R/'tb/tb_das_precision.v').read_text().replace('VECTOR_DIR',O.as_posix())
(O/'tb.v').write_text(bench)
for cmd,name in [(['iverilog','-g2012','-Irtl','-s','tb_das_precision','-o',str(O/'sim'),str(R/'rtl/beamformer/rv32_das_stream.v'),str(O/'tb.v')],'compile'),(['vvp',str(O/'sim')],'run')]:
    q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/(name+'.log')).write_text(q.stdout+q.stderr)
    assert q.returncode==0,(name,q.stdout+q.stderr)
    if name=='run':assert 'DAS_PRECISION_PASS' in q.stdout
print((O/'run.log').read_text())
(O/'metrics.json').write_text(json.dumps({'status':'PASS','samples':2048,'channels':12,'fractions':16,'reference':'exact rational Q14 coefficients, symmetric rounding, per-channel saturation'},indent=2))
