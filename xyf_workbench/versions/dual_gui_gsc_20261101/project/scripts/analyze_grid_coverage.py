"""Exact spherical covering radius of the existing 32x32 azimuth/elevation grid."""
from pathlib import Path
import json,math
R=Path(__file__).resolve().parents[1];lat=[-math.pi/2+i*math.pi/31 for i in range(32)]
a=math.pi/32;rows=[]
# By azimuth symmetry, the farthest cell boundaries lie halfway between columns.
# At each latitude Voronoi boundary, adjacent grid rows have equal dot product.
for i in range(31):
    mid=(lat[i]+lat[i+1])/2;b=math.atan(math.cos(a)*math.tan(mid))
    dot=math.cos(b)*math.cos(lat[i])*math.cos(a)+math.sin(b)*math.sin(lat[i])
    rows.append({'row':i,'boundary_elevation_deg':math.degrees(b),'cover_radius_deg':math.degrees(math.acos(min(1,max(-1,dot))))})
data={'grid_slots':1024,'distinct_unit_directions':962,'azimuth_spacing_deg':11.25,'elevation_spacing_deg':180/31,
      'exact_max_nearest_grid_angle_deg':max(r['cover_radius_deg'] for r in rows),'scope':'SIM_GEOMETRY_ONLY angular grid, independent of array aperture','row_boundaries':rows}
out=R/'build/zynq12_integrated_plan/reports/grid_coverage.json';assert not out.exists();out.write_text(json.dumps(data,indent=2));print(json.dumps({k:v for k,v in data.items() if k!='row_boundaries'},indent=2))
