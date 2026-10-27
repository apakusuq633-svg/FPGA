/* Offline numerical equivalence and real-rate tracking regression. */
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "circular9_candidates.c"
#include "circular9_tracking.h"
static uint32_t seed=123;
static double rnd(void){seed=seed*1664525u+1013904223u;return (int32_t)seed/2147483648.0;}
static uint32_t lut_test[9*1024];
int main(void){
 assert(search_prepare_delays(lut_test));double worst=0;
 for(unsigned f=0;f<64;f++)for(unsigned trial=0;trial<1000;trial++){
  double p[64]={0},t=f/64.0;for(unsigned j=0;j<4;j++)p[j]=rnd()*10000;
  double ref=(((-.5*p[0]+1.5*p[1]-1.5*p[2]+.5*p[3])*t+(p[0]-2.5*p[1]+2*p[2]-.5*p[3]))*t+.5*(p[2]-p[0]))*t+p[1];
  double fast=search_interpolated(p,(uint16_t)f),error=fabs(fast-ref);if(error>worst)worst=error;
  assert(error<1e-8);
 }
 lut_test[0]=4096;assert(!search_prepare_delays(lut_test));lut_test[0]=0;assert(search_prepare_delays(lut_test));
 static c9_complex x[1024],y[1024],packed[1024],tw[512];double phase_error=0;
 for(unsigned k=0;k<512;k++){double sn,cs;sincos_small(6.2831853071795864769*k/1024,&sn,&cs);tw[k]=(c9_complex){cs,-sn};}
 for(unsigned trial=0;trial<32;trial++){
  memset(x,0,sizeof(x));memset(y,0,sizeof(y));
  for(unsigned k=16;k<=209;k++){x[k]=(c9_complex){rnd(),rnd()};y[k]=(c9_complex){rnd(),rnd()};x[1024-k]=zconj(x[k]);y[1024-k]=zconj(y[k]);}
  for(unsigned k=0;k<1024;k++)packed[k]=(c9_complex){x[k].re-y[k].im,x[k].im+y[k].re};
  fft(x,tw,1);fft(y,tw,1);fft(packed,tw,1);
  for(unsigned k=0;k<1024;k++){double e=fabs(packed[k].re-x[k].re)+fabs(packed[k].im-y[k].re);if(e>phase_error)phase_error=e;assert(e<1e-12);}
 }
 for(unsigned k=0;k<10000;k++){double a=fabs(rnd())+1e-10,b=fabs(rnd())+1e-10;double old=square_root(a*b),new=square_root(a)*square_root(b);assert(fabs(old-new)<1e-12*old);}
 for(unsigned stride=1;stride<=3;stride++){
  c9_tracker s={0};c9_candidate c={.grid=528,.score=1000};
  for(unsigned k=1;k<=40;k++){uint32_t end=k*8192u*stride;c9_tracks_update_interval(&s,&c,1,end-8192,end,1,1);}
  const c9_track *t=&s.tracks[0];uint32_t end=40*8192u*stride;
  int covered=c9_track_covers_range(t,end-C9_SNAPSHOT_FRAMES,end);
  assert(covered==(stride==1));if(stride==3)assert(t->observations==1);
  printf("REAL_RATE stride=%u observations=%u covered=%d synthetic_only=1\n",stride,t->observations,covered);
 }
 printf("SEARCH_EQUIVALENCE_PASS cubic_trials=64000 max_abs_error=%.12g phase_error=%.12g\n",worst,phase_error);return 0;
}
