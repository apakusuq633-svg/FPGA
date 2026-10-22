"""Synthetic geometry only. Never writes production_array.json or production LUT."""
from pathlib import Path
import math,itertools,json
R=Path(__file__).resolve().parents[1];O=R/'build/pdm12_test_srp';O.mkdir(parents=True,exist_ok=True)
coords=[(0,a,b) for a in (.01,.03) for b in (.01,.03)]+[(a,0,b) for a in (.01,.03) for b in (.01,.03)]+[(a,b,0) for a in (.01,.03) for b in (.01,.03)]
directions=[]
for el in range(32):
 e=-math.pi/2+el*math.pi/31
 for az in range(32):
  a=az*2*math.pi/32;directions.append((math.cos(e)*math.cos(a),math.cos(e)*math.sin(a),math.sin(e)))
lut=[]
for i,j in itertools.combinations(range(12),2):
 for u in directions:
  delay=-sum((coords[i][d]-coords[j][d])*u[d] for d in range(3))*39062.5/343
  q=math.floor(delay*16);assert -16<=q//16<=14
  lut.append(((q//16)&31)*16+(q&15))
words=[int(x,16) for x in (R/'build/pdm12_numeric/full_corr.hex').read_text().split()]
values=[]
for w in words:
 for v in (w&65535,w>>16):values.append((v+32768)%65536-32768)
scores=[]
for f in range(4):
 for g in range(1024):
  score=0
  for p in range(66):
   q=lut[p*1024+g];idx=q>>4;frac=q&15
   lag0=idx if idx<16 else idx+992;idx1=(idx+1)&31;lag1=idx1 if idx1<16 else idx1+992
   a=values[(f*66+p)*1024+lag0];b=values[(f*66+p)*1024+lag1]
   score+=a+(((b-a)*frac)>>4)
  scores.append(score&0xffffffff)
for name,data in [('lut',lut),('scores',scores)]:
 (O/(name+'.hex')).write_text(''.join(f'{v:08x}\n' for v in data))
(O/'geometry.json').write_text(json.dumps({'role':'TEST_GEOMETRY_ONLY','physical_coordinates_confirmed':False,'coordinates_m':coords,'grid_directions':directions,'pairs':66,'production_geometry_enabled':False},indent=2))
print('TEST_SRP_VECTORS_PASS frames=4 pairs=66 grid=1024 TEST_GEOMETRY_ONLY')
