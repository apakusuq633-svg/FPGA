"""Independent angle/LUT and scalar SRP checks for the 9-mic direction profile.

These tests verify numeric conventions and generated C tables.  They cannot
establish physical angular resolution or separate real overlapping sources.
"""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess

from build_circular9 import direction_grid, direction_header, geometry, plane_wave_delays

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'build/circular9_direction_checks'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    c = json.loads((ROOT/'configs/circular9_array.json').read_text(encoding='utf-8'))
    srp, steer, pairs = geometry(c)
    vectors, azimuth, elevation = direction_grid(c)
    assert len(vectors) == len(set(vectors)) == 1024
    assert all(abs(sum(v*v for v in u)-1) < 4e-16 and u[2] > 0 for u in vectors)
    assert azimuth == elevation and azimuth[0] == -87.1875 and azimuth[-1] == 87.1875
    assert (ROOT/'sw/circular9_direction.h').read_text(encoding='ascii') == direction_header(c)
    comparisons = 0
    for g in range(1024):
        # Derive the direction independently from the angular cell index.
        a = (2*(g%32)+1-32)*math.pi/64
        e = (2*(g//32)+1-32)*math.pi/64
        unit = (math.cos(e)*math.sin(a), math.sin(e), math.cos(e)*math.cos(a))
        for index, (i, j) in enumerate(pairs):
            baseline = [c['channel_positions_m'][i][k]-c['channel_positions_m'][j][k] for k in range(3)]
            truth = -sum(baseline[k]*unit[k] for k in range(3))*c['sample_rate_hz']/c['sound_speed_m_s']
            q = srp[index*1024+g]
            if q >= c['r_len']*8:
                q -= c['r_len']*16
            assert -1/16-1e-12 <= q/16-truth <= 1e-12, (g, i, j)
            comparisons += 1
        for m in range(9):
            truth = sum((c['channel_positions_m'][m][k]-c['channel_positions_m'][0][k])*unit[k]
                        for k in range(3))*c['sample_rate_hz']/c['sound_speed_m_s']
            q = steer[m*1024+g]
            if q >= 8192:
                q -= 16384
            assert -1/16-1e-12 <= q/16-truth <= 1e-12, (g, m)
            comparisons += 1
    assert all(d == 0 for d in plane_wave_delays(c, 0, 0))
    assert plane_wave_delays(c, 45, 0)[5] < plane_wave_delays(c, 45, 0)[2]
    assert plane_wave_delays(c, 0, 45)[7] < plane_wave_delays(c, 0, 45)[0]
    # A flat array has exactly identical delays for mirror directions across
    # its board plane; the frontend hemisphere is an installation constraint.
    for u in vectors[::31]:
        reflected = (u[0],u[1],-u[2])
        for m in c['channel_positions_m']:
            assert sum(m[k]*u[k] for k in range(3)) == sum(m[k]*reflected[k] for k in range(3))
    negatives = 0
    for name, value in [('scan_model','spherical_distance'), ('plane_z_m',.3),
                        ('grid_half_m',.2), ('front_hemisphere_only',False),
                        ('planar_front_back_ambiguous',False), ('grid_w',31)]:
        bad = dict(c); bad[name] = value
        try:
            geometry(bad)
        except ValueError:
            negatives += 1
        else:
            raise AssertionError('invalid direction profile accepted: '+name)
    # Cell corners are bounded by 3.98 degrees on the unit sphere.  This is
    # grid quantization only, never a promise about aperture/noise accuracy.
    maximum_quantization_deg = 0
    for row in range(33):
        for column in range(33):
            a, e = -math.pi/2+column*math.pi/32, -math.pi/2+row*math.pi/32
            u = (math.cos(e)*math.sin(a), math.sin(e), math.cos(e)*math.cos(a))
            dot = max(sum(u[k]*v[k] for k in range(3)) for v in vectors)
            maximum_quantization_deg = max(maximum_quantization_deg,
                math.degrees(math.acos(min(1,max(-1,dot)))))
    assert maximum_quantization_deg < 3.98
    # Scalar GCC/SRP from an analytic bandlimited plane wave, without FFT RTL.
    # Values are independently generated and linearly interpolated at Q4 LUT delays.
    localization = []
    for source in [16*32+16, 12*32+10, 20*32+22, 4*32+17, 30*32+15]:
        u = vectors[source]
        delays = [-sum(m[k]*u[k] for k in range(3))*c['sample_rate_hz']/c['sound_speed_m_s']
                  for m in c['channel_positions_m']]
        correlations = [[sum(math.cos(2*math.pi*k*(lag-(delays[i]-delays[j]))/1024)
                             for k in range(2,53)) for lag in range(-32,32)]
                        for i,j in pairs]
        scores = []
        for g in range(1024):
            score = 0
            for index, r in enumerate(correlations):
                q = srp[index*1024+g]
                if q >= 512:
                    q -= 1024
                lag, fraction = divmod(q,16)
                score += r[lag+32]*(16-fraction)/16+r[lag+33]*fraction/16
            scores.append(score)
        best = max(range(1024),key=scores.__getitem__)
        error = math.degrees(math.acos(min(1,sum(u[k]*vectors[best][k] for k in range(3)))))
        assert error < 6, (source,best,error)
        localization.append(dict(source_grid=source,best_grid=best,spherical_error_deg=error))
    # Test exact exported C integer tables, angle sign convention, overflow,
    # angular-neighborhood behavior and out-of-range rejection.
    source = OUT/'direction_test.c'
    source.write_text('''#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "circular9_direction.h"
int main(void){unsigned g,h;int32_t a,e;int64_t d;
 assert(!c9_direction_from_grid(1024,&a,&e));
 assert(!c9_direction_within(1024,1024,-1073741824));
 assert(c9_direction_from_grid(0,&a,&e)&&a==-87188&&e==-87188);
 assert(c9_direction_from_grid(1023,&a,&e)&&a==87188&&e==87188);
 assert(c9_direction_from_grid(512+16,&a,&e)&&a>0&&e>0);
 for(g=0;g<1024;g++){
  assert(c9_direction_from_grid(g,0,0));
  d=c9_direction_dot_q30(g,g);assert(d>=1073741822&&d<=1073741824);
  for(h=0;h<1024;h+=31){
   double ref=0;unsigned k;for(k=0;k<3;k++)ref+=(double)c9_direction_unit_q30[g][k]*c9_direction_unit_q30[h][k]/1152921504606846976.0;
   assert(fabs((double)c9_direction_dot_q30(g,h)/1073741824.0-ref)<3e-9);
  }
 }
 /* Near-pole azimuth columns are close on the sphere; rectangular NMS fails. */
 assert(c9_direction_within(0,31,1067859754)); /* cos(6 degrees) */
 assert(!c9_direction_within(16*32,16*32+31,1067859754));
 puts("CIRCULAR9_DIRECTION_C_PASS");return 0;
}
''',encoding='ascii')
    env = os.environ.copy();env['PATH']='C:/msys64/ucrt64/bin;'+env['PATH']
    with (OUT/'c_test.log').open('w') as log:
        subprocess.run(['gcc','-std=c99','-O2','-Wall','-Wextra','-Werror','-Isw',str(source),'-o',str(OUT/'direction_test.exe')],
                       cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        subprocess.run([str(OUT/'direction_test.exe')],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    files = [ROOT/'configs/circular9_array.json', ROOT/'scripts/build_circular9.py',
             ROOT/'sw/circular9_direction.h', Path(__file__)]
    result = dict(status='PASS_DIGITAL',board_tested=False,scan_model=c['scan_model'],
        direction_grid=c['direction_grid'],unique_directions=1024,range_scan=False,
        lut_comparisons=comparisons,negative_controls=negatives,
        grid_quantization_bound_deg=maximum_quantization_deg,scalar_localization=localization,
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    (OUT/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('CIRCULAR9_DIRECTION_PASS directions=1024 range_scan=0 board=UNVERIFIED')


if __name__ == '__main__':
    main()
