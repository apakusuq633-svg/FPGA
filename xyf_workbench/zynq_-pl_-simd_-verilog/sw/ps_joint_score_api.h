/* CPU0-owned accepted formal-search snapshot; no search/scheduler calls. */
#ifndef PS_JOINT_SCORE_API_H
#define PS_JOINT_SCORE_API_H
#include "ps_joint_score_js.h"
#include "gui_overview_js.h"
#include "gui_overview_css.h"
#include "gui_complete_js.h"
static int c9_joint_score_json(char *out,size_t cap){
#if C9_JOINT_FORMAL
 const c9_aux_result *v=&c9_debug_aux;const c9_search_debug *d=&v->debug;
 unsigned have=c9_aux_received_have!=0;uint32_t end=0,count=0,epoch=0,session=0;
 int era=have&&c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)&&session==d->session&&epoch==d->epoch;
 uint32_t age=end-d->end;int age_valid=era&&age<0x80000000u;
 int fresh=age_valid&&age<=C9_SEARCH_MAX_AGE_SAMPLES;
 int n=snprintf(out,cap,"{\"mode\":\"PS_JOINT_FORMAL\",\"have\":%u,\"fresh\":%s,\"session\":%u,\"epoch\":%u,\"sequence\":%u,\"first\":%u,\"end\":%u,\"age_ms\":",have,fresh?"true":"false",(unsigned)d->session,(unsigned)d->epoch,(unsigned)v->sequence,(unsigned)d->first,(unsigned)d->end);
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
static int c9_joint_panel_route(const char *req,struct ui_reply *rep,char *body,size_t cap){
 const char *asset=NULL,*type="application/javascript";
 if(!strncmp(req,"GET /gui-complete.js ",sizeof("GET /gui-complete.js ")-1))asset=C9_GUI_COMPLETE_JS;
 if(!strncmp(req,"GET /gui-overview.js ",sizeof("GET /gui-overview.js ")-1))asset=C9_OVERVIEW_JS;
 if(!strncmp(req,"GET /gui-overview.css ",sizeof("GET /gui-overview.css ")-1)){asset=C9_OVERVIEW_CSS;type="text/css";}
 if(asset){int n=(int)strlen(asset);*rep=(struct ui_reply){(size_t)n<cap?200:500,"OK",type,(size_t)n<cap?n:0};if(rep->len)memcpy(body,asset,rep->len);return 1;}
 if(!strncmp(req,"GET /ps-score.js ",sizeof("GET /ps-score.js ")-1)){
  *rep=(struct ui_reply){200,"OK","application/javascript",(int)strlen(C9_JOINT_SCORE_JS)};
  if((size_t)rep->len>=cap){rep->code=500;rep->len=0;}else memcpy(body,C9_JOINT_SCORE_JS,rep->len);return 1;
 }
 if(strncmp(req,"GET /api/ps-score ",sizeof("GET /api/ps-score ")-1))return 0;
 int n=c9_joint_score_json(body,cap);
 *rep=(struct ui_reply){n<0||(size_t)n>=cap?500:200,"OK","application/json",n<0||(size_t)n>=cap?0:n};return 1;
}
#endif
