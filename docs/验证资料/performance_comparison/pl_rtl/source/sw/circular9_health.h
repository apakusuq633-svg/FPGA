#ifndef CIRCULAR9_HEALTH_H
#define CIRCULAR9_HEALTH_H
#include <stdint.h>
#include <string.h>
#define C9H_TRACKS 8u
#define C9H_HISTORY 256u
#define C9H_EVENTS 32u
enum {C9H_NORMAL,C9H_SUSPECTED,C9H_ALARM,C9H_RECOVERING};
typedef struct {
 uint64_t ms;uint32_t cursor,sequence,track,session,epoch,first,samples;
 uint32_t label,reason,valid,state,model;int32_t azimuth,elevation;double rms,shaft;
} c9h_record;
typedef struct {
 uint32_t used,track,session,epoch,state,abnormal,normal,label,event,model,fresh;
 uint64_t last_ms; c9h_record latest,first_abnormal;
} c9h_track;
typedef struct {
 uint32_t id,revision,track,state,label,closed;
 uint64_t first_ms,confirmed_ms,recovering_ms,closed_ms;
 c9h_record first,latest;
} c9h_event;
typedef struct {
 unsigned enabled,suspect,alarm,recover,timeout;
 uint64_t now_ms,remainder,archive_session;
 uint32_t timer,last_sequence,cursor,event_id,revision,history_next,history_count;
 uint32_t history_overwritten,event_overflow,track_overflow;
 c9h_record history[C9H_HISTORY];c9h_track tracks[C9H_TRACKS];c9h_event events[C9H_EVENTS];
} c9h_monitor;
static inline void c9h_init(c9h_monitor *m){
 memset(m,0,sizeof(*m));m->enabled=1;m->suspect=3;m->alarm=5;m->recover=10;m->timeout=5000;
}
/* CPU0 services this independently of the browser. Timer is Cortex-A9 ticks. */
static inline void c9h_clock(c9h_monitor *m,uint32_t timer,uint32_t hz){
 uint32_t delta=timer-m->timer;m->timer=timer;
 if(hz){uint64_t ticks=(uint64_t)delta*1000u+m->remainder;m->now_ms+=ticks/hz;m->remainder=ticks%hz;}
 for(unsigned i=0;i<C9H_TRACKS;i++)if(m->tracks[i].used&&m->now_ms-m->tracks[i].last_ms>m->timeout){
  m->tracks[i].fresh=0;m->tracks[i].abnormal=m->tracks[i].normal=0;
 }
}
static inline void c9h_observe(c9h_monitor *m,c9h_record r){
 if(!m->enabled)return;
 c9h_track *t=NULL;
 for(unsigned i=0;i<C9H_TRACKS;i++)if(m->tracks[i].used&&m->tracks[i].track==r.track&&
  m->tracks[i].session==r.session&&m->tracks[i].epoch==r.epoch){t=&m->tracks[i];break;}
 if(!t)for(unsigned i=0;i<C9H_TRACKS;i++)if(!m->tracks[i].used||
  (m->tracks[i].state==C9H_NORMAL&&!m->tracks[i].event&&m->now_ms-m->tracks[i].last_ms>m->timeout)){
  t=&m->tracks[i];memset(t,0,sizeof(*t));t->used=1;t->track=r.track;t->session=r.session;t->epoch=r.epoch;break;
 }
 if(!t){m->track_overflow++;return;}
 if(t->latest.sequence==r.sequence&&t->latest.track==r.track)return;
 if(t->model!=r.model){t->abnormal=t->normal=0;t->model=r.model;}
 r.ms=m->now_ms;r.cursor=++m->cursor;
 if(!r.valid){t->fresh=0;t->abnormal=t->normal=0;}
 else {
  t->fresh=1;t->last_ms=r.ms;
  if(r.label==2u||r.label==4u){
   t->normal=0;if(t->label!=r.label)t->abnormal=0;t->label=r.label;
   if(!t->abnormal)t->first_abnormal=r;
   if(t->abnormal<m->alarm)t->abnormal++;
   if(t->state==C9H_RECOVERING)t->state=C9H_ALARM;
   else if(t->abnormal>=m->alarm)t->state=C9H_ALARM;
   else if(t->abnormal>=m->suspect&&t->state==C9H_NORMAL)t->state=C9H_SUSPECTED;
  }else if(r.label==1u){
   t->abnormal=0;if(t->normal<m->recover)t->normal++;
   if(t->state==C9H_ALARM)t->state=C9H_RECOVERING;
   if(t->normal>=m->recover)t->state=C9H_NORMAL;
  }else {t->abnormal=t->normal=0;} /* Interference is not healthy recovery. */
 }
 r.state=t->state;t->latest=r;
 if(r.valid&&t->state!=C9H_NORMAL&&!t->event){
  c9h_event *e=NULL;
  for(unsigned i=0;i<C9H_EVENTS;i++)if(!m->events[i].id){e=&m->events[i];break;}
  if(!e)for(unsigned i=0;i<C9H_EVENTS;i++)if(m->events[i].closed&&(!e||m->events[i].revision<e->revision))e=&m->events[i];
  if(e){memset(e,0,sizeof(*e));e->id=++m->event_id;e->track=r.track;e->first_ms=t->first_abnormal.ms;e->first=t->first_abnormal;t->event=e->id;}
  else m->event_overflow++;
 }
 if(t->event)for(unsigned i=0;i<C9H_EVENTS;i++)if(m->events[i].id==t->event){
  c9h_event *e=&m->events[i];e->state=t->state;e->latest=r;e->label=t->label;e->revision=++m->revision;
  if(t->state==C9H_ALARM&&!e->confirmed_ms)e->confirmed_ms=r.ms;
  if(t->state==C9H_RECOVERING&&!e->recovering_ms)e->recovering_ms=r.ms;
  if(r.valid&&t->state==C9H_NORMAL){e->closed=1;e->closed_ms=r.ms;t->event=0;}
  break;
 }
 m->history[m->history_next]=r;m->history_next=(m->history_next+1u)%C9H_HISTORY;
 if(m->history_count<C9H_HISTORY)m->history_count++;else m->history_overwritten++;
}
#endif
