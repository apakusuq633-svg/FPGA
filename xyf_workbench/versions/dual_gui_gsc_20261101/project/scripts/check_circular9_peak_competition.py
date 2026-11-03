# Offline competition regression using configured sound-hole geometry; no board.
from pathlib import Path
import json,subprocess,hashlib
R=Path(__file__).resolve().parents[1];O=R/'build/peak_competition_20261027';O.mkdir(exist_ok=True);CC=r'D:\winlibs\mingw64\bin\gcc.exe'
def run(name,args):
 p=subprocess.run([str(x) for x in args],cwd=R,text=True,capture_output=True);(O/(name+'.log')).write_text(p.stdout+p.stderr);print(p.stdout,end='',flush=True)
 if p.returncode:raise RuntimeError(name+': '+p.stderr)
 return p.stdout
run('pool_compile',[CC,'-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-const-variable','-Isw','sw/circular9_peak_competition_test.c','-lm','-o',O/'peak_pool.exe']);run('pool',[O/'peak_pool.exe'])
c=json.loads((R/'configs/circular9_array.json').read_text());xyz=c['channel_positions_m'];x=','.join(format(v[0],'.17g') for v in xyz);y=','.join(format(v[1],'.17g') for v in xyz)
s=(R/'sw/circular9_candidates_test.c').read_text();s=s.replace('double x=ch<8?.030*cos(a):0,y=ch<8?.030*sin(a):0;','double x=physical_x[ch],y=physical_y[ch];').replace('double x=ch<8?.030*cos(ring_angle):0,y=ch<8?.030*sin(ring_angle):0;','double x=physical_x[ch],y=physical_y[ch];').replace('x-.030','x-physical_x[0]')
pre='#define main archived_fixture_main\nstatic const double physical_x[9]={'+x+'};\nstatic const double physical_y[9]={'+y+'};\n'
post=r'''
#undef main
#include <time.h>
int main(void){
 make_lut();first_tone=600;tone_step=175;amplitude[0]=.05;echo_gain=0;
 const double angles[]={-85,-75,-60,0,60,75,85};
 c9_search_context ctx={.session=1,.epoch=1,.first_sample=80000,.end_sample=80000+C9_SEARCH_RAW_FRAMES,.geometry_version=1,.geometry_confirmed=1};
 unsigned checks=0;double worst=0;clock_t elapsed=0;
 for(unsigned axis=0;axis<2;axis++)for(unsigned j=0;j<7;j++){
  c9_candidate cs[3]={{.grid=528,.score=1000},{0},{0}};
  double az=axis?0:angles[j],el=axis?angles[j]:0;
  rng=0x19327561;synthesize(cs,1,az-2.812,el-2.812);
  c9_search_feedback r;clock_t begin=clock();int ok=c9_candidates_search(raw,C9_SEARCH_RAW_FRAMES,lut,&workspace,&ctx,&r);elapsed+=clock()-begin;
  assert(ok&&r.count);double truth[3]={sin(az*3.141592653589793/180)*cos(el*3.141592653589793/180),sin(el*3.141592653589793/180),cos(az*3.141592653589793/180)*cos(el*3.141592653589793/180)};
  double best=180;
  for(unsigned k=0;k<r.count;k++){double u[3];c9_candidate_unit(&r.candidates[k],u);double dot=u[0]*truth[0]+u[1]*truth[1]+u[2]*truth[2];if(dot>1)dot=1;double error=acos(dot)*180/3.141592653589793;if(error<best)best=error;}
  assert(best<6);if(best>worst)worst=best;checks++;
  assert(c9_search_feedback_current(&r,ctx.end_sample,1,1,1,0));
  printf("PHYSICAL_SYNTH axis=%u truth=%.1f count=%u first_az=%d first_el=%d best_error_deg=%.6f\n",axis,angles[j],r.count,r.candidates[0].azimuth_mdeg,r.candidates[0].elevation_mdeg,best);
 }
 printf("PHYSICAL_GEOMETRY_PASS checks=%u worst_spherical_error_deg=%.6f host_search_cpu_ms=%.3f hardware_tested=0\n",checks,worst,1000.*elapsed/CLOCKS_PER_SEC);return 0;
}
'''
source=O/'physical_geometry_fixture.c';source.write_text('#include <assert.h>\n'+pre+s+post)
run('physical_compile',[CC,'-std=c11','-O2','-DC9_CANDIDATES_TEST','-Isw','sw/circular9_candidates.c',source,'-pthread','-lm','-o',O/'physical_geometry.exe']);run('physical',[O/'physical_geometry.exe'])
files=['sw/circular9_candidates.c','sw/ps_circular9_aux.h','sw/circular9_peak_competition_test.c','sw/circular9_pipeline_test.c','configs/circular9_array.json','scripts/check_circular9_peak_competition.py']
(O/'results.json').write_text(json.dumps({'passed':True,'scope':'synthetic native only','hardware_tested':False,'ARM_timing_measured':False,'pool_permutations':240,'physical_geometry_directions':14,'reference_25deg_extraction_NMS_unchanged':True,'merge_15deg_unchanged':True,'coverage_90percent_unchanged':True,'direct_and_cross_support_checks_max':27,'projected_support_checks_max':9,'feedback_abi':'C9B2','sources':{f:hashlib.sha256((R/f).read_bytes()).hexdigest() for f in files}},indent=2))
print('PEAK_COMPETITION_OFFLINE_PASS')
