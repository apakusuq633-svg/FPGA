#include "sw/circular9_health.h"
#include <assert.h>
#include <stdio.h>
static c9h_monitor m;
static unsigned seq;
static void add(unsigned track,unsigned label,unsigned valid){
 m.now_ms+=512;
 c9h_record r={0};r.sequence=++seq;r.track=track;r.session=1;r.epoch=1;r.samples=40000;r.label=label;r.valid=valid;r.model=1;r.rms=.03;
 c9h_observe(&m,r);
}
int main(void){
 c9h_init(&m);for(int i=0;i<10;i++)add(1,1,1);assert(m.tracks[0].state==C9H_NORMAL);
 add(1,2,1);add(1,1,1);assert(!m.event_id);
 for(int i=0;i<3;i++)add(1,2,1);assert(m.tracks[0].state==C9H_SUSPECTED&&m.event_id==1);
 for(int i=0;i<2;i++)add(1,2,1);assert(m.tracks[0].state==C9H_ALARM&&m.event_id==1);
 assert(m.events[0].first_ms<m.events[0].confirmed_ms);
 for(int i=0;i<20;i++)add(1,0,0);assert(m.tracks[0].state==C9H_ALARM);
 add(1,1,1);assert(m.tracks[0].state==C9H_RECOVERING);
 add(1,2,1);assert(m.tracks[0].state==C9H_ALARM);
 for(int i=0;i<10;i++)add(1,1,1);assert(m.tracks[0].state==C9H_NORMAL&&m.events[0].closed);
 for(int i=0;i<5;i++)add(2,2,1);assert(m.tracks[1].state==C9H_ALARM&&m.event_id==2);
 for(int i=0;i<20;i++)add(1,i%2?1:2,1);assert(m.tracks[0].state==C9H_NORMAL);
 for(int i=0;i<300;i++)add(1,1,1);assert(m.history_count==256&&m.history_overwritten>0);
 c9h_clock(&m,6000000u,1000u);assert(!m.tracks[1].fresh&&m.tracks[1].state==C9H_ALARM);
 m.enabled=0;unsigned cursor=m.cursor;add(1,2,1);assert(m.cursor==cursor);
 printf("C9_HEALTH_PASS sizeof=%u records=%u events=%u\n",(unsigned)sizeof(m),m.cursor,m.event_id);
 return 0;
}
