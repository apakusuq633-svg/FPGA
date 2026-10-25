#ifndef PS_CIRCULAR9_GUI_H
#define PS_CIRCULAR9_GUI_H
#include "circular9_health.h"
static c9h_monitor c9_health;
static void c9_gui_poll(void){
 c9h_clock(&c9_health,dia_gtimer_now(),XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ/2u);
 if(!c9_health.enabled||c9_latest_slot<0)return;
 const c9_diagnostic_result *r=&c9_tasks_shared.data.results[c9_latest_slot];
 if(r->sequence==c9_health.last_sequence)return;
 c9_health.last_sequence=r->sequence;
 for(unsigned i=0;i<r->count;i++){
  const c9_diag_report *d=&r->diagnosis[i];const c9_diag_binding *b=&d->binding;
  c9h_record v={0};v.sequence=r->sequence;v.track=b->track_id;v.session=r->session;v.epoch=r->epoch;
  v.first=b->first_sample;v.samples=b->sample_count;v.label=d->label;v.reason=d->reason;v.model=d->model_version;
  v.azimuth=b->azimuth_mdeg;v.elevation=b->elevation_mdeg;v.rms=d->rms;v.shaft=d->shaft_hz;
  v.valid=c9_result_current(d,r->session,r->shaft_generation)&&d->reason==C9_DIAG_OK&&
   d->model_validated&&d->label!=C9_DIAG_UNKNOWN&&c9_shaft_confirmed&&
   d->shaft_hz==c9_shaft_millihz/1000.0&&!r->deadline_missed;
  c9h_observe(&c9_health,v);
 }
}
static int c9h_record_json(char *out,size_t cap,int n,const c9h_record *r){
 return ui_append(out,(int)cap,n,"{\"cursor\":%u,\"ms\":%llu,\"sequence\":%u,\"track\":%u,\"session\":%u,\"epoch\":%u,\"first_sample\":%u,\"samples\":%u,\"label\":%u,\"reason\":%u,\"valid\":%u,\"state\":%u,\"model\":%u,\"azimuth_mdeg\":%d,\"elevation_mdeg\":%d,\"rms\":%.9g,\"shaft_hz\":%.9g}",
  (unsigned)r->cursor,(unsigned long long)r->ms,(unsigned)r->sequence,(unsigned)r->track,(unsigned)r->session,(unsigned)r->epoch,
  (unsigned)r->first,(unsigned)r->samples,(unsigned)r->label,(unsigned)r->reason,(unsigned)r->valid,(unsigned)r->state,
  (unsigned)r->model,(int)r->azimuth,(int)r->elevation,r->rms,r->shaft);
}
static int c9_gui_route(const char *req,struct ui_reply *rep,char *body,size_t cap){
 int n=0;unsigned after=0,limit=16;char tail;
 if(strncmp(req,"GET /api/recording/on ",22)==0||strncmp(req,"GET /api/recording/off ",23)==0){
  c9_recording=strncmp(req,"GET /api/recording/on ",22)==0;
  c9_batch=0;c9_udp_tail=c9_udp_head;
  int len=snprintf(body,cap,"{\"udp_enabled\":%u}",c9_recording);
  *rep=(struct ui_reply){200,"OK","application/json",len};return 1;
 }

 if(strncmp(req,"GET /api/health9/",17)==0){
  if(strncmp(req,"GET /api/health9/session/",25)==0){
   unsigned long long session=0;
   if(sscanf(req+25,"%llu%c",&session,&tail)!=2||tail!=' '||!session||session>4503599627370495ULL||
      (c9_health.archive_session&&c9_health.archive_session!=session)){
    *rep=(struct ui_reply){409,"Conflict","application/json",0};return 1;
   }
   c9_health.archive_session=session;
  }else if(strncmp(req,"GET /api/health9/enabled?value=",31)==0){
   uint32_t value;if(!c9_http_decimal(req+31,0,1,&value)){*rep=(struct ui_reply){400,"Bad Request","application/json",0};return 1;}
   c9_health.enabled=value;for(unsigned i=0;i<C9H_TRACKS;i++){c9_health.tracks[i].fresh=0;c9_health.tracks[i].normal=c9_health.tracks[i].abnormal=0;}
  }
  n=snprintf(body,cap,"{\"session\":\"%llu\",\"uptime_ms\":%llu,\"enabled\":%u,\"cursor\":%u,\"revision\":%u,\"history_overwritten\":%u,\"event_overflow\":%u,\"track_overflow\":%u,\"thresholds\":[%u,%u,%u],",
   (unsigned long long)c9_health.archive_session,(unsigned long long)c9_health.now_ms,c9_health.enabled,
   (unsigned)c9_health.cursor,(unsigned)c9_health.revision,(unsigned)c9_health.history_overwritten,
   (unsigned)c9_health.event_overflow,(unsigned)c9_health.track_overflow,c9_health.suspect,c9_health.alarm,c9_health.recover);
  if(sscanf(req,"GET /api/health9/history?after=%u&limit=%u%c",&after,&limit,&tail)==3&&tail==' '&&limit>=1&&limit<=32){
   n=ui_append(body,(int)cap,n,"\"records\":[");unsigned count=0,next=after;
   for(unsigned i=0;i<c9_health.history_count&&count<limit;i++){
    const c9h_record *r=&c9_health.history[(c9_health.history_next+C9H_HISTORY-c9_health.history_count+i)%C9H_HISTORY];
    if(r->cursor<=after)continue;
    n=ui_append(body,(int)cap,n,count?",":"");n=c9h_record_json(body,cap,n,r);next=r->cursor;count++;
   }
   n=ui_append(body,(int)cap,n,"],\"next_after\":%u}",next);
  }else if(sscanf(req,"GET /api/health9/events?after=%u&limit=%u%c",&after,&limit,&tail)==3&&tail==' '&&limit>=1&&limit<=16){
   n=ui_append(body,(int)cap,n,"\"events\":[");unsigned count=0,next=after;
   while(count<limit){const c9h_event *e=NULL;
    for(unsigned i=0;i<C9H_EVENTS;i++)if(c9_health.events[i].id&&c9_health.events[i].revision>next&&(!e||c9_health.events[i].revision<e->revision))e=&c9_health.events[i];
    if(!e)break;
    n=ui_append(body,(int)cap,n,"%s{\"id\":%u,\"revision\":%u,\"track\":%u,\"state\":%u,\"label\":%u,\"closed\":%u,\"first_ms\":%llu,\"confirmed_ms\":%llu,\"recovering_ms\":%llu,\"closed_ms\":%llu,\"first\":",
     count?",":"",(unsigned)e->id,(unsigned)e->revision,(unsigned)e->track,(unsigned)e->state,(unsigned)e->label,(unsigned)e->closed,
     (unsigned long long)e->first_ms,(unsigned long long)e->confirmed_ms,(unsigned long long)e->recovering_ms,(unsigned long long)e->closed_ms);
    n=c9h_record_json(body,cap,n,&e->first);n=ui_append(body,(int)cap,n,",\"latest\":");n=c9h_record_json(body,cap,n,&e->latest);
    n=ui_append(body,(int)cap,n,"}");next=e->revision;count++;
   }
   n=ui_append(body,(int)cap,n,"],\"next_after\":%u}",next);
  }else if(strncmp(req,"GET /api/health9/status ",24)==0||strncmp(req,"GET /api/health9/session/",25)==0||strncmp(req,"GET /api/health9/enabled?value=",31)==0){
   n=ui_append(body,(int)cap,n,"\"tracks\":[");unsigned count=0;
   for(unsigned i=0;i<C9H_TRACKS;i++)if(c9_health.tracks[i].used){
    const c9h_track *t=&c9_health.tracks[i];n=ui_append(body,(int)cap,n,"%s{\"fresh\":%u,\"last_valid_ms\":%llu,\"event\":%u,\"record\":",count++?",":"",t->fresh,(unsigned long long)t->last_ms,(unsigned)t->event);
    n=c9h_record_json(body,cap,n,&t->latest);n=ui_append(body,(int)cap,n,"}");
   }n=ui_append(body,(int)cap,n,"]}");
  }else {*rep=(struct ui_reply){400,"Bad Request","application/json",0};return 1;}
 }else if(strncmp(req,"GET /api/debug/pair?",20)==0||strncmp(req,"GET /api/debug/raw ",19)==0){
  unsigned a=0,b=1;int all=strncmp(req,"GET /api/debug/raw ",19)==0;
  if(!all&&(sscanf(req+20,"a=%u&b=%u%c",&a,&b,&tail)!=3||tail!=' '||a>=9||b>=9||a==b)){*rep=(struct ui_reply){400,"Bad Request","application/json",0};return 1;}
  static int16_t raw[1024][9];uint32_t end,count,epoch,session,first;
  int copied=c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)&&count>=1024;
  uint32_t capture_epoch=epoch,capture_session=session,start=(end&~3u)-1024u;
  for(unsigned offset=0;copied&&offset<1024;offset+=64){
   copied=c9_history_copy(&c9_history_shared.history,raw+offset,64,start+offset+64,&first,&epoch,&session)&&
    epoch==capture_epoch&&session==capture_session;
   c9_realtime_checkpoint();
  }
  first=start;
  if(!copied){
   *rep=(struct ui_reply){409,"Conflict","application/json",0};return 1;
  }
  uint32_t h[8]={all?0x43395231u:0x43395031u,156250u,1024u,all?9u:a,all?0u:b,first,epoch,session};memcpy(body,h,32);
  if(all){for(unsigned i=0;i<1024;i++)for(unsigned ch=0;ch<9;ch++){uint16_t x=(uint16_t)raw[i][ch];body[32+18*i+2*ch]=(char)x;body[33+18*i+2*ch]=(char)(x>>8);}
   *rep=(struct ui_reply){200,"OK","application/octet-stream",18464};return 1;}
  for(unsigned i=0;i<1024;i++){uint16_t x=(uint16_t)raw[i][a],y=(uint16_t)raw[i][b];body[32+4*i]=(char)x;body[33+4*i]=(char)(x>>8);body[34+4*i]=(char)y;body[35+4*i]=(char)(y>>8);}
  *rep=(struct ui_reply){200,"OK","application/octet-stream",4128};return 1;
 }else if(strncmp(req,"GET /api/gui/plots?",19)==0){
  unsigned seq,index;
  if(sscanf(req+19,"sequence=%u&index=%u%c",&seq,&index,&tail)!=3||tail!=' '||index>=3){*rep=(struct ui_reply){400,"Bad Request","application/json",0};return 1;}
  const c9_diagnostic_result *r=c9_latest_slot<0?NULL:&c9_tasks_shared.data.results[c9_latest_slot];
  if(!r||r->sequence!=seq||index>=r->count){*rep=(struct ui_reply){409,"Conflict","application/json",0};return 1;}
  n=snprintf(body,cap,"{\"sequence\":%u,\"track\":%u,\"envelope_valid\":%u,\"envelope_max_hz\":900,\"envelope\":[",seq,(unsigned)r->diagnosis[index].binding.track_id,(unsigned)r->gui_envelope_valid[index]);
  for(unsigned i=0;i<128;i++)n=ui_append(body,(int)cap,n,"%s%u",i?",":"",(unsigned)r->gui_envelope[index][i]);
  n=ui_append(body,(int)cap,n,"]}");
 }else return 0;
 *rep=(struct ui_reply){n<0||(size_t)n>=cap?500:200,n<0||(size_t)n>=cap?"Internal Server Error":"OK","application/json",n<0||(size_t)n>=cap?0:n};return 1;
}
#endif
