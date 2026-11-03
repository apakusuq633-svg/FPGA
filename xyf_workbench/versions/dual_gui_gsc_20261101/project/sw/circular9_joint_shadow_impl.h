#include "circular9_joint_shadow.h"
#if C9_JOINT_SHADOW || C9_JOINT_FORMAL
#ifdef __arm__
static uint32_t c9_joint_now_us(void){XTime t;XTime_GetTime(&t);return (uint32_t)((t/COUNTS_PER_SECOND)*1000000u+(t%COUNTS_PER_SECOND)*1000000u/COUNTS_PER_SECOND);}
#else
#include <time.h>
#ifdef _WIN32
#include <windows.h>
#endif
static uint32_t c9_joint_now_us(void){
#ifdef C9_JOINT_TEST_TIME_STEP_US
 static uint32_t t;t+=C9_JOINT_TEST_TIME_STEP_US;return t;
#else
 #ifdef _WIN32
 LARGE_INTEGER f,t;QueryPerformanceFrequency(&f);QueryPerformanceCounter(&t);return (uint32_t)(((uint64_t)t.QuadPart/(uint64_t)f.QuadPart)*1000000u+((uint64_t)t.QuadPart%(uint64_t)f.QuadPart)*1000000u/(uint64_t)f.QuadPart);
#else
 struct timespec t;timespec_get(&t,TIME_UTC);return (uint32_t)((uint64_t)t.tv_sec*1000000u+(uint64_t)t.tv_nsec/1000u);
#endif
#endif
}
#endif
/* CPU1-only static scratch, no extra PCM/FFT/covariance buffer. */
/* Exact signed truncation for a sum of at most three int32 values.
 * 2^32=3*1431655765+1; magnitude high word is at most1. */
static int64_t c9_joint_div3(int64_t sum){
 uint64_t u=(uint64_t)(sum<0?-sum:sum);uint32_t lo=(uint32_t)u,hi=(uint32_t)(u>>32);
 uint32_t q=lo/3u,rem=lo-q*3u;
 uint64_t result=(uint64_t)q+hi*1431655765u+((rem+hi)>=3u);
 return sum<0?-(int64_t)result:(int64_t)result;
}
static int32_t c9_joint_scores[1024];
static double c9_joint_power[210]; /* CPU1-private reusable mask scratch. */
static int c9_joint_expired(uint32_t start,uint32_t budget,c9_joint_report *r){
 if(budget==UINT32_MAX)return 0; /* Complete formal search; outer job deadline still applies. */
 r->total_us=c9_joint_now_us()-start;
 if(!budget||r->total_us>=budget){r->status=C9_JOINT_BUDGET;r->count=0;return 1;}return 0;
}
void c9_joint_shadow_compute(const c9_separation_workspace *cw,const uint32_t *lut,uint32_t bands,uint32_t budget,c9_joint_report *r){
 memset(r,0,sizeof(*r));r->budget_us=budget;uint32_t start=c9_joint_now_us();
 if(!cw||!lut||(bands&~7u)){r->status=C9_JOINT_INVALID;return;}
 if(!bands){r->status=C9_JOINT_NO_BANDS;return;}
 r->band_mask=bands;unsigned active=0;for(unsigned b=0;b<3;b++)active+=(bands>>b)&1u;
 for(unsigned g=0;g<1024;g++){
  int64_t sum=0;for(unsigned b=0;b<3;b++)if(bands&(1u<<b))sum+=cw->search_scores[b][g];c9_joint_scores[g]=(int32_t)(active==1u?sum:active==2u?sum/2:c9_joint_div3(sum));
  if((g&63u)==63u&&c9_joint_expired(start,budget,r))return;
 }
 r->score_us=c9_joint_now_us()-start;uint32_t t=c9_joint_now_us();c9_candidate peaks[3];unsigned count=c9_candidates_extract(c9_joint_scores,peaks);r->raw_peaks=count;memcpy(r->raw_candidates,peaks,count*sizeof(peaks[0]));r->peak_us=c9_joint_now_us()-t;
 if(c9_joint_expired(start,budget,r))return;
 t=c9_joint_now_us();
 /* candidate_support is read-only; keep signature compatibility with core. */
 c9_separation_workspace *w=(c9_separation_workspace*)cw;
 uint8_t used[3][210]={{0}};
 double peak_power[3]={0};
 /* Identical channel sum order, computed once instead of twice per bin. */
 for(unsigned k=16;k<=209;k++)if(bands&(1u<<analysis_band(k))){
  double power=0;for(unsigned ch=0;ch<9;ch++)power+=w->covariance[k-8][ch][ch].re;
  c9_joint_power[k]=power;unsigned b=analysis_band(k);if(power>peak_power[b])peak_power[b]=power;
 }
 for(unsigned k=16;k<=209;k++){unsigned b=analysis_band(k);if((bands&(1u<<b))&&c9_joint_power[k]>peak_power[b]*.001&&c9_joint_power[k]>1e-12)used[b][k]=1;}

 for(unsigned k=0;k<count;k++){
  if(c9_joint_expired(start,budget,r))return;
  int32_t shoulder;unsigned quality=c9_peak_quality_details(c9_joint_scores,&peaks[k],&shoulder);r->raw_quality[k]=quality;r->raw_shoulder[k]=shoulder;if(!quality)continue;
  uint32_t supported=0,bestmask=0;unsigned best=0;
  for(unsigned b=0;b<3;b++)if(bands&(1u<<b)){
   unsigned first,last;uint32_t mask;unsigned n=candidate_support(w,&peaks[k],lut,b,used[b],&mask,&first,&last);
   if(n>=3){supported|=1u<<b;if(n>best){best=n;bestmask=mask;}}
   if(c9_joint_expired(start,budget,r))return;
  }
  if(!supported)continue;
  unsigned j=r->count++;r->selected_raw_index[j]=k;r->candidates[j]=peaks[k];r->quality[j]=quality;r->shoulder[j]=shoulder;r->support_band_mask[j]=supported;r->support_mask[j]=bestmask;
  double v[3];c9_candidate_unit(&peaks[k],v);for(unsigned a=0;a<3;a++)r->direction_q30[j][a]=(int32_t)(v[a]*1073741824.0);
 }
 r->support_us=c9_joint_now_us()-t;if(c9_joint_expired(start,budget,r))return;r->status=C9_JOINT_OK;
}
#endif
