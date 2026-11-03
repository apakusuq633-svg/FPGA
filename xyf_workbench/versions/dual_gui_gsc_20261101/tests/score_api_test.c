#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include "circular9_candidates.h"
#define C9_JOINT_FORMAL 1
typedef struct{uint32_t sequence;c9_search_debug debug;c9_search_feedback feedback;}c9_aux_result;
static c9_aux_result c9_debug_aux;static unsigned c9_aux_received_have;static struct{c9_history history;}c9_history_shared;
static uint32_t he=1000,hs=2,hp=3;
int c9_history_info(const c9_history*h,uint32_t*end,uint32_t*count,uint32_t*epoch,uint32_t*session){(void)h;*end=he;*count=999;*epoch=hp;*session=hs;return 1;}
static int ui_append(char*out,int cap,int n,const char*f,...){if(n<0||n>=cap)return cap;va_list a;va_start(a,f);int k=vsnprintf(out+n,cap-n,f,a);va_end(a);return n+k;}
static int c9_joint_score_json(char *out,size_t cap){
#if C9_JOINT_FORMAL
 const c9_aux_result *v=&c9_debug_aux;const c9_search_debug *d=&v->debug;
 unsigned have=c9_aux_received_have!=0;uint32_t end=0,count=0,epoch=0,session=0;
 int era=have&&c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)&&session==d->session&&epoch==d->epoch;
 uint32_t age=end-d->end;int age_valid=era&&age<0x80000000u;
 int fresh=age_valid&&age<=C9_SEARCH_MAX_AGE_SAMPLES;
 int n=snprintf(out,cap,"{\"mode\":\"PS_JOINT_FORMAL\",\"have\":%u,\"fresh\":%s,\"session\":%u,\"epoch\":%u,\"sequence\":%u,\"first\":%u,\"end\":%u,\"age_ms\":",have,fresh?"true":"false",d->session,d->epoch,v->sequence,d->first,d->end);
 n=age_valid?ui_append(out,(int)cap,n,"%.3f",age*1000.0/156250.0):ui_append(out,(int)cap,n,"null");
 n=ui_append(out,(int)cap,n,",\"peaks\":[");
 unsigned peaks=have?d->joint_raw_count:0;if(peaks>2)peaks=2;
 for(unsigned i=0;i<peaks;i++){
  const c9_candidate *p=&d->joint_raw[i];unsigned y=p->grid/32;
  n=ui_append(out,(int)cap,n,"%s{\"score\":%d,\"az\":%d,\"el\":%d,\"grid\":%u,\"quality\":%u,\"boundary\":%s}",i?",":"",p->score,p->azimuth_mdeg,p->elevation_mdeg,p->grid,d->joint_quality[i],y==0||y==31?"true":"false");
 }
 n=ui_append(out,(int)cap,n,"],\"gap\":");
 n=peaks>=2?ui_append(out,(int)cap,n,"%lld",(long long)d->joint_raw[0].score-d->joint_raw[1].score):ui_append(out,(int)cap,n,"null");
 int slot=-1;for(unsigned i=0;i<v->feedback.count&&i<3;i++)if(peaks&&d->joint_selected_raw[i]==0&&v->feedback.candidates[i].grid==d->joint_raw[0].grid){slot=(int)i;break;}
 n=ui_append(out,(int)cap,n,",\"band_valid_mask\":%u,\"scores_at_s1_grid\":[",v->feedback.band_valid_mask);
 for(unsigned b=0;b<3;b++){
  if(b)n=ui_append(out,(int)cap,n,",");
  if(slot>=0&&(v->feedback.band_valid_mask&(1u<<b)))n=ui_append(out,(int)cap,n,"%d",v->feedback.band_score[slot][b]);
  else n=ui_append(out,(int)cap,n,"null");
 }
 n=ui_append(out,(int)cap,n,"],\"formal_count\":%u,\"formal_main\":",v->feedback.count);
 if(have&&v->feedback.count){const c9_candidate *p=&v->feedback.candidates[0];n=ui_append(out,(int)cap,n,"{\"az\":%d,\"el\":%d,\"grid\":%u}",p->azimuth_mdeg,p->elevation_mdeg,p->grid);}else n=ui_append(out,(int)cap,n,"null");
 return ui_append(out,(int)cap,n,"}");
#else
 return snprintf(out,cap,"{\"mode\":\"not_formal_joint\",\"have\":0}");
#endif
}
int main(void){char out[4096];c9_joint_score_json(out,sizeof out);puts(out);
 c9_aux_received_have=1;c9_debug_aux.sequence=20;c9_search_debug*d=&c9_debug_aux.debug;d->session=2;d->epoch=3;d->first=100;d->end=800;d->joint_raw_count=1;d->joint_raw[0]=(c9_candidate){.grid=500,.score=554013};c9_joint_score_json(out,sizeof out);puts(out);
 d->joint_raw_count=2;d->joint_raw[1]=(c9_candidate){.grid=31,.score=478532};c9_debug_aux.feedback.count=1;c9_debug_aux.feedback.candidates[0]=d->joint_raw[0];c9_debug_aux.feedback.band_valid_mask=5;c9_debug_aux.feedback.band_score[0][0]=500000;c9_debug_aux.feedback.band_score[0][1]=600000;c9_debug_aux.feedback.band_score[0][2]=562039;c9_joint_score_json(out,sizeof out);puts(out);
 he=50000;c9_joint_score_json(out,sizeof out);puts(out);hs=9;c9_joint_score_json(out,sizeof out);puts(out);return 0;}
