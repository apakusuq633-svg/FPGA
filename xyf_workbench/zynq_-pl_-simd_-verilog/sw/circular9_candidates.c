#include "circular9_candidates.h"
#include "circular9_decimator.h"
#include "circular9_direction.h"
#include "circular9_diagnosis.h" /* One fixed carrier definition for readiness. */
#include <string.h>
_Static_assert((C9_HISTORY_FRAMES&(C9_HISTORY_FRAMES-1u))==0,"power-of-two history");
_Static_assert(sizeof(c9_history)<=32u*1024u*1024u,"shared history reservation");

/* Both cores map the shared history as noncached. Acquire/release additionally
 * order the 16/32-bit atomic accesses on Cortex-A9 and keep native SPSC tests
 * within the C memory model. Invalidate BEFORE writing PCM, not afterwards. */
#define LOAD(p) __atomic_load_n((p),__ATOMIC_ACQUIRE)
#define STORE(p,v) __atomic_store_n((p),(v),__ATOMIC_RELEASE)
static uint32_t head_begin(c9_history *s){
 uint32_t g=LOAD(&s->head_guard);STORE(&s->head_guard,g+1u);
 /* A release store alone orders earlier writes, not following payload writes.
  * This barrier makes invalidation visible BEFORE any protected mutation. */
 __atomic_thread_fence(__ATOMIC_SEQ_CST);return g+2u;
}
static void head_end(c9_history *s,uint32_t g){STORE(&s->head_guard,g);}
void c9_history_init(c9_history *s){
 /* No slot can be observed until count becomes nonzero. Avoid clearing 28 MiB
  * in the real-time producer; even uninitialized slot guards are never read
  * until that slot has first been explicitly initialized by the writer. */
 STORE(&s->head_guard,0);STORE(&s->end,0);STORE(&s->count,0);
 STORE(&s->epoch,0);STORE(&s->session,1);
}
void c9_history_reset(c9_history *s){
 uint32_t g=head_begin(s);STORE(&s->count,0);
 STORE(&s->session,LOAD(&s->session)+1u);head_end(s,g);
}
void c9_history_push(c9_history *s,const uint32_t w[16]){
 uint32_t g=head_begin(s),seq=w[1],count=LOAD(&s->count);
 if(count&&(seq!=LOAD(&s->end)||w[14]!=LOAD(&s->epoch))){
  count=0;STORE(&s->session,LOAD(&s->session)+1u);
 }
 c9_history_frame *f=&s->frames[seq&(C9_HISTORY_FRAMES-1u)];
 /* Global seq advances per packet, so use it to initialize a fresh guard
  * without reading uninitialized RAM. Every rewrite differs by capacity. */
 uint32_t version=(seq/C9_HISTORY_FRAMES)*2u+1u;
 STORE(&f->guard,version);
 __atomic_thread_fence(__ATOMIC_SEQ_CST);
 STORE(&f->sequence,seq);
 for(unsigned i=0;i<9;i++)
  __atomic_store_n(&f->pcm[i],(int16_t)(uint16_t)(w[8+i/2]>>(16*(i&1))),__ATOMIC_RELAXED);
 STORE(&f->guard,version+1u);
 STORE(&s->epoch,w[14]);STORE(&s->count,count<C9_HISTORY_FRAMES?count+1u:count);
 STORE(&s->end,seq+1u);head_end(s,g);
}
int c9_history_info(const c9_history *s,uint32_t *end,uint32_t *count,
 uint32_t *epoch,uint32_t *session){
 for(unsigned tries=0;tries<8;tries++){
  uint32_t g=LOAD(&s->head_guard);if(g&1u)continue;
  uint32_t en=LOAD(&s->end),n=LOAD(&s->count),ep=LOAD(&s->epoch),se=LOAD(&s->session);
  if(LOAD(&s->head_guard)!=g)continue;
  if(end)*end=en;
  if(count)*count=n;
  if(epoch)*epoch=ep;
  if(session)*session=se;
  return 1;
 }
 return 0;
}
int c9_history_copy(const c9_history *s,int16_t (*pcm)[9],uint32_t frames,
 uint32_t requested_end,uint32_t *first,uint32_t *epoch,uint32_t *session){
 uint32_t end,count,e,se;
 if(!s||!pcm||!first||!epoch||!session||!frames||(frames&3u)||frames>C9_HISTORY_FRAMES||
    (requested_end&3u)||!c9_history_info(s,&end,&count,&e,&se))return 0;
 uint32_t distance=end-requested_end;
 if(distance>=0x80000000u||distance>C9_HISTORY_FRAMES||frames>count||distance>count-frames)return 0;
 uint32_t start=requested_end-frames;
 for(unsigned i=0;i<frames;i++){
  uint32_t seq=start+i;
  const c9_history_frame *f=&s->frames[seq&(C9_HISTORY_FRAMES-1u)];
  uint32_t g=LOAD(&f->guard);
  if((g&1u)||LOAD(&f->sequence)!=seq)return 0;
  for(unsigned ch=0;ch<9;ch++)pcm[i][ch]=__atomic_load_n(&f->pcm[ch],__ATOMIC_RELAXED);
  __atomic_thread_fence(__ATOMIC_ACQUIRE);
  if(LOAD(&f->guard)!=g||LOAD(&f->sequence)!=seq)return 0;
 }
 uint32_t end2,count2,e2,se2;
 if(!c9_history_info(s,&end2,&count2,&e2,&se2)||e2!=e||se2!=se||
    (uint32_t)(end2-start)>C9_HISTORY_FRAMES||count2<frames||
    (uint32_t)(end2-requested_end)>count2-frames)return 0;
 *first=start;*epoch=e;*session=se;return 1;
}
int c9_history_snapshot_at(const c9_history *s,int16_t (*pcm)[9],uint32_t requested_end,
 uint32_t *first,uint32_t *epoch,uint32_t *session){
 return c9_history_copy(s,pcm,C9_SNAPSHOT_FRAMES,requested_end,first,epoch,session);
}
int c9_history_snapshot(const c9_history *s,int16_t (*pcm)[9],uint32_t *first,
 uint32_t *epoch,uint32_t *session){
 uint32_t end;
 return s&&c9_history_info(s,&end,NULL,NULL,NULL)&&
  c9_history_snapshot_at(s,pcm,end&~3u,first,epoch,session);
}

