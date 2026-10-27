"""Offline direction evaluation. No truth enters runtime candidate generation."""
import math,itertools
def direction(az,el):
 a,e=math.radians(az),math.radians(el)
 return (math.cos(e)*math.sin(a),math.sin(e),math.cos(e)*math.cos(a))
def angle(a,b):
 u=direction(a['azimuth_deg'],a.get('elevation_deg',0));v=direction(b['azimuth_deg'],b.get('elevation_deg',0))
 return math.degrees(math.acos(max(-1,min(1,sum(x*y for x,y in zip(u,v))))))
def match(outputs,sources,limit=12):
 # Maximum-cardinality angular assignment, then minimum total spherical error.
 best=[];cost=float('inf')
 for n in range(min(len(outputs),len(sources))+1):
  for oi in itertools.combinations(range(len(outputs)),n):
   for si in itertools.permutations(range(len(sources)),n):
    pairs=[{'output':i,'source':j,'error_deg':angle(outputs[i],sources[j])} for i,j in zip(oi,si)]
    if any(p['error_deg']>limit for p in pairs):continue
    c=sum(p['error_deg'] for p in pairs)
    if n>len(best) or (n==len(best) and c<cost):best,cost=pairs,c
 return best
if __name__=='__main__':
 assert abs(angle({'azimuth_deg':0,'elevation_deg':60},{'azimuth_deg':0,'elevation_deg':0})-60)<1e-9
 assert angle({'azimuth_deg':-90,'elevation_deg':90},{'azimuth_deg':90,'elevation_deg':90})<1e-6
 assert len(match([{'azimuth_deg':0}],[{'azimuth_deg':-2},{'azimuth_deg':2}]))==1
 assert len(match([{'azimuth_deg':-50},{'azimuth_deg':50}],[{'azimuth_deg':50},{'azimuth_deg':-50}]))==2
 assert match([{'azimuth_deg':0,'elevation_deg':60}],[{'azimuth_deg':0}],12)==[]
 print('SPHERICAL_ONE_TO_ONE_EVALUATION_PASS')
