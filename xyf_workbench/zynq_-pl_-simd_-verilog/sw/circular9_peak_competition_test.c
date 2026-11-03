/* Synthetic mechanism tests, not acoustic source truth or ARM timing. */
#include <assert.h>
#include <stdio.h>
#include "circular9_candidates.c"
static c9_peak_evidence point(unsigned x,unsigned band,int score){
 c9_peak_evidence p={.candidate={.grid=16u*32u+x,.score=score},.band=band,.frames=7,.quality=100};
 p.evidence[band]=score;p.rank_evidence[band]=score;return p;
}
static void permutation(c9_peak_evidence *p,unsigned at,unsigned n,unsigned expected,unsigned *runs){
 if(at==n){int k=c9_peak_pool_best(p,n,0);assert(k>=0&&p[k].candidate.grid==expected);(*runs)++;return;}
 for(unsigned i=at;i<n;i++){
  c9_peak_evidence t=p[at];p[at]=p[i];p[i]=t;
  permutation(p,at+1,n,expected,runs);
  t=p[at];p[at]=p[i];p[i]=t;
 }
}
static void cell_edge_refinement_test(void){
 int32_t map[1024];const unsigned center=16u*32u+16u;
 const double vertices[4][2]={{.52,.1},{-.52,-.1},{.1,.52},{-.1,-.52}};
 for(unsigned t=0;t<4;t++){
  double dx=vertices[t][0],dy=vertices[t][1],gx=10000*dx-5000*dy,gy=10000*dy-5000*dx;
  for(unsigned g=0;g<1024;g++){double x=(int)(g%32)-16,y=(int)(g/32)-16;map[g]=(int32_t)(1000000+gx*x+gy*y-5000*x*x-5000*y*y+5000*x*y);}
  c9_candidate c;assert(c9_candidate_at_peak(map,center,&c)&&c.flags==C9_CANDIDATE_REFINED&&c.uncertainty_mdeg==3000u);
  int32_t az=c.azimuth_mdeg-c9_direction_azimuth_mdeg[16],el=c.elevation_mdeg-c9_direction_elevation_mdeg[16];
  assert(az>=-2814&&az<=2814&&el>=-2814&&el<=2814);
  if(t<2)assert(az>2800||az< -2800);else assert(el>2800||el< -2800);
 }
 for(unsigned g=0;g<1024;g++){double x=(int)(g%32)-16,y=(int)(g/32)-16;map[g]=(int32_t)(1000000+5000*x-1000*y-5000*x*x-5000*y*y+5000*x*y);}
 c9_candidate c;assert(c9_candidate_at_peak(map,center,&c)&&!c.flags); /* vertex .6,.2 remains rejected. */
 for(unsigned g=0;g<1024;g++)map[g]=1000000;
 assert(c9_candidate_at_peak(map,center,&c)&&!c.flags); /* flat map never invents a fine angle. */
 assert(c9_candidate_at_peak(map,0,&c)&&!c.flags); /* array boundary unchanged. */
 puts("CELL_EDGE_REFINEMENT_PASS shared_edge=4 half_cell_bounded=1 far_vertex_flat_boundary_rejected=1 uncertainty_unchanged=1");
}
int main(void){cell_edge_refinement_test();
 /* A65degree low-band peak must not win solely because band0 is visited first.
  * Independent85degree evidence in two other bands is ranked jointly. */
 c9_peak_evidence p[5]={point(27,0,1000000),point(31,1,900000),point(31,2,880000),point(12,0,700000),point(5,1,650000)};
 p[1].rank_evidence[2]=880000;p[2].rank_evidence[1]=900000;
 unsigned runs=0;permutation(p,0,5,16*32+31,&runs);assert(runs==120);
 /* This is not a preference for larger angles or a particular frequency. */
 p[0]=point(31,0,1000000);p[1]=point(27,1,900000);p[2]=point(27,2,880000);p[1].rank_evidence[2]=880000;p[2].rank_evidence[1]=900000;
 permutation(p,0,5,16*32+27,&runs);assert(runs==240);
 c9_peak_evidence independent[3]={point(5,0,300000),point(16,1,400000),point(27,2,500000)};
 unsigned excluded=0;for(unsigned i=0;i<3;i++){int k=c9_peak_pool_best(independent,3,excluded);assert(k>=0);excluded|=1u<<k;}assert(c9_peak_pool_best(independent,3,excluded)<0);
 /* A direction repeated in one band must not receive two-band credit. */
 c9_peak_evidence dup[3]={point(31,0,900000),point(31,0,850000),point(5,1,1000000)};
 assert(c9_peak_pool_best(dup,3,0)==2);
 unsigned first,last;
 assert(c9_support_component(0x15u,7,&first,&last)==3&&first==0&&last==4);
 assert(c9_support_component(0x49u,7,&first,&last)==1); /*0,3,6 have real holes.*/
 assert(c9_support_component(0x23u,7,&first,&last)==2); /*0,1 then isolated5.*/
 assert(!c9_support_component(0x80u,7,&first,&last)); /*outside recorded windows.*/
 puts("PEAK_POOL_PASS permutations=240 independent_sources=3 same_band_double_credit=0 angle_preference=0");return 0;
}
