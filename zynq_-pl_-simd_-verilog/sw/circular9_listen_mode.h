#ifndef C9_LISTEN_MODE_H
#define C9_LISTEN_MODE_H
#include <stdint.h>
#include <string.h>
enum {PATROL_DAS=0,MANUAL_GSC=1};
enum {C9_LISTEN_PRESET=0,C9_LISTEN_FORMAL=1,C9_LISTEN_OPERATOR=2,C9_LISTEN_MAP=3};
#define C9_LISTEN_POINTS 8u
typedef struct {int az,el;uint32_t dwell_ms,enabled;} c9_listen_point;
typedef struct {uint32_t revision,version,applied,mode,actual_mode,pending,running,paused,strategy,index,actual_index,saved_index,saved_running,saved_paused,source;
 int az,el,actual_az,actual_el;uint32_t actual_source,baseline,actual_baseline,started_ms,applied_sample,last_follow_ms,last_formal_seq,transitions,updates,errors;
 uint32_t transition_ms,transition_sample;const char *reason,*transition_reason;c9_listen_point points[C9_LISTEN_POINTS];} c9_listen_state;
static int c9_listen_angle(int a,int e){return a>=-85&&a<=85&&e>=-85&&e<=85;}
static void c9_listen_request(c9_listen_state *s,uint32_t mode,int az,int el,uint32_t source,const char *why){
 s->revision++;s->reason=why;
 if(s->mode==mode&&s->az==az&&s->el==el&&s->source==source&&s->baseline==s->actual_baseline&&s->applied)return;
 s->mode=mode;s->az=az;s->el=el;s->source=source;s->version++;s->pending=1;
}
static int c9_listen_select(c9_listen_state *s,unsigned from){
 for(unsigned k=0;k<C9_LISTEN_POINTS;k++){unsigned n=(from+k)%C9_LISTEN_POINTS;if(s->points[n].enabled){s->index=n;c9_listen_request(s,PATROL_DAS,s->points[n].az,s->points[n].el,C9_LISTEN_PRESET,"patrol_point");if(!s->pending)s->actual_index=n;return 1;}}return 0;
}
static int c9_listen_lock(c9_listen_state *s,int az,int el,uint32_t source){
 if(!c9_listen_angle(az,el))return 0;
 if(s->mode==PATROL_DAS){s->saved_index=s->applied?s->actual_index:s->index;s->saved_running=s->running;s->saved_paused=s->paused;}
 s->baseline=0;c9_listen_request(s,MANUAL_GSC,az,el,source,"operator_lock");return 1;
}
static void c9_listen_back(c9_listen_state *s){
 s->baseline=0;s->running=s->saved_running;s->paused=s->saved_paused;s->index=s->saved_index;
 if(s->strategy==C9_LISTEN_PRESET&&s->points[s->index].enabled)c9_listen_request(s,PATROL_DAS,s->points[s->index].az,s->points[s->index].el,C9_LISTEN_PRESET,"return_patrol");
 else c9_listen_request(s,PATROL_DAS,s->az,s->el,s->source,"return_patrol");
}
static void c9_listen_tick(c9_listen_state *s,uint32_t now){
 if(s->mode!=PATROL_DAS||!s->running||s->paused||s->pending||s->strategy!=C9_LISTEN_PRESET)return;
 if((uint32_t)(now-s->started_ms)>=s->points[s->index].dwell_ms){c9_listen_select(s,(s->index+1)%C9_LISTEN_POINTS);if(!s->pending)s->started_ms=now;}
}
static void c9_listen_committed(c9_listen_state *s,uint32_t now,uint32_t sample){
 if(s->actual_mode!=s->mode){s->transitions++;s->transition_ms=now;s->transition_sample=sample;s->transition_reason=s->reason;}
 if(!s->applied||s->actual_az!=s->az||s->actual_el!=s->el)s->updates++;
 s->actual_mode=s->mode;s->actual_az=s->az;s->actual_el=s->el;s->actual_source=s->source;s->actual_baseline=s->baseline;
 s->actual_index=s->index;s->applied=s->version;s->applied_sample=sample;s->started_ms=now;s->pending=0;
}
#endif