static int candidate_local_maximum(const int32_t p[1024],unsigned grid){
 unsigned x=grid%32u,y=grid/32u;
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
  int xx=(int)x+dx,yy=(int)y+dy;
  if(xx>=0&&xx<32&&yy>=0&&yy<32&&p[yy*32+xx]>p[grid])return 0;
 }
 return 1;
}
int c9_candidate_at_peak(const int32_t p[1024],unsigned grid,c9_candidate *out){
 if(!out)return 0;
 *out=(c9_candidate){0};
 if(!p||grid>=C9_DIRECTION_COUNT||p[grid]<=0||!candidate_local_maximum(p,grid))return 0;
 c9_candidate c={.grid=grid,.score=p[grid],.uncertainty_mdeg=6000u};
 unsigned x=grid%32u,y=grid/32u;
 c.azimuth_mdeg=c9_direction_azimuth_mdeg[x];
 c.elevation_mdeg=c9_direction_elevation_mdeg[y];
 /* A bounded two-dimensional quadratic fit needs all nine committed cells.
  * Cross curvature matters for tilted peaks. Reject a saddle/flat surface,
  * boundary maximum and a vertex outside the central cell rather than
  * manufacture fine angular precision. All differences use double before
  * subtracting int32 inputs, including INT32_MIN negative side lobes. */
 if(x&&x<31u&&y&&y<31u){
  double p0=p[grid],left=p[grid-1],right=p[grid+1];
  double down=p[grid-32],up=p[grid+32];
  double hx=left-2*p0+right,hy=down-2*p0+up;
  double hxy=((double)p[grid+33]-p[grid+31]-p[grid-31]+p[grid-33])*.25;
  double gx=(right-left)*.5,gy=(up-down)*.5,det=hx*hy-hxy*hxy;
  /* A one-count ripple cannot establish a trustworthy local curvature. */
  double floor=p0*.002;if(floor<2)floor=2;
  if(hx< -floor&&hy< -floor&&det>floor*floor){
   double dx=(hxy*gy-hy*gx)/det,dy=(hxy*gx-hx*gy)/det;
   if(dx>= -.5&&dx<=.5&&dy>= -.5&&dy<=.5){
    double az=c.azimuth_mdeg+dx*(c9_direction_azimuth_mdeg[x+1]-c9_direction_azimuth_mdeg[x-1])*.5;
    double el=c.elevation_mdeg+dy*(c9_direction_elevation_mdeg[y+1]-c9_direction_elevation_mdeg[y-1])*.5;
    c.azimuth_mdeg=(int32_t)(az+(az>=0?.5:-.5));
    c.elevation_mdeg=(int32_t)(el+(el>=0?.5:-.5));
    c.flags=C9_CANDIDATE_REFINED;c.uncertainty_mdeg=3000u;
   }
  }
 }
 *out=c;return 1;
}

unsigned c9_candidates_extract(const int32_t p[1024],c9_candidate out[3]){
 if(!p||!out)return 0;
 unsigned count=0;
 /* 25 degree NMS is angular: grid row/column distances are misleading near
  * the hemisphere poles. This is a candidate proposal, not a claim that a
  * 50-mm aperture can resolve every pair separated by 25 degrees. */
 const int32_t cos25=973140576;
 for(unsigned k=0;k<C9_CANDIDATES;k++){
  int32_t best=0;unsigned chosen=0;
  for(unsigned g=0;g<C9_DIRECTION_COUNT;g++){
   if(p[g]<=best)continue;
   int separated=1;
   for(unsigned j=0;j<count;j++)if(c9_direction_within(g,out[j].grid,cos25))separated=0;
   if(!separated)continue;
   if(candidate_local_maximum(p,g)){best=p[g];chosen=g;}
  }
  /* Keep weak peaks down to 1/20 of the largest score. Actual separability
   * and trust are checked by the separator and caller's temporal tracker. */
  if(!best||(count&&(int64_t)best*20<out[0].score))break;
  if(c9_candidate_at_peak(p,chosen,&out[count]))count++;
 }
 return count;
}

static c9_complex zadd(c9_complex a,c9_complex b){return(c9_complex){a.re+b.re,a.im+b.im};}
static c9_complex zsub(c9_complex a,c9_complex b){return(c9_complex){a.re-b.re,a.im-b.im};}
static c9_complex zmul(c9_complex a,c9_complex b){return(c9_complex){a.re*b.re-a.im*b.im,a.re*b.im+a.im*b.re};}
static c9_complex zconj(c9_complex a){return(c9_complex){a.re,-a.im};}
static double zpower(c9_complex a){return a.re*a.re+a.im*a.im;}
static c9_complex zdiv(c9_complex a,c9_complex b){double p=zpower(b);return(c9_complex){(a.re*b.re+a.im*b.im)/p,(a.im*b.re-a.re*b.im)/p};}
static double absolute(double x){return x<0?-x:x;}
static int finite_number(double x){return x==x&&x<1e100&&x> -1e100;}
/* Small argument sin/cos without libm, matching the PS math convention. All
 * callers use |angle|<2*pi; phase construction is bounded by the 25-mm ring. */
