/* Native behavioral checks. Observation times and expected angular identity
 * come from explicit synthetic scenes, not the association implementation. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "circular9_tracking.h"
static unsigned checks;
#define CHECK(condition,message) do{checks++;if(!(condition)){fprintf(stderr,"TRACKING_FAIL line=%d %s\n",__LINE__,message);exit(1);}}while(0)
static c9_candidate at(int az,int el,int score){
 c9_candidate c={.score=score,.azimuth_mdeg=az,.elevation_mdeg=el,
  .flags=C9_CANDIDATE_REFINED,.uncertainty_mdeg=2000};
 unsigned x=0,y=0;
 for(unsigned k=1;k<32;k++){
  if(abs(c9_direction_azimuth_mdeg[k]-az)<abs(c9_direction_azimuth_mdeg[x]-az))x=k;
  if(abs(c9_direction_elevation_mdeg[k]-el)<abs(c9_direction_elevation_mdeg[y]-el))y=k;
 }
 c.grid=y*32+x;return c;
}
static c9_track *by_id(c9_tracker *s,uint32_t id){
 for(unsigned i=0;i<3;i++)if(s->tracks[i].id==id)return &s->tracks[i];
 return NULL;
}
static c9_track *by_angle(c9_tracker *s,int az){
 for(unsigned i=0;i<3;i++)if(s->tracks[i].id&&s->tracks[i].candidate.azimuth_mdeg==az)return &s->tracks[i];
 return NULL;
}
static unsigned count(const c9_tracker *s){
 unsigned n=0;for(unsigned i=0;i<3;i++)if(s->tracks[i].id)n++;return n;
}
static void supported(c9_tracker *s,const c9_candidate *c,unsigned n,unsigned frames){
 for(unsigned i=0;i<frames;i++)c9_tracks_update(s,c,n,i*3125u,7,1);
}
static void recovery_and_coverage(void){
 c9_tracker s={0};c9_candidate c=at(-27000,1500,80);supported(&s,&c,1,61);
 c9_track *t=by_angle(&s,-27000);CHECK(t&&t->state==C9_TRACK_OBSERVED,"stable candidate observed");
 uint32_t id=t->id,origin=t->first_sample,observations=t->observations;
 CHECK(c9_track_covers(t,0),"continuous original observation interval supported");
 c9_tracks_update(&s,NULL,0,190625,7,1);t=by_id(&s,id);
 CHECK(t&&t->state==C9_TRACK_COASTING&&t->observations==observations,"one missing map retains identity without an observation");
 CHECK(t->confidence_q15<32767&&!c9_track_covers(t,40000),"missing map reduces confidence and stops fault routing");
 uint32_t confidence=t->confidence_q15;c9_tracks_update(&s,NULL,0,193750,7,1);t=by_id(&s,id);
 CHECK(t&&t->confidence_q15<confidence,"second miss monotonically reduces confidence");
 c9_tracks_update(&s,&c,1,196875,7,1);t=by_id(&s,id);
 CHECK(t&&t->first_sample==origin&&t->fresh_observations==1&&t->state==C9_TRACK_RECOVERING,"first return keeps stable origin but requires fresh evidence");
 CHECK(!c9_track_covers(t,40000),"first return cannot revive diagnostic binding");
 c9_tracks_update(&s,&c,1,200000,7,1);CHECK(!c9_track_covers(by_id(&s,id),40000),"second return is still recovering");
 c9_tracks_update(&s,&c,1,203125,7,1);t=by_id(&s,id);
 CHECK(t&&t->state==C9_TRACK_OBSERVED&&t->gap_count==1,"third return restores supported state");
 CHECK(t->gaps[0].first==187500&&t->gaps[0].end==196875,"uncertain interval spans the whole unobserved 60 ms");
 CHECK(c9_track_covers_range(t,43125,203125),"a full 1.024-second range with 60 ms missing is supported");
 CHECK(!c9_track_covers_range(t,185000,203125),"short range cannot dilute its missing fraction using old observations");
 c9_candidate forwarded=c9_track_candidate(t);
 CHECK(forwarded.azimuth_mdeg==-27000&&forwarded.elevation_mdeg==1500&&forwarded.uncertainty_mdeg==2000,"refinement and uncertainty survive tracker and job forwarding");

 s=(c9_tracker){0};supported(&s,&c,1,61);id=by_angle(&s,-27000)->id;
 c9_tracks_update(&s,NULL,0,203125,7,1); /* A 100 ms miss is within coast lifetime. */
 CHECK(by_id(&s,id)&&by_id(&s,id)->state==C9_TRACK_COASTING,"100 ms miss retains ID");
 for(uint32_t sample=206250;sample<=212500;sample+=3125)c9_tracks_update(&s,&c,1,sample,7,1);
 t=by_id(&s,id);CHECK(t&&t->first_sample==0,"stable anchor survives a bounded 100 ms miss");
 CHECK(!c9_track_covers_range(t,52500,212500),"120 ms uncertain interval exceeds ten percent of 1.024 s");
 for(uint32_t sample=215625;sample<=381250;sample+=3125)c9_tracks_update(&s,&c,1,sample,7,1);
 t=by_id(&s,id);CHECK(t&&c9_track_covers_range(t,221250,381250),"fresh full observation window recovers support");
 CHECK(!c9_track_covers_range(t,0,160000),"pruned uncertain history cannot validate an old range");
}
static void expiry_and_capacity(void){
 c9_candidate c=at(10000,0,100);c9_tracker s={0};supported(&s,&c,1,3);
 uint32_t id=by_angle(&s,10000)->id,last=6250;
 c9_tracks_update(&s,NULL,0,last+C9_TRACK_COAST_SAMPLES-1,7,1);
 CHECK(by_id(&s,id)&&by_id(&s,id)->state==C9_TRACK_COASTING,"identity retained just below 150 ms");
 c9_tracks_update(&s,NULL,0,last+C9_TRACK_COAST_SAMPLES,7,1);
 CHECK(!by_id(&s,id)&&!count(&s),"identity expires exactly at coast bound");
 c9_tracks_update(&s,&c,1,last+31250u,7,1);
 CHECK(by_angle(&s,10000)&&by_angle(&s,10000)->id!=id,"reappearance at 200 ms creates a new identity");
 c9_candidate old[3]={at(-60000,0,100),at(0,0,200),at(60000,0,300)};
 s=(c9_tracker){0};c9_tracks_update(&s,old,3,0,7,1);id=by_angle(&s,-60000)->id;
 uint32_t center=by_angle(&s,0)->id,right=by_angle(&s,60000)->id;
 c9_candidate replacement[3]={at(30000,0,100000),old[2],old[1]};
 for(uint32_t sample=3125;sample<=21875;sample+=3125){
  c9_tracks_update(&s,replacement,3,sample,7,1);
  CHECK(by_id(&s,id)&&!by_angle(&s,30000),"new loud candidate cannot steal an unexpired coasting slot");
 }
 c9_tracks_update(&s,replacement,3,25000,7,1);
 CHECK(!by_id(&s,id)&&by_angle(&s,30000)&&count(&s)==3,"expired coasting slot admits waiting newcomer");
 CHECK(by_angle(&s,0)->id==center&&by_angle(&s,60000)->id==right,"capacity replacement preserves supported identities");
}
static void rank_motion_and_merge(void){
 c9_tracker s={0};c9_candidate c[2]={at(-30000,0,100),at(30000,0,500)};
 c9_tracks_update(&s,c,2,0,7,1);uint32_t left=by_angle(&s,-30000)->id,right=by_angle(&s,30000)->id;
 for(unsigned k=1;k<=5;k++){
  c9_candidate reversed[2]={at(30000-(int)k*2000,0,20),at(-30000+(int)k*2000,0,10000)};
  c9_tracks_update(&s,reversed,2,k*3125u,7,1);
  CHECK(by_angle(&s,-30000+(int)k*2000)->id==left&&by_angle(&s,30000-(int)k*2000)->id==right,"moving directions retain identities across rank changes");
 }
 CHECK(by_id(&s,left)->first_sample==12500&&!c9_track_covers(by_id(&s,left),0),"motion exceeding 7.5 degrees invalidates the old stable span");
 c9_candidate merged[2]={at(-6000,0,100),at(6000,0,50)};
 s=(c9_tracker){0};supported(&s,merged,2,3);left=by_angle(&s,-6000)->id;right=by_angle(&s,6000)->id;
 c9_candidate one_peak=at(0,0,1000);c9_tracks_update(&s,&one_peak,1,9375,7,1);
 CHECK(count(&s)==2&&by_id(&s,left)->state==C9_TRACK_COASTING&&by_id(&s,right)->state==C9_TRACK_COASTING,"one NMS-merged ambiguous peak cannot manufacture two source observations or a third identity");
 for(uint32_t sample=12500;sample<=18750;sample+=3125)c9_tracks_update(&s,merged,2,sample,7,1);
 CHECK(by_angle(&s,-6000)->id==left&&by_angle(&s,6000)->id==right,"resolved angular sources recover original IDs");
 CHECK(!c9_track_covers_range(by_id(&s,left),0,18750),"brief recovery does not hide a large uncertain fraction");
}
static void counters_and_invalid_input(void){
 c9_tracker s={0};c9_candidate c=at(-12000,0,100);supported(&s,&c,1,3);
 c9_tracker original=s;c9_tracks_update(&s,NULL,0,6250,7,1);
 CHECK(!memcmp(&s,&original,sizeof(s)),"duplicate timestamp is a strict no-op");
 c9_tracks_update(&s,NULL,0,6000,7,1);CHECK(!memcmp(&s,&original,sizeof(s)),"out-of-order map is a strict no-op");
 uint32_t id=by_angle(&s,-12000)->id;c9_tracks_update(&s,&c,1,6250,7,2);
 CHECK(by_angle(&s,-12000)->id!=id&&!c9_track_covers(by_angle(&s,-12000),0),"session change resets even with identical PCM timestamp");
 id=by_angle(&s,-12000)->id;c9_tracks_update(&s,&c,1,6500,UINT32_MAX,2);
 CHECK(by_angle(&s,-12000)->id!=id,"epoch change resets identity");
 id=by_angle(&s,-12000)->id;c9_tracks_update(&s,&c,1,6750,0,2);
 CHECK(by_angle(&s,-12000)->id!=id,"epoch wrap resets identity");
 s=(c9_tracker){0};c9_tracks_update(&s,&c,1,UINT32_MAX-2000u,7,UINT32_MAX);
 id=by_angle(&s,-12000)->id;c9_tracks_update(&s,&c,1,1000,7,UINT32_MAX);
 CHECK(by_angle(&s,-12000)->id!=id&&by_angle(&s,-12000)->first_sample==1000,"PCM counter wrap starts a new identity era");
 id=by_angle(&s,-12000)->id;c9_tracks_update(&s,&c,1,2000,7,0);
 CHECK(by_angle(&s,-12000)->id!=id,"session counter wrap resets identity");
 s=(c9_tracker){0};c9_candidate pair[3]={at(-50000,0,1),at(0,0,2),at(50000,0,3)};
 c9_tracks_update(&s,pair,2,0,7,1);s.next_id=UINT32_MAX;c9_tracks_update(&s,pair,3,3125,7,1);
 CHECK(count(&s)==3&&by_angle(&s,50000)->id!=0&&by_angle(&s,50000)->id!=by_angle(&s,0)->id&&by_angle(&s,50000)->id!=by_angle(&s,-50000)->id,"ID allocation wrap skips zero and every active ID");
 c9_tracker empty={0};c9_candidate bad={.grid=1024,.score=1000};c9_tracks_update(&empty,&bad,1,0,7,1);
 CHECK(!count(&empty),"invalid grid cannot create a source");
 bad=(c9_candidate){.grid=16*32+16,.score=0};c9_tracks_update(&empty,&bad,1,3125,7,1);
 CHECK(!count(&empty),"zero-evidence candidate cannot create a source");
 c9_tracks_update(&empty,NULL,3,6250,7,1);CHECK(!count(&empty),"null candidate input cannot create a source");
 s=(c9_tracker){0};supported(&s,&c,1,3);id=by_angle(&s,-12000)->id;
 c9_tracks_update(&s,&c,1,14000,7,1);
 CHECK(by_id(&s,id)&&by_id(&s,id)->state==C9_TRACK_RECOVERING&&!c9_track_covers(by_id(&s,id),0),"an unobserved map-processing hole longer than 40 ms requires fresh recovery");
}
static void support_boundaries_and_overflow(void){
 c9_candidate c=at(0,0,1);c9_tracker s={0};supported(&s,&c,1,61);c9_track t=*by_angle(&s,0);
 t.first_sample=0;t.coverage_first=0;t.last_sample=100000;t.gap_count=1;t.gaps[0]=(c9_track_gap){20000,30000};
 CHECK(c9_track_covers_range(&t,0,100000),"exactly ninety percent angular support is accepted");
 t.gaps[0].end++;CHECK(!c9_track_covers_range(&t,0,100000),"one sample below ninety percent support is rejected");
 t.gap_count=0;CHECK(!c9_track_covers_range(&t,0,111112),"unobserved future tail is not counted as angular evidence");
 s=(c9_tracker){0};supported(&s,&c,1,3);uint32_t id=by_angle(&s,0)->id;
 uint32_t sample=6250;
 for(unsigned k=0;k<=C9_TRACK_GAPS;k++){
  sample+=200;c9_tracks_update(&s,NULL,0,sample,7,1);
  sample+=200;c9_tracks_update(&s,&c,1,sample,7,1);
 }
 c9_track *track=by_id(&s,id);
 CHECK(track&&track->first_sample==sample&&!c9_track_covers(track,0),"missing-interval capacity overflow conservatively resets stability");
}
static void true_interval_coverage(void){
 c9_tracker s={0};s.next_id=0x40000000u;c9_candidate weak=at(42000,0,50);
 c9_tracks_update_interval(&s,&weak,1,0,16384,7,1);
 uint32_t id=by_angle(&s,42000)->id;CHECK(id>=0x40000000u,"auxiliary tracks use an independent ID namespace");
 c9_tracks_update_interval(&s,&weak,1,8192,24576,7,1);
 CHECK(!c9_track_covers_range(by_id(&s,id),0,C9_SNAPSHOT_FRAMES),"two short FFT intervals cannot qualify a full diagnostic window");
 c9_tracker saved=s;c9_tracks_update_interval(&s,&weak,1,8192,24576,7,1);
 CHECK(!memcmp(&s,&saved,sizeof(s)),"one auxiliary FFT result cannot be replayed into new support");
 for(uint32_t end=32768;end<=180224;end+=8192)c9_tracks_update_interval(&s,&weak,1,end-16384,end,7,1);
 c9_track *track=by_id(&s,id);
 CHECK(track&&track->observations>=20&&track->gap_count==0&&c9_track_covers_range(track,180224-C9_SNAPSHOT_FRAMES,180224),"real overlapping auxiliary intervals cover1.024s despite no broadband weak peak");
 uint32_t old=track->observations;c9_tracks_update_interval(&s,&weak,1,0,1000,7,1);
 CHECK(by_id(&s,id)->observations==old,"old auxiliary ends cannot advance track observations");
 c9_tracks_update_interval(&s,&weak,1,180224+17000,180224+20000,7,1);
 track=by_id(&s,id);
 CHECK(track&&track->gap_count==1&&!c9_track_covers_range(track,200224-C9_SNAPSHOT_FRAMES,200224),"unobserved interval outside measured FFT windows is retained as a real coverage hole");
 c9_tracks_update_interval(&s,&weak,1,0,0,7,1);
 CHECK(by_id(&s,id)->gap_count==1,"empty auxiliary intervals cannot erase missing evidence");
}
int main(void){
 recovery_and_coverage();expiry_and_capacity();rank_motion_and_merge();counters_and_invalid_input();support_boundaries_and_overflow();
 true_interval_coverage();
 printf("C9_TRACKING_PASS checks=%u coast_samples=%u map_gap_samples=%u support_percent=%u track_bytes=%zu\n",
  checks,C9_TRACK_COAST_SAMPLES,C9_TRACK_MAX_MAP_GAP_SAMPLES,C9_TRACK_SUPPORT_PERCENT,sizeof(c9_track));return 0;
}
