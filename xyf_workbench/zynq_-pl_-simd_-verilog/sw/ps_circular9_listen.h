#ifndef PS_C9_LISTEN_H
#define PS_C9_LISTEN_H
#include "circular9_listen_mode.h"
#include <stdlib.h>
static c9_listen_state c9_listen={.reason="standby"};
static uint32_t c9_listen_ms(void){static uint32_t prev;static uint64_t ticks;uint32_t now=dia_gtimer_now();ticks+=(uint32_t)(now-prev);prev=now;return (uint32_t)(ticks/(XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ/2000u));}
static int c9_listen_formal(int *az,int *el){
 const c9_search_feedback *f=&c9_debug_aux.feedback;uint32_t end,count,ep,se;
 if(!c9_history_info(&c9_history_shared.history,&end,&count,&ep,&se)||!count||f->count!=1||f->session!=se||f->epoch!=ep||end-f->support_end_sample[0]>=C9_TRACK_COAST_SAMPLES)return 0;
 int32_t a,e;c9_candidate_angles(&f->candidates[0],&a,&e);*az=a/1000;*el=e/1000;return c9_listen_angle(*az,*el);
}
static void c9_listen_poll(void){
 uint32_t now=c9_listen_ms();c9_listen_tick(&c9_listen,now);
 if(c9_listen.mode==PATROL_DAS&&c9_listen.running&&!c9_listen.paused&&c9_listen.strategy==C9_LISTEN_FORMAL){
  const c9_search_feedback *f=&c9_debug_aux.feedback;uint32_t end,count,ep,se;
  if(c9_history_info(&c9_history_shared.history,&end,&count,&ep,&se)&&count&&f->count==1&&f->session==se&&f->epoch==ep&&
     end-f->support_end_sample[0]<C9_TRACK_COAST_SAMPLES&&c9_debug_aux.sequence!=c9_listen.last_formal_seq&&now-c9_listen.last_follow_ms>=500u){
   int32_t a,e;c9_candidate_angles(&f->candidates[0],&a,&e);int az=a/1000,el=e/1000;
   c9_listen.last_formal_seq=c9_debug_aux.sequence;c9_listen.last_follow_ms=now;
   if(c9_listen_angle(az,el)&&(abs(az-c9_listen.az)>=3||abs(el-c9_listen.el)>=3||!c9_listen.applied))c9_listen_request(&c9_listen,PATROL_DAS,az,el,C9_LISTEN_FORMAL,"fresh_formal");
  }
 }
}
/* Called ONLY at a /8 output boundary, before constructing that output sample. */
static int c9_listen_boundary(const uint32_t w[16]){
 if(c9_listen.applied&&!c9_listen.pending&&(!c9_audio.adaptive.configured||c9_audio.adaptive.config.epoch!=w[14])){c9_listen.version++;c9_listen.revision++;c9_listen.pending=1;c9_listen.reason="input_epoch_reset";}
 if(!c9_listen.applied&&!c9_listen.pending)return 0;
 if(c9_listen.pending){
  if(c9_batch)c9_queue_batch();
  das_bus b=das_axi_bus(RV32_BASE);
  unsigned have=c9_audio_have,fill=c9_audio_fill;
  if(!c9_gsc_manual_target(&b,c9_listen.az,c9_listen.el)){c9_listen.errors++;return 0;}
  /* Anti-alias history is direction-independent; retain it across retargets. */
  c9_audio_have=have;c9_audio_fill=fill;
  c9_audio.adaptive.config.version=c9_listen.version;
  c9_requested=c9_listen.mode==MANUAL_GSC&&!c9_listen.baseline;c9_freeze=0;
  c9_listen_committed(&c9_listen,c9_listen_ms(),w[1]);
 }
 return c9_gsc_manual_ready&&c9_audio.adaptive.configured&&c9_audio.adaptive.config.epoch==w[14];
}
static int c9_listen_json(char *body,size_t cap){
 c9_listen_state *s=&c9_listen;unsigned reason=gsc9_reason(&c9_audio.adaptive);
 const char *engine=!c9_recording||!s->applied||!c9_listen_output_tick||c9_ticks_to_us(dia_gtimer_now()-c9_listen_output_tick)>100000u?"AUDIO_UNAVAILABLE":s->pending?"PREPARING":!c9_requested?"DAS":reason==GSC9_OK?"GSC_ACTIVE":reason==GSC9_BYPASS_WARMUP?"GSC_ADAPTING":"GSC_BYPASSED";
 int n=snprintf(body,cap,"{\"revision\":%u,\"version\":%u,\"applied_version\":%u,\"mode\":\"%s\",\"requested_mode\":\"%s\",\"pending\":%u,\"az\":%d,\"el\":%d,\"requested_az\":%d,\"requested_el\":%d,\"source\":%u,\"index\":%u,\"running\":%u,\"paused\":%u,\"strategy\":%u,\"engine\":\"%s\",\"bypass_reason\":%u,\"udp_enabled\":%u,\"udp_sent\":%u,\"udp_dropped\":%u,\"applied_sample\":%u,\"dwell_elapsed_ms\":%u,\"transitions\":%u,\"direction_updates\":%u,\"errors\":%u,\"reason\":\"%s\",\"gsc_active_samples\":%llu,\"gsc_disabled_samples\":%llu,\"gsc_restarts\":%llu,\"points\":[",(unsigned)s->revision,(unsigned)s->version,(unsigned)s->applied,s->actual_mode==MANUAL_GSC?"MANUAL_GSC":"PATROL_DAS",s->mode==MANUAL_GSC?"MANUAL_GSC":"PATROL_DAS",(unsigned)s->pending,s->actual_az,s->actual_el,s->az,s->el,(unsigned)s->actual_source,(unsigned)s->actual_index,(unsigned)s->running,(unsigned)s->paused,(unsigned)s->strategy,engine,reason,c9_recording,(unsigned)c9_sent,(unsigned)c9_software_drops,(unsigned)s->applied_sample,(unsigned)(c9_listen_ms()-s->started_ms),(unsigned)s->transitions,(unsigned)s->updates,(unsigned)s->errors,s->reason,(unsigned long long)gsc9_stat(&c9_audio.adaptive,GSC9_ACTIVE),(unsigned long long)gsc9_stat(&c9_audio.adaptive,GSC9_DISABLED),(unsigned long long)gsc9_stat(&c9_audio.adaptive,GSC9_RESTARTS));
 for(unsigned i=0;i<8;i++)n=ui_append(body,(int)cap,n,"%s{\"az\":%d,\"el\":%d,\"ms\":%u,\"enabled\":%u}",i?",":"",s->points[i].az,s->points[i].el,(unsigned)s->points[i].dwell_ms,(unsigned)s->points[i].enabled);
 int fa=0,fe=0,ff=c9_listen_formal(&fa,&fe);
 return ui_append(body,(int)cap,n,"],\"udp_receive_stats\":null,\"formal_fresh\":%u,\"formal_az\":%d,\"formal_el\":%d,\"applied_ms\":%u,\"last_transition_ms\":%u,\"last_transition_sample\":%u,\"last_transition_reason\":\"%s\",\"weight_reset_total\":null}",(unsigned)ff,fa,fe,(unsigned)s->started_ms,(unsigned)s->transition_ms,(unsigned)s->transition_sample,s->transition_reason?s->transition_reason:"standby");
}
static int c9_listen_route(const char *req,struct ui_reply *rep,char *body,size_t cap){
 if(strncmp(req,"GET /api/listen",15))return 0;
 unsigned rev,index,ms,on,strategy;int a,e;char tail;int ok=0;
 if(!strcmp(req,"GET /api/listen HTTP/1.1")||!strncmp(req,"GET /api/listen ",16)){*rep=(struct ui_reply){200,"OK","application/json",c9_listen_json(body,cap)};return 1;}
 if(sscanf(req,"GET /api/listen/lock?rev=%u&az=%d&el=%d&source=%u%c",&rev,&a,&e,&on,&tail)==5&&tail==' '&&rev==c9_listen.revision&&on<=3){int fa=0,fe=0;int preset=0;for(unsigned k=0;k<8;k++)if(c9_listen.points[k].enabled&&c9_listen.points[k].az==a&&c9_listen.points[k].el==e)preset=1;
 if((on!=C9_LISTEN_PRESET||preset)&&(on!=C9_LISTEN_FORMAL||(c9_listen_formal(&fa,&fe)&&fa==a&&fe==e)))ok=c9_listen_lock(&c9_listen,a,e,on);}
 else if(sscanf(req,"GET /api/listen/point?rev=%u&i=%u&az=%d&el=%d&ms=%u&on=%u%c",&rev,&index,&a,&e,&ms,&on,&tail)==7&&tail==' '&&rev==c9_listen.revision&&index<8&&c9_listen_angle(a,e)&&ms>=500&&ms<=60000&&on<=1){c9_listen.points[index]=(c9_listen_point){a,e,ms,on};c9_listen.revision++;ok=1;}
 else {char cmd[16];if(sscanf(req,"GET /api/listen/%15[^?]?rev=%u%c",cmd,&rev,&tail)==3&&tail==' '&&rev==c9_listen.revision){
  if(!strcmp(cmd,"start")&&c9_listen.mode==PATROL_DAS){c9_listen.running=1;c9_listen.paused=0;ok=c9_listen.strategy==C9_LISTEN_FORMAL||c9_listen_select(&c9_listen,c9_listen.index);if(!ok)c9_listen.running=0;else {c9_listen.started_ms=c9_listen_ms();if(c9_listen.strategy==C9_LISTEN_FORMAL)c9_listen.revision++;}}
  if(!strcmp(cmd,"pause")&&c9_listen.mode==PATROL_DAS){c9_listen.paused=1;c9_listen.revision++;ok=1;}
  if(!strcmp(cmd,"resume")&&c9_listen.mode==PATROL_DAS&&c9_listen.running){c9_listen.paused=0;c9_listen.started_ms=c9_listen_ms();c9_listen.revision++;ok=c9_listen.strategy==C9_LISTEN_FORMAL||c9_listen_select(&c9_listen,c9_listen.index);if(!ok)c9_listen.running=0;}
  if(!strcmp(cmd,"stop")){if(c9_listen.mode==MANUAL_GSC)c9_listen_back(&c9_listen);c9_listen.running=0;c9_listen.revision++;ok=1;}
  if(!strcmp(cmd,"back")&&c9_listen.mode==MANUAL_GSC){c9_listen_back(&c9_listen);ok=1;}
  if(!strcmp(cmd,"baseline")&&c9_listen.mode==MANUAL_GSC){c9_listen.baseline=!c9_listen.baseline;c9_listen_request(&c9_listen,MANUAL_GSC,c9_listen.az,c9_listen.el,c9_listen.source,"baseline_test");ok=1;}
 }}
 if(sscanf(req,"GET /api/listen/strategy?rev=%u&value=%u%c",&rev,&strategy,&tail)==3&&tail==' '&&rev==c9_listen.revision&&strategy<=1&&c9_listen.mode==PATROL_DAS){c9_listen.strategy=strategy;c9_listen.revision++;ok=1;}
 if(ok)c9_recording=1;
 *rep=(struct ui_reply){ok?202:409,ok?"Accepted":"Conflict","application/json",ok?c9_listen_json(body,cap):snprintf(body,cap,"{\"error\":\"invalid_or_stale_request\"}")};return 1;
}
#endif