static void sincos_small(double angle,double *sn,double *cs){
 const double halfpi=1.57079632679489661923;
 int q=(int)(angle/halfpi+(angle>=0?.5:-.5));
 double x=(angle-q*1.5707963267948966)-q*6.123233995736766e-17,t=x*x;
 double s=x*(1+t*(-1./6+t*(1./120+t*(-1./5040+t*(1./362880+t*(-1./39916800+t*(1./6227020800.+t*(-1./1307674368000.+t/355687428096000.))))))));
 double c=1+t*(-1./2+t*(1./24+t*(-1./720+t*(1./40320+t*(-1./3628800+t*(1./479001600+t*(-1./87178291200.+t*(1./20922789888000.-t/6402373705728000.))))))));
 switch(q&3){case 0:*sn=s;*cs=c;break;case 1:*sn=c;*cs=-s;break;case 2:*sn=-s;*cs=-c;break;default:*sn=-c;*cs=s;break;}
}
void c9_candidate_angles(const c9_candidate *c,int32_t *az,int32_t *el){
 int32_t a=0,e=0;
 if(c&&c->grid<C9_DIRECTION_COUNT){
  a=c9_direction_azimuth_mdeg[c->grid%32u];e=c9_direction_elevation_mdeg[c->grid/32u];
  /* Invalid metadata never steers outside the advertised front hemisphere. */
  if((c->flags&C9_CANDIDATE_REFINED)&&c->azimuth_mdeg>= -90000&&c->azimuth_mdeg<=90000&&
     c->elevation_mdeg>= -90000&&c->elevation_mdeg<=90000&&
     c->azimuth_mdeg-a>= -2814&&c->azimuth_mdeg-a<=2814&&
     c->elevation_mdeg-e>= -2814&&c->elevation_mdeg-e<=2814){
   a=c->azimuth_mdeg;e=c->elevation_mdeg;
  }
 }
 if(az)*az=a;
 if(el)*el=e;
}
void c9_candidate_unit(const c9_candidate *c,double u[3]){
 if(!u)return;
 int32_t az,el;double sa,ca,se,ce;c9_candidate_angles(c,&az,&el);
 sincos_small(az*(3.14159265358979323846/180000),&sa,&ca);
 sincos_small(el*(3.14159265358979323846/180000),&se,&ce);
 u[0]=sa*ce;u[1]=se;u[2]=ca*ce;
}
static void fft(c9_complex *x,const c9_complex *twiddle,int inverse){
 unsigned j=0;
 for(unsigned i=1;i<C9_SEPARATION_FFT;i++){
  unsigned bit=C9_SEPARATION_FFT>>1;for(;j&bit;bit>>=1)j^=bit;j^=bit;
  if(i<j){c9_complex z=x[i];x[i]=x[j];x[j]=z;}
 }
 for(unsigned len=2;len<=C9_SEPARATION_FFT;len<<=1){
  unsigned half=len>>1,stride=C9_SEPARATION_FFT/len;
  for(unsigned b=0;b<C9_SEPARATION_FFT;b+=len)for(unsigned k=0;k<half;k++){
   c9_complex w=twiddle[k*stride];if(inverse)w.im=-w.im;
   c9_complex z=zmul(x[b+k+half],w),a=x[b+k];
   x[b+k]=zadd(a,z);x[b+k+half]=zsub(a,z);
  }
 }
 if(inverse)for(unsigned i=0;i<C9_SEPARATION_FFT;i++){x[i].re/=C9_SEPARATION_FFT;x[i].im/=C9_SEPARATION_FFT;}
}
/* Dimensions are fixed at nine; no heap and no convergence-dependent loop. */
static int inverse(c9_complex matrix[9][9],c9_complex result[9][9]){
 memset(result,0,81*sizeof(c9_complex));for(unsigned i=0;i<9;i++)result[i][i].re=1;
 for(unsigned k=0;k<9;k++){
  unsigned pivot=k;double largest=zpower(matrix[k][k]);
  for(unsigned i=k+1;i<9;i++)if(zpower(matrix[i][k])>largest){pivot=i;largest=zpower(matrix[i][k]);}
  if(largest<1e-16||!finite_number(largest))return 0;
  if(pivot!=k)for(unsigned j=0;j<9;j++){
   c9_complex t=matrix[k][j];matrix[k][j]=matrix[pivot][j];matrix[pivot][j]=t;
   t=result[k][j];result[k][j]=result[pivot][j];result[pivot][j]=t;
  }
  c9_complex d=matrix[k][k];
  for(unsigned j=0;j<9;j++){matrix[k][j]=zdiv(matrix[k][j],d);result[k][j]=zdiv(result[k][j],d);}
  for(unsigned i=0;i<9;i++)if(i!=k){
   c9_complex m=matrix[i][k];for(unsigned j=0;j<9;j++){
    matrix[i][j]=zsub(matrix[i][j],zmul(m,matrix[k][j]));
    result[i][j]=zsub(result[i][j],zmul(m,result[k][j]));
   }
  }
 }
 return 1;
}
static double delay_q4(const uint32_t *lut,unsigned channel,int32_t az,int32_t el){
 unsigned x=0,y=0;
 while(x<30u&&az>c9_direction_azimuth_mdeg[x+1])x++;
 while(y<30u&&el>c9_direction_elevation_mdeg[y+1])y++;
 double fx=(az-c9_direction_azimuth_mdeg[x])/(double)(c9_direction_azimuth_mdeg[x+1]-c9_direction_azimuth_mdeg[x]);
 double fy=(el-c9_direction_elevation_mdeg[y])/(double)(c9_direction_elevation_mdeg[y+1]-c9_direction_elevation_mdeg[y]);
 /* At the hemisphere boundary at most half a cell is extrapolated. */
 if(fx< -.5)fx= -.5;
 if(fx>1.5)fx=1.5;
 if(fy< -.5)fy= -.5;
 if(fy>1.5)fy=1.5;
 double q[2][2];
 for(unsigned dy=0;dy<2;dy++)for(unsigned dx=0;dx<2;dx++){
  int v=(int)(lut[channel*1024+(y+dy)*32+x+dx]&16383u);if(v&8192)v-=16384;
  q[dy][dx]=v;
 }
 return (1-fy)*((1-fx)*q[0][0]+fx*q[0][1])+fy*((1-fx)*q[1][0]+fx*q[1][1]);
}
static int candidate_valid(const c9_candidate *c){
 if(!c||c->grid>=C9_DIRECTION_COUNT||(c->flags&~C9_CANDIDATE_REFINED))return 0;
 int32_t az,el;c9_candidate_angles(c,&az,&el);
 return !(c->flags&C9_CANDIDATE_REFINED)||(az==c->azimuth_mdeg&&el==c->elevation_mdeg);
}
int c9_candidate_delays_q16(const c9_candidate *c,const uint32_t *lut,uint32_t delays[9]){
 if(!delays)return 0;
 memset(delays,0,9*sizeof(*delays));if(!lut||!candidate_valid(c))return 0;
 int32_t az,el;int q[9],minimum=0;c9_candidate_angles(c,&az,&el);
 unsigned x=0,y=0;
 while(x<30u&&az>c9_direction_azimuth_mdeg[x+1])x++;
 while(y<30u&&el>c9_direction_elevation_mdeg[y+1])y++;
 int64_t sx=c9_direction_azimuth_mdeg[x+1]-c9_direction_azimuth_mdeg[x];
 int64_t sy=c9_direction_elevation_mdeg[y+1]-c9_direction_elevation_mdeg[y];
 int64_t dx=az-c9_direction_azimuth_mdeg[x],dy=el-c9_direction_elevation_mdeg[y];
 int64_t wx[2]={sx-dx,dx},wy[2]={sy-dy,dy},denominator=sx*sy;
 for(unsigned ch=0;ch<9;ch++){
  /* Integer rational interpolation avoids a one-Q4 floor error when the true
   * bilinear result is integral but binary64 rounds just below that integer.
   * |numerator| stays below2e12 for these14-bit LUTs and hemisphere angles. */
  int64_t numerator=0;
  for(unsigned j=0;j<2;j++)for(unsigned i=0;i<2;i++){
   int value=(int)(lut[ch*1024+(y+j)*32+x+i]&16383u);if(value&8192)value-=16384;
   numerator+=(int64_t)value*wx[i]*wy[j];
  }
  q[ch]=(int)(numerator/denominator);if(numerator<0&&numerator%denominator)q[ch]--;
  if(!ch||q[ch]<minimum)minimum=q[ch];
 }
 for(unsigned ch=0;ch<9;ch++)if(q[ch]-minimum>=61*16)return 0;
 for(unsigned ch=0;ch<9;ch++)delays[ch]=(uint32_t)(q[ch]-minimum)*4096u;
 return 1;
}
static double square_root(double x){
 if(x<=0)return 0;
 /* IEEE754 binary64/VFP: exponent estimate plus bounded Newton refinement. */
 union {double d;uint64_t u;} v={x};v.u=(v.u>>1)+0x1ff8000000000000ull;
 double y=v.d;for(unsigned i=0;i<6;i++)y=.5*(y+x/y);return y;
}
static unsigned analysis_band(unsigned bin){return bin<58u?0u:bin<=120u?1u:2u;}
static void prepare_samples(const int16_t (*raw)[9],unsigned frames,c9_separation_workspace *w,
 uint32_t *invalid,uint32_t clipped[9]){
 uint64_t energy[9]={0};uint32_t clips[9]={0};
 for(unsigned n=0;n<frames;n++)for(unsigned ch=0;ch<9;ch++){
  int v=raw[n][ch];energy[ch]+=(int64_t)v*v;if(v==32767||v== -32768)clips[ch]++;
 }
 *invalid=0;for(unsigned ch=0;ch<9;ch++){
  if(energy[ch]<frames*4ull||clips[ch])*invalid|=1u<<ch;
  if(clipped)clipped[ch]=clips[ch];
 }
 for(unsigned ch=0;ch<9;ch++)for(unsigned n=0;n<frames/4u;n++){
  int index=(int)(4*n+3);int64_t sum=0;
  for(int j=0;j<63;j++){
   int v=index>=j?raw[index-j][ch]:0;if(index>=126-j)v+=raw[index-126+j][ch];
   sum+=(int64_t)v*c9_decim_coeff[j];
  }
  if(index>=63)sum+=(int64_t)raw[index-63][ch]*c9_decim_coeff[63];
  w->decimated[ch][n]=(float)(sum/(32768.0*32768.0));
 }
 for(unsigned n=0;n<C9_SEPARATION_FFT;n++){
  double sn,cs;sincos_small(3.14159265358979323846*n/C9_SEPARATION_FFT,&sn,&cs);w->window[n]=sn;
  if(n<C9_SEPARATION_FFT/2){sincos_small(6.2831853071795864769*n/C9_SEPARATION_FFT,&sn,&cs);w->twiddle[n]=(c9_complex){cs,-sn};}
 }
}
static void analyze_observations(c9_separation_workspace *w,unsigned decimated_frames){
 unsigned hops=(decimated_frames-64u-C9_SEPARATION_FFT)/C9_SEPARATION_HOP;
 unsigned frames=hops+1u;if(frames>C9_ANALYSIS_FRAMES)frames=C9_ANALYSIS_FRAMES;
 w->analysis_frames=frames;memset(w->covariance,0,sizeof(w->covariance));memset(w->band_energy,0,sizeof(w->band_energy));
 for(unsigned f=0;f<frames;f++){
  unsigned start=64u+(frames>1u?(f*hops/(frames-1u)):0u)*C9_SEPARATION_HOP;w->observed_start[f]=start;
  for(unsigned ch=0;ch<9;ch++){
   for(unsigned n=0;n<C9_SEPARATION_FFT;n++)w->spectrum[ch][n]=(c9_complex){w->decimated[ch][start+n]*w->window[n],0};
   fft(w->spectrum[ch],w->twiddle,0);
   for(unsigned k=8;k<=209;k++){
    w->observed[f][ch][k-8u]=w->spectrum[ch][k];
    if(k>=16u)w->band_energy[f][analysis_band(k)]+=zpower(w->spectrum[ch][k]);
   }
  }
  for(unsigned k=0;k<C9_ANALYSIS_BINS;k++)for(unsigned i=0;i<9;i++)for(unsigned j=i;j<9;j++){
   c9_complex v=zmul(w->observed[f][i][k],zconj(w->observed[f][j][k]));
   w->covariance[k][i][j]=zadd(w->covariance[k][i][j],v);
   if(i!=j)w->covariance[k][j][i]=zadd(w->covariance[k][j][i],zconj(v));
  }
 }
 for(unsigned k=0;k<C9_ANALYSIS_BINS;k++)for(unsigned i=0;i<9;i++)for(unsigned j=0;j<9;j++){
  w->covariance[k][i][j].re/=frames;w->covariance[k][i][j].im/=frames;
 }
}
static unsigned candidate_support(c9_separation_workspace *w,const c9_candidate *c,const uint32_t *lut,
 unsigned band,const uint8_t used[210],uint32_t *mask,unsigned *run_start,unsigned *run_end){
 int32_t az,el;c9_candidate_angles(c,&az,&el);double q[9],numerator[8]={0},denominator[8]={0},maximum_energy=0;
 for(unsigned ch=0;ch<9;ch++)q[ch]=delay_q4(lut,ch,az,el);
 for(unsigned f=0;f<w->analysis_frames;f++)if(w->band_energy[f][band]>maximum_energy)maximum_energy=w->band_energy[f][band];
 for(unsigned k=16;k<=209;k++)if(used[k]&&analysis_band(k)==band){
  c9_complex steer[9];
  for(unsigned ch=0;ch<9;ch++){
   double sn,cs;sincos_small(6.2831853071795864769*k*q[ch]/(64.0*C9_SEPARATION_FFT),&sn,&cs);
   steer[ch]=(c9_complex){cs,-sn};
  }
  for(unsigned f=0;f<w->analysis_frames;f++){
   c9_complex beam={0,0};double energy=0;
   for(unsigned ch=0;ch<9;ch++){
    c9_complex x=w->observed[f][ch][k-8];beam=zadd(beam,zmul(x,steer[ch]));energy+=zpower(x);
   }
   numerator[f]+=zpower(beam)-energy;denominator[f]+=8*energy;
  }
 }
 unsigned run=0,best=0;*mask=0;*run_start=*run_end=0;
 for(unsigned f=0;f<w->analysis_frames;f++){
  int supported=denominator[f]>1e-12&&numerator[f]>.25*denominator[f]&&
   w->band_energy[f][band]>.25*maximum_energy;
  if(supported){*mask|=1u<<f;run++;}else run=0;
  if(run>best){best=run;*run_start=f+1u-run;*run_end=f;}
 }
 return best;
}
int c9_search_feedback_current(const c9_search_feedback *f,uint32_t now,uint32_t session,
 uint32_t epoch,uint32_t geometry,uint32_t calibration){
 if(!f||f->abi!=C9_SEARCH_FEEDBACK_ABI||f->count>3u||f->invalid_input||f->session!=session||f->epoch!=epoch||
    f->geometry_version!=geometry||f->calibration_version!=calibration||!session||!geometry||
    f->analysis_frames<3u||f->analysis_frames>C9_ANALYSIS_FRAMES||
    f->end_sample-f->first_sample>C9_SEARCH_RAW_FRAMES||f->end_sample-f->first_sample<C9_SEARCH_MIN_RAW_FRAMES||
    ((f->first_sample|f->end_sample)&3u)||f->band_valid_mask>7u||
    f->valid_until_sample!=f->end_sample+C9_SEARCH_MAX_AGE_SAMPLES||
    now-f->end_sample>C9_SEARCH_MAX_AGE_SAMPLES)return 0;
 for(unsigned c=0;c<f->count;c++){
  uint32_t start=f->support_first_sample[c]-f->first_sample,end=f->support_end_sample[c]-f->first_sample;
  unsigned n=f->support_frames[c];
  if(!candidate_valid(&f->candidates[c])||!f->band_mask[c]||(f->band_mask[c]&~f->band_valid_mask)||
     !f->quality_permille[c]||f->quality_permille[c]>1000u||n<3u||n>f->analysis_frames||
     start<256u||start>=end||end>f->end_sample-f->first_sample||
     (start-256u)%(4u*C9_SEPARATION_HOP)||
     end-start!=4u*(C9_SEPARATION_FFT+(n-1u)*C9_SEPARATION_HOP)||
     now-f->support_end_sample[c]>C9_SEARCH_MAX_AGE_SAMPLES)return 0;
  unsigned first=(start-256u)/(4u*C9_SEPARATION_HOP);
  if(first+n>f->analysis_frames||f->support_mask[c]>>f->analysis_frames||
     (f->support_mask[c]&(((1u<<n)-1u)<<first))!=(((1u<<n)-1u)<<first))return 0;
 }
 return 1;
}
int c9_candidates_search(const int16_t (*raw)[9],uint32_t raw_frames,const uint32_t *lut,
 c9_separation_workspace *w,const c9_search_context *ctx,c9_search_feedback *r){
 if(!r)return 0;
 memset(r,0,sizeof(*r));
 if(!raw||!lut||!w||!ctx||raw_frames<C9_SEARCH_MIN_RAW_FRAMES||raw_frames>C9_SEARCH_RAW_FRAMES||
    (raw_frames&3u)||((ctx->first_sample|ctx->end_sample)&3u)||ctx->end_sample-ctx->first_sample!=raw_frames||!ctx->session||!ctx->geometry_version||
    ctx->geometry_confirmed>1u){r->invalid_input=0x80000000u;return 0;}
 r->abi=C9_SEARCH_FEEDBACK_ABI;r->session=ctx->session;r->epoch=ctx->epoch;r->first_sample=ctx->first_sample;
 r->end_sample=ctx->end_sample;r->valid_until_sample=ctx->end_sample+C9_SEARCH_MAX_AGE_SAMPLES;
 r->geometry_version=ctx->geometry_version;r->calibration_version=ctx->calibration_version;r->geometry_confirmed=ctx->geometry_confirmed;
 prepare_samples(raw,raw_frames,w,&r->invalid_input,NULL);if(r->invalid_input)return 1;
 analyze_observations(w,raw_frames/4u);r->analysis_frames=w->analysis_frames;
 double band_energy[3]={0},largest=0;
 for(unsigned f=0;f<w->analysis_frames;f++)for(unsigned b=0;b<3;b++)band_energy[b]+=w->band_energy[f][b];
 for(unsigned b=0;b<3;b++)if(band_energy[b]>largest)largest=band_energy[b];
 c9_candidate proposals[3][3];unsigned counts[3]={0};uint8_t used[3][210]={{0}};
 for(unsigned b=0;b<3;b++){
  memset(w->search_scores[b],0,sizeof(w->search_scores[b]));
  if(largest<1e-10||band_energy[b]<largest*.0005)continue;
  double peak_power=0;
  for(unsigned k=16;k<=209;k++)if(analysis_band(k)==b){
   double p=0;for(unsigned ch=0;ch<9;ch++)p+=w->covariance[k-8][ch][ch].re;
   if(p>peak_power)peak_power=p;
  }
  for(unsigned k=16;k<=209;k++)if(analysis_band(k)==b){
   double p=0;for(unsigned ch=0;ch<9;ch++)p+=w->covariance[k-8][ch][ch].re;
   if(p>peak_power*.001&&p>1e-12){used[b][k]=1;r->band_bins[b]++;}
  }
  if(r->band_bins[b]<4u)continue;
  unsigned pair=0;
  for(unsigned i=0;i<8;i++)for(unsigned j=i+1;j<9;j++){
   memset(w->transform,0,sizeof(w->transform));
   for(unsigned k=16;k<=209;k++)if(used[b][k]){
    c9_complex v=w->covariance[k-8][i][j];
    double den=square_root(w->covariance[k-8][i][i].re*w->covariance[k-8][j][j].re);
    if(den>1e-18){v.re/=den;v.im/=den;}else v=(c9_complex){0,0};
    w->transform[k]=v;w->transform[C9_SEPARATION_FFT-k]=zconj(v);
   }
   fft(w->transform,w->twiddle,1);
   for(int lag=-32;lag<32;lag++)w->search_lags[pair][lag+32]=w->transform[(lag+C9_SEPARATION_FFT)%C9_SEPARATION_FFT].re;
   pair++;
  }
  double scale=1000000.0*C9_SEPARATION_FFT/(72.0*r->band_bins[b]);
  for(unsigned g=0;g<1024;g++){
   int q[9];for(unsigned ch=0;ch<9;ch++){q[ch]=(int)(lut[ch*1024+g]&16383u);if(q[ch]&8192)q[ch]-=16384;}
   double sum=0;pair=0;
   for(unsigned i=0;i<8;i++)for(unsigned j=i+1;j<9;j++){
    double lag= -(q[i]-q[j])/64.0;int l=(int)lag;if(l>lag)l--;
    if(l< -31||l>29){r->invalid_input=0x20000000u;return 0;}
    /* Cubic correlation interpolation avoids bias toward integer decimated
     * lags, especially in the high band; the geometric grid remains32x32. */
    double t=lag-l,p0=w->search_lags[pair][l+31],p1=w->search_lags[pair][l+32];
    double p2=w->search_lags[pair][l+33],p3=w->search_lags[pair][l+34];
    sum+=(((-.5*p0+1.5*p1-1.5*p2+.5*p3)*t+(p0-2.5*p1+2*p2-.5*p3))*t+.5*(p2-p0))*t+p1;pair++;
   }
   double score=sum*scale;if(score>2000000000)score=2000000000;if(score< -2000000000)score= -2000000000;
   w->search_scores[b][g]=(int32_t)score;
  }
  counts[b]=c9_candidates_extract(w->search_scores[b],proposals[b]);
  if(counts[b]&&proposals[b][0].score>=150000)r->band_valid_mask|=1u<<b;else counts[b]=0;
 }
 /* Each valid band first gets its strongest temporally supported direction;
  * only afterwards fill remaining slots with other angularly distinct peaks.
  * All band scores are coherence-normalized, never ranked by loudness. */
 for(unsigned rank=0;rank<3;rank++)for(unsigned b=0;b<3;b++)if(rank<counts[b]){
  c9_candidate c=proposals[b][rank];if(c.score<150000)continue;
  int32_t shoulder=0;
  for(unsigned g=0;g<1024;g++){
   int32_t dot=c9_direction_dot_q30(g,c.grid);
   if(dot<=1050277989&&dot>=973140576&&w->search_scores[b][g]>shoulder)shoulder=w->search_scores[b][g];
  }
  int64_t quality=(int64_t)(c.score-shoulder)*1000/c.score;if(quality<3)continue;if(quality>1000)quality=1000;
  uint32_t mask;unsigned first,last,n=candidate_support(w,&c,lut,b,used[b],&mask,&first,&last);if(n<3)continue;
  unsigned slot=r->count;double u[3];c9_candidate_unit(&c,u);
  for(unsigned j=0;j<r->count;j++){
   double v[3];c9_candidate_unit(&r->candidates[j],v);
   if(u[0]*v[0]+u[1]*v[1]+u[2]*v[2]>.9659258262890683){slot=j;break;}
  }
  if(slot>=3u)continue;
  if(slot==r->count){r->count++;r->candidates[slot]=c;}
  r->band_mask[slot]|=1u<<b;r->band_score[slot][b]=c.score;
  if((uint32_t)quality>r->quality_permille[slot])r->quality_permille[slot]=(uint32_t)quality;
  if(!r->support_frames[slot]||c.score>=r->candidates[slot].score){
   r->candidates[slot]=c;r->support_frames[slot]=n;r->support_mask[slot]=mask;
   r->support_first_sample[slot]=ctx->first_sample+4u*w->observed_start[first];
   r->support_end_sample[slot]=ctx->first_sample+4u*(w->observed_start[last]+C9_SEPARATION_FFT);
  }
 }
 return 1;
}
static void steering_sector(const c9_candidate *cand,const uint32_t *lut,unsigned bin,
 c9_complex a[5][9]){
 int32_t az,el;c9_candidate_angles(cand,&az,&el);
 uint32_t uncertainty=cand->uncertainty_mdeg;
 /* Fitting a peak does not establish sub-degree physical accuracy. Keep at
  * least a three-degree protection sector even on synthetic sharp peaks. */
 if(uncertainty<3000u)uncertainty=3000u;
 if(uncertainty>6000u)uncertainty=6000u;
 const int da[5]={0,1,-1,0,0},de[5]={0,0,0,1,-1};
 for(unsigned s=0;s<5;s++){
  int32_t aa=az+da[s]*(int32_t)uncertainty,ee=el+de[s]*(int32_t)uncertainty;
  if(aa< -90000)aa= -90000;
  if(aa>90000)aa=90000;
  if(ee< -90000)ee= -90000;
  if(ee>90000)ee=90000;
  for(unsigned ch=0;ch<9;ch++){
   double q=delay_q4(lut,ch,aa,ee),sn,cs;
   sincos_small(6.2831853071795864769*bin*q/(64.0*C9_SEPARATION_FFT),&sn,&cs);
   a[s][ch]=(c9_complex){cs,sn};
  }
 }
}
static int protected_covariance(const c9_separation_workspace *w,unsigned bin,
 const c9_complex target[5][9],c9_complex result[9][9],unsigned *rank_out){
 c9_complex basis[5][9],projection[9][9],temp[9][9];unsigned rank=0;
 for(unsigned vector=0;vector<5;vector++){
  c9_complex v[9];
  for(unsigned ch=0;ch<9;ch++){
   if(!vector)v[ch]=target[0][ch];
   else if(vector==1)v[ch]=zsub(target[1][ch],target[2][ch]);
   else if(vector==2)v[ch]=zsub(target[3][ch],target[4][ch]);
   else{
    unsigned a=vector==3?1u:3u,b=vector==3?2u:4u;
    v[ch]=zsub(zadd(target[a][ch],target[b][ch]),zadd(target[0][ch],target[0][ch]));
   }
  }
  for(unsigned pass=0;pass<2;pass++)for(unsigned j=0;j<rank;j++){
   c9_complex dot={0,0};for(unsigned ch=0;ch<9;ch++)dot=zadd(dot,zmul(zconj(basis[j][ch]),v[ch]));
   for(unsigned ch=0;ch<9;ch++)v[ch]=zsub(v[ch],zmul(basis[j][ch],dot));
  }
  double norm=0;for(unsigned ch=0;ch<9;ch++)norm+=zpower(v[ch]);
  if(norm<1e-10||!finite_number(norm))continue;
  norm=square_root(norm);for(unsigned ch=0;ch<9;ch++)basis[rank][ch]=(c9_complex){v[ch].re/norm,v[ch].im/norm};rank++;
 }
 *rank_out=rank;
 for(unsigned i=0;i<9;i++)for(unsigned j=0;j<9;j++){
  c9_complex p={(double)(i==j),0};for(unsigned k=0;k<rank;k++)p=zsub(p,zmul(basis[k][i],zconj(basis[k][j])));
  projection[i][j]=p;
 }
 for(unsigned i=0;i<9;i++)for(unsigned j=0;j<9;j++){
  c9_complex sum={0,0};for(unsigned k=0;k<9;k++)sum=zadd(sum,zmul(projection[i][k],w->covariance[bin-8][k][j]));temp[i][j]=sum;
 }
 double total=0,residual=0;
 for(unsigned i=0;i<9;i++)for(unsigned j=0;j<9;j++){
  c9_complex sum={0,0};for(unsigned k=0;k<9;k++)sum=zadd(sum,zmul(temp[i][k],projection[k][j]));result[i][j]=sum;
  if(i==j){total+=w->covariance[bin-8][i][i].re;residual+=sum.re;}
 }
 /* Never normalize an almost-pure target's tiny steering/quantization error
  * into a high-power noise covariance. At least-30dB residual evidence is
  * required; otherwise retain the deterministic guarded sector solution. */
 if(!w->analysis_frames||total<1e-16||residual<.001*total||!finite_number(residual))return 0;
 double scale=9.0/residual;
 for(unsigned i=0;i<9;i++)for(unsigned j=i;j<9;j++){
  c9_complex v=zadd(result[i][j],zconj(result[j][i]));v.re*=.375*scale;v.im*=.375*scale;
  if(i==j){v.re+=.25;v.im=0;}
  result[i][j]=v;result[j][i]=zconj(v);
 }
 return 1;
}
static int prepare_bin(c9_separation_workspace *w,const c9_candidate *cand,
 unsigned count,const uint32_t *lut,unsigned bin,c9_separation_report *r,int empirical){
 c9_complex a[3][5][9],cov[9][9],iv[9][9],observed_cov[9][9];
 for(unsigned c=0;c<count;c++)steering_sector(&cand[c],lut,bin,a[c]);
 int usable=1,used_covariance=0;unsigned protected_min=9,protected_max=0;
 double report_norm=0,report_null=0,report_error=0,sector_min=1,sector_max=1,sector_leak=0;
 for(unsigned c=0;c<count&&usable;c++){
  int accepted=0;unsigned protected_rank=0;
  int have_covariance=empirical&&count>1&&protected_covariance(w,bin,a[c],observed_cov,&protected_rank);
  /* Soft-null loading is deliberately bounded. An infinitely deep point null
   * is brittle to angle/calibration errors. Five sector samples broaden the
   * suppression while target-sector deviations are penalized separately.
   * Retry weaker suppression only when all explicit quality guards still pass. */
  static const double loading[3]={10000,300,30};
  for(unsigned attempt=0;attempt<3&&!accepted;attempt++){
   if(count==1){
    /* One known candidate has no spatial competitor to null. Ordinary DAS
     * is the exact minimum-white-noise solution and needs no matrix solve. */
    memset(iv,0,sizeof(iv));for(unsigned ch=0;ch<9;ch++)iv[ch][ch].re=1;
   }else{
    memset(cov,0,sizeof(cov));for(unsigned ch=0;ch<9;ch++)cov[ch][ch].re=1;
    for(unsigned other=0;other<count;other++)for(unsigned s=0;s<5;s++){
     double scale=(other==c?1000:loading[attempt])/5;
     for(unsigned i=0;i<9;i++)for(unsigned j=0;j<9;j++){
      c9_complex ai=a[other][s][i],aj=a[other][s][j];
      if(other==c){ai=zsub(ai,a[c][0][i]);aj=zsub(aj,a[c][0][j]);}
      c9_complex value=zmul(ai,zconj(aj));value.re*=scale;value.im*=scale;
      cov[i][j]=zadd(cov[i][j],value);
     }
    }
    if(have_covariance){
     const double mix[3]={8,2,0};
     for(unsigned i=0;i<9;i++)for(unsigned j=0;j<9;j++){
      c9_complex value=observed_cov[i][j];value.re*=mix[attempt];value.im*=mix[attempt];cov[i][j]=zadd(cov[i][j],value);
     }
    }
    if(!inverse(cov,iv))continue;
   }
   c9_complex response={0,0};double norm=0;
   for(unsigned ch=0;ch<9;ch++){
    c9_complex b={0,0};for(unsigned j=0;j<9;j++)b=zadd(b,zmul(zconj(a[c][0][j]),iv[j][ch]));
    w->weights[c][bin][ch]=b;response=zadd(response,zmul(b,a[c][0][ch]));
   }
   if(zpower(response)<1e-12)continue;
   for(unsigned ch=0;ch<9;ch++){
    w->weights[c][bin][ch]=zdiv(w->weights[c][bin][ch],response);
    norm+=zpower(w->weights[c][bin][ch]);
   }
   if(!finite_number(norm)||norm>8.0)continue;
   double null=0,error=0,min_gain=1,max_gain=1,max_leak=0;
   for(unsigned other=0;other<count;other++)for(unsigned s=0;s<5;s++){
    c9_complex v={0,0};for(unsigned ch=0;ch<9;ch++)v=zadd(v,zmul(w->weights[c][bin][ch],a[other][s][ch]));
    double gain=zpower(v);
    if(!finite_number(gain)){max_leak=1e100;continue;}
    if(other==c){
     if(gain<min_gain)min_gain=gain;
     if(gain>max_gain)max_gain=gain;
     if(!s)error=absolute(v.re-1)+absolute(v.im);
    }else{
     if(!s&&gain>null)null=gain;
     if(gain>max_leak)max_leak=gain;
    }
   }
   /* Power thresholds: preserve sector amplitude within +/-15 percent, at
    * least20dB suppression at each competing center and15.2dB over samples.
    * These are steering-model checks, never proof of real acoustic isolation. */
   if(min_gain<.85*.85||max_gain>1.15*1.15||null>.01||max_leak>.03)continue;
   accepted=1;
   if(have_covariance&&attempt<2u){
    used_covariance=1;if(protected_rank<protected_min)protected_min=protected_rank;if(protected_rank>protected_max)protected_max=protected_rank;
   }
   if(norm>report_norm)report_norm=norm;
   if(null>report_null)report_null=null;
   if(error>report_error)report_error=error;
   if(min_gain<sector_min)sector_min=min_gain;
   if(max_gain>sector_max)sector_max=max_gain;
   if(max_leak>sector_leak)sector_leak=max_leak;
  }
  if(!accepted)usable=0;
 }
 if(usable){
  if(used_covariance){
   r->covariance_used_bins++;if(protected_min<r->covariance_protected_rank_min)r->covariance_protected_rank_min=protected_min;
   if(protected_max>r->covariance_protected_rank_max)r->covariance_protected_rank_max=protected_max;
  }
  if(report_norm>r->max_weight_norm)r->max_weight_norm=report_norm;
  if(report_null>r->max_null_leakage)r->max_null_leakage=report_null;
  if(report_error>r->target_error)r->target_error=report_error;
  if(sector_min<r->min_sector_gain)r->min_sector_gain=sector_min;
  if(sector_max>r->max_sector_gain)r->max_sector_gain=sector_max;
  if(sector_leak>r->max_sector_leakage)r->max_sector_leakage=sector_leak;
 }else for(unsigned c=0;c<count;c++)for(unsigned ch=0;ch<9;ch++){
  w->weights[c][bin][ch]=zconj(a[c][0][ch]);
  w->weights[c][bin][ch].re/=9;w->weights[c][bin][ch].im/=9;
 }
 return usable;
}

static int separate_internal(const int16_t (*raw)[9],const c9_candidate *cand,
 unsigned count,const uint32_t *lut,c9_separation_workspace *w,
 double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *r,int empirical,const c9_separation_report *frozen){
 if(!r)return 0;
 if(frozen){*r=*frozen;r->frames=0;r->ready_mask=0;memset(r->energy,0,sizeof(r->energy));memset(r->usable_energy,0,sizeof(r->usable_energy));memset(r->clipped_output,0,sizeof(r->clipped_output));}
 else memset(r,0,sizeof(*r));
 if(!raw||!cand||!lut||!w||!out||!count||count>C9_CANDIDATES){r->invalid_input=0x80000000u;return 0;}
 memset(out,0,C9_CANDIDATES*C9_AUDIO_FRAMES*sizeof(double));r->count=count;
 for(unsigned c=0;c<count;c++){
  uint32_t delays[9];if(!c9_candidate_delays_q16(&cand[c],lut,delays)){r->invalid_input=0x80000000u;return 0;}
 }
 for(unsigned i=0;i<count;i++)for(unsigned j=0;j<i;j++){
  double u[3],v[3];c9_candidate_unit(&cand[i],u);c9_candidate_unit(&cand[j],v);
  if(u[0]*v[0]+u[1]*v[1]+u[2]*v[2]>.90630778703664996){r->invalid_input=0x40000000u;return 0;}
 }
 if(!frozen){r->min_sector_gain=1;r->max_sector_gain=1;r->covariance_protected_rank_min=9;}
 prepare_samples(raw,C9_SNAPSHOT_FRAMES,w,&r->invalid_input,r->clipped_input);
 if(!frozen&&empirical){
  analyze_observations(w,C9_DECIMATED_FRAMES);r->covariance_frames=w->analysis_frames;
  r->covariance_bins=C9_ANALYSIS_BINS;r->covariance_shrinkage_permille=250;
 }
 uint8_t usable[C9_SEPARATION_FFT/2+1]={0};
 const unsigned firstbin=8,lastbin=209; /* 305.1758..7972.7173 Hz. */
 for(unsigned k=firstbin;k<=lastbin;k++){
  if(frozen)usable[k]=(uint8_t)((frozen->usable_mask[(k-firstbin)/32]>>((k-firstbin)%32))&1u);
  else{
   usable[k]=(uint8_t)prepare_bin(w,cand,count,lut,k,r,empirical);r->usable_bins+=usable[k];r->total_bins++;
   if(usable[k])r->usable_mask[(k-firstbin)/32]|=1u<<((k-firstbin)%32);
  }
 }
 /* The chosen fixed carrier is2200..4600Hz (feature contract C9F2).
  * Coverage is a geometry/calibration condition, independent of spectral
  * energy. Otherwise a signal with its fault sideband in an unsafe hole
  * could be handed to diagnosis as apparently clean normal machine audio. */
 if(!r->covariance_used_bins)r->covariance_protected_rank_min=0;
 r->carrier_bins=r->carrier_usable_bins=r->carrier_max_gap=0;unsigned gap=0;
 for(unsigned k=firstbin;k<=lastbin;k++){
  double hz=k*(39062.5/C9_SEPARATION_FFT);
  if(hz<C9_DIAG_CARRIER_LOW_HZ||hz>C9_DIAG_CARRIER_HIGH_HZ)continue;
  r->carrier_bins++;r->carrier_usable_bins+=usable[k];
  if(!usable[k]){gap++;if(gap>r->carrier_max_gap)r->carrier_max_gap=gap;}else gap=0;
 }
 memset(w->normalization,0,sizeof(w->normalization));
 /* Start one half-frame before the capture. Zero padding plus exact overlap
  * normalization avoid startup/end amplitude dips without borrowing samples
  * from another snapshot. Trim the first 64 decimated warmup samples. */
 for(int start=-(int)C9_SEPARATION_HOP;start<(int)C9_DECIMATED_FRAMES;start+=C9_SEPARATION_HOP){
  r->frames++;
  for(unsigned ch=0;ch<9;ch++){
   for(unsigned j=0;j<C9_SEPARATION_FFT;j++){
    int index=start+(int)j;
    w->spectrum[ch][j]=(c9_complex){index>=0&&index<(int)C9_DECIMATED_FRAMES?w->decimated[ch][index]*w->window[j]:0,0};
   }
   fft(w->spectrum[ch],w->twiddle,0);
  }
  for(unsigned c=0;c<count;c++){
   memset(w->transform,0,sizeof(w->transform));
   for(unsigned k=firstbin;k<=lastbin;k++){
    c9_complex y={0,0};for(unsigned ch=0;ch<9;ch++)y=zadd(y,zmul(w->weights[c][k][ch],w->spectrum[ch][k]));
    double hz=k*(39062.5/C9_SEPARATION_FFT),gain=1;
    if(hz<600)gain=(hz-300)/300;else if(hz>7500)gain=(8000-hz)/500;
    if(gain<0)gain=0;
    y.re*=gain;y.im*=gain;
    double energy=zpower(y);r->energy[c]+=energy;if(usable[k])r->usable_energy[c]+=energy;
    /* An unsafe DAS bin is only a conservative quality proxy. Do not hand
     * its spatially mixed signal to a fault classifier as separated audio. */
    if(!usable[k])y=(c9_complex){0,0};
    w->transform[k]=y;w->transform[C9_SEPARATION_FFT-k]=zconj(y);
   }
   fft(w->transform,w->twiddle,1);
   for(unsigned j=0;j<C9_SEPARATION_FFT;j++){
    int n=start+(int)j-64;
    if(n>=0&&n<(int)C9_AUDIO_FRAMES)out[c][n]+=w->transform[j].re*w->window[j];
   }
  }
  for(unsigned j=0;j<C9_SEPARATION_FFT;j++){
   int n=start+(int)j-64;if(n>=0&&n<(int)C9_AUDIO_FRAMES)w->normalization[n]+=w->window[j]*w->window[j];
  }
 }
 for(unsigned c=0;c<count;c++){
  int ready=!r->invalid_input&&r->energy[c]>1e-6&&r->usable_energy[c]>=.85*r->energy[c]&&
   r->carrier_bins&&r->carrier_usable_bins*20u>=r->carrier_bins*19u&&r->carrier_max_gap<=3u;
  for(unsigned n=0;n<C9_AUDIO_FRAMES;n++){
   double norm=w->normalization[n];if(norm<.01){ready=0;out[c][n]=0;continue;}
   out[c][n]/=norm;
   if(!finite_number(out[c][n])){ready=0;out[c][n]=0;}
   if(out[c][n]>1||out[c][n]< -1){r->clipped_output[c]++;ready=0;}
  }
  if(ready)r->ready_mask|=1u<<c;
 }
 return 1;
}

int c9_candidates_separate(const int16_t (*raw)[9],const c9_candidate *cand,unsigned count,
 const uint32_t *lut,c9_separation_workspace *w,double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *r){
 return separate_internal(raw,cand,count,lut,w,out,r,1,NULL);
}
#ifdef C9_CANDIDATES_TEST
int c9_candidates_test_separate(const int16_t (*raw)[9],const c9_candidate *cand,unsigned count,
 const uint32_t *lut,c9_separation_workspace *w,double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *r,int empirical){
 return separate_internal(raw,cand,count,lut,w,out,r,empirical,NULL);
}
int c9_candidates_test_render(const int16_t (*raw)[9],const c9_candidate *cand,unsigned count,
 const uint32_t *lut,c9_separation_workspace *w,double out[C9_CANDIDATES][C9_AUDIO_FRAMES],c9_separation_report *r,const c9_separation_report *frozen){
 return separate_internal(raw,cand,count,lut,w,out,r,0,frozen);
}
#endif
