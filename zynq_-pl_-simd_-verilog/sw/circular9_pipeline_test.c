/* Execute the real CPU0/CPU1 task and HTTP helpers with native-only MMIO,
 * cache and clock doubles. This is not a Cortex-A9 timing/cache experiment. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "acoustic_circular9_image.h"
/* A named simulation fixture: production geometry remains unconfirmed. */
#undef ACOUSTIC_GEOMETRY_CONFIRMED
#undef ACOUSTIC_CALIBRATION_VERSION
#define ACOUSTIC_GEOMETRY_CONFIRMED 1u
#define ACOUSTIC_CALIBRATION_VERSION 0x54455354u
#define UI_SHAFT_MILLIHZ 25000u
#define RV32_BASE 0u
#define NORM_WB_CACHE 0x54455354u
#include "ps_ui_page.h"
#include "circular9_deadline.h"
/* Reuse independent geometric multisine generation, never the separation
 * implementation as an expected-answer oracle. Its standalone main is idle. */
#define main circular9_candidate_fixture_main
#include "circular9_candidates_test.c"
#undef main

typedef intptr_t INTPTR;
static unsigned cache_flushes,noncache_maps,checkpoints;
static void (*checkpoint_hook)(void);
static void Xil_DCacheFlushRange(INTPTR address,size_t length){CHECK(address&&length,"cache flush range");cache_flushes++;}
static void Xil_SetTlbAttributes(INTPTR address,uint32_t flags){CHECK(address&&flags==NORM_WB_CACHE,"noncached shared mapping");noncache_maps++;}
static uint32_t ticks=100000000u;
static uint32_t delayed_timer_reads,delayed_timer_ticks;
static uint32_t dia_gtimer_now(void){ticks+=3333;if(delayed_timer_reads&&!--delayed_timer_reads)ticks+=delayed_timer_ticks;return ticks;}
static uint32_t dia_ticks_to_ms(uint32_t delta){return delta/333333u;}
static uint32_t c9_ticks_to_us(uint32_t delta){return delta/333u;}
static void c9_realtime_checkpoint(void){checkpoints++;ticks+=333;if(checkpoint_hook)checkpoint_hook();}
struct ipc_page {volatile uint32_t busy;};
static struct {
 uint32_t index,sequence,sample,reason,frame,pl_first,pl_age;
 uint32_t command,commands,data_reads,mutate_at;
 int32_t scores[1024];
} device;
static uint32_t device_read(void *ctx,uint32_t offset){
 (void)ctx;ticks+=33;
 if(offset==0x3e0)return device.pl_first+(device.pl_age?device.pl_age:300000u);
 if(offset!=0x88)return 0;
 uint32_t index=device.index++;
 if(index>=0x80000a00u){
  switch(index-0x80000a00u){
   case 90:return device.sequence;case 235:return 0x1000u;
   case 1:return device.frame;case 93:return device.sample;
   case 97:return device.reason;case 239:return device.pl_first;
   default:return 0;
  }
 }
 if(index>=0x80000400u&&index<0x80000800u){
  device.data_reads++;
  if(device.mutate_at&&device.data_reads%device.mutate_at==0)device.sequence+=2;
  return (uint32_t)device.scores[index-0x80000400u];
 }
 return 0;
}
static void device_write(void *ctx,uint32_t offset,uint32_t value){
 (void)ctx;ticks+=33;
 if(offset==0x80)device.index=value;
 if(offset==0x3c){device.command=value;device.commands++;}
}
static das_bus das_axi_bus(uintptr_t base){(void)base;return(das_bus){NULL,device_read,device_write};}
static c9_candidate applied_candidate;static uint32_t applied_epoch;
static unsigned release_calls,apply_target_accept=1;
static int c9_apply_target(const das_bus *b,const c9_candidate *candidate,uint32_t epoch){
 applied_candidate=*candidate;applied_epoch=epoch;
 if(!apply_target_accept)return 0;
 if(device.command!=(0xd1000000u|candidate->grid))b->write(b->ctx,0x3c,0xd1000000u|candidate->grid);
 return 1;
}
static void c9_release_target(const das_bus *b){release_calls++;if(device.command!=0xd3000000u)b->write(b->ctx,0x3c,0xd3000000u);}
static int c9_control_route(const char *request,struct ui_reply *rep,char *body,size_t cap){
 (void)request;(void)rep;(void)body;(void)cap;return 0;
}
/* PE/COFF cannot express a 1-MiB object alignment. Native cache/TLB doubles do
 * not map hardware pages; only this fixture substitutes its supported 8 KiB.
 * Production ARM source retains the 1-MiB alignment/linker reservation. */
#define aligned(c9_native_alignment) aligned(8192)
#include "ps_circular9_tasks.h"
#undef aligned
#include "ps_circular9_api.h"
static c9_candidate scene[3]={{.grid=16*32+5,.score=1000},{.grid=16*32+16,.score=300},{.grid=16*32+27,.score=2000}};
static char body[32768];
static struct ui_reply route(const char *request){
 struct ui_reply rep={0};CHECK(c9_tasks_route(request,&rep,body,sizeof(body)),"recognized API request");return rep;
}
static uint32_t audio_hash(const int16_t *pcm){
 uint32_t value=2166136261u;for(unsigned i=0;i<C9_AUDIO_FRAMES;i++){value^=(uint16_t)pcm[i];value*=16777619u;}return value;
}
static void run_cpu1_pending(struct ipc_page *ipc){
 for(unsigned i=0;i<4;i++){
  if(c9_tasks_shared.data.job.state!=1u&&c9_tasks_shared.data.auxiliary.job.state!=1u)break;
  c9_tasks_cpu1(ipc);
 }
}
static void complete_queued_job(void){
 checkpoint_hook=NULL;struct ipc_page ipc={0};run_cpu1_pending(&ipc);
 CHECK(!ipc.busy&&c9_tasks_shared.data.job.state==0,"CPU1 completes next job during HTTP checkpoint");
}
static void map_scene_mask(unsigned mask){
 memset(device.scores,0,sizeof(device.scores));
 for(unsigned i=0;i<3;i++)if(mask&(1u<<i))device.scores[scene[i].grid]=scene[i].score;
}
static void map_scene(unsigned count){map_scene_mask((1u<<count)-1u);}
static void map_publish_mask(const das_bus *bus,uint32_t sample,unsigned mask){
 ticks+=6666666u;device.sequence+=2;device.frame++;
 device.sample=sample;device.pl_first+=800000u;map_scene_mask(mask);
 for(unsigned k=0;k<40;k++)c9_tasks_map_poll(bus);
}
static void map_publish(const das_bus *bus,uint32_t sample,unsigned count){map_publish_mask(bus,sample,(1u<<count)-1u);}
static void push_pcm(uint32_t begin,uint32_t end){
 uint32_t p[16];
 for(uint32_t seq=begin;seq<end;seq++){
  memset(p,0,sizeof(p));p[1]=seq;p[14]=7;
  for(unsigned ch=0;ch<9;ch++)p[8+ch/2]|=(uint32_t)(uint16_t)raw[seq%C9_SNAPSHOT_FRAMES][ch]<<(16*(ch&1));
  c9_record_sample(p);
 }
}
static uint32_t id_at(const c9_tracker *tracker,uint32_t grid){
 for(unsigned i=0;i<3;i++)if(tracker->tracks[i].grid==grid)return tracker->tracks[i].id;
 return 0;
}
static void tracking_tests(void){
 c9_tracker tracker={0};c9_candidate c[3]={scene[0],scene[1],scene[2]};
 c9_tracks_update(&tracker,c,3,0,7,1);
 uint32_t id=id_at(&tracker,c[1].grid);
 c9_candidate swapped[3]={c[2],c[0],c[1]};
 c9_tracks_update(&tracker,swapped,3,3125,7,1);
 CHECK(id_at(&tracker,c[1].grid)==id,"rank changes retain direction identity");
 c9_tracks_update(&tracker,c,3,6250,7,1);
 const c9_track *track=NULL;for(unsigned i=0;i<3;i++)if(tracker.tracks[i].id==id)track=&tracker.tracks[i];
 CHECK(track&&c9_track_covers(track,0),"three observations cover initial snapshot start");
 c[1].grid+=2; /*11.25 degrees: association retained, stability resets. */
 c9_tracks_update(&tracker,c,3,9375,7,1);
 track=NULL;for(unsigned i=0;i<3;i++)if(tracker.tracks[i].id==id)track=&tracker.tracks[i];
 CHECK(track&&track->first_sample==9375&&!c9_track_covers(track,0),"motion invalidates earlier binding");
 c[1].grid-=2;c9_tracks_update(&tracker,c,3,12500,7,1);
 track=NULL;for(unsigned i=0;i<3;i++)if(tracker.tracks[i].id==id)track=&tracker.tracks[i];
 CHECK(track&&track->first_sample==12500&&!c9_track_covers(track,0),"direction return cannot revive old stable window");
 c9_tracks_update(&tracker,c,1,15625,7,1);
 CHECK(id_at(&tracker,scene[1].grid)==id&&track->state==C9_TRACK_COASTING&&!c9_track_covers(track,12500),"missing source keeps ID but supplies no diagnosis evidence");
 c9_tracks_update(&tracker,c,3,18750,7,1);
 CHECK(id_at(&tracker,scene[1].grid)==id&&track->state==C9_TRACK_RECOVERING,"short miss returns into recovery with original identity");
 for(uint32_t sample=21875;sample<=200000;sample+=3125)c9_tracks_update(&tracker,c,3,sample,7,1);
 CHECK(track->first_sample==12500&&c9_track_covers_range(track,39744,200000),"a fresh common diagnostic window recovers without resetting the stable anchor");
 c9_tracks_update(&tracker,c,1,200000+C9_TRACK_COAST_SAMPLES,7,1);
 CHECK(!id_at(&tracker,scene[1].grid),"source expires at bounded coast lifetime");
 c9_tracks_update(&tracker,c,3,225000,7,1);
 CHECK(id_at(&tracker,scene[1].grid)!=id,"source reappearing after expiry has new identity");
 uint32_t before=id_at(&tracker,c[0].grid);c9_tracks_update(&tracker,c,3,228125,7,2);
 CHECK(id_at(&tracker,c[0].grid)!=before,"new capture session invalidates all prior identities");
 puts("TRACKING_PIPELINE_PASS");
}
static c9_diag_model score_fixture(const c9_diag_binding *binding){
 c9_diag_model m={0};m.abi=C9_DIAG_MODEL_ABI;m.feature_contract=C9_DIAG_FEATURE_CONTRACT;
 m.version=0x54455354u;m.kind=2;m.validated=1;m.shaft_hz_min=10;m.shaft_hz_max=30;m.rms_min=.001;
 m.minimum_margin=1.25;m.anomaly_multiplier=2;m.separation_contract=C9_DIAG_SEPARATION_CONTRACT;m.mask_count=1;
 memcpy(m.allowed_masks[0],binding->usable_mask,sizeof(binding->usable_mask));
 for(unsigned i=0;i<C9_DIAG_FEATURES;i++){m.inverse_variance[i]=1;m.center[1][i]=10;m.center[2][i]=-10;}
 for(unsigned i=0;i<3;i++)m.radius[i]=2;
 return m;
}
static void inject_fault(c9_diag_report *report){
 double features[C9_DIAG_FEATURES];for(unsigned i=0;i<C9_DIAG_FEATURES;i++)features[i]=10;
 c9_diag_binding binding=report->binding;c9_diag_model model=score_fixture(&binding);
 c9_diag_score_features(features,.1,25,&binding,&model,report);
 CHECK(report->fault_direction_valid,"synthetic score-space fixture yields bound fault");
}
static void refined_result_guard(const c9_diagnostic_result *r){
 c9_diag_report diagnosed=r->diagnosis[0];c9_track *track=NULL;
 for(unsigned i=0;i<3;i++)if(c9_tracks.tracks[i].id==diagnosed.binding.track_id)track=&c9_tracks.tracks[i];
 CHECK(track!=NULL,"refined-angle guard has a real supported track binding");if(!track)return;
 c9_track saved=*track;uint32_t saved_ticks=ticks;
 /* Keep the original snapshot, session, identity and support history. Only
  * the named refined-angle inputs change; neighboring coarse addresses are
  * only 5.625 degrees apart while the valid refined directions differ by
  * eight degrees. A grid-only comparison cannot reject this case. */
 uint32_t grid=16u*32u+16u;
 track->grid=grid;track->anchor=grid;
 track->anchor_candidate=(c9_candidate){.grid=grid,.score=100,.azimuth_mdeg=0,.elevation_mdeg=0,.flags=C9_CANDIDATE_REFINED};
 track->candidate=(c9_candidate){.grid=grid,.score=100,.azimuth_mdeg=3000,.elevation_mdeg=0,.flags=C9_CANDIDATE_REFINED};
 diagnosed.binding.grid=grid-1;diagnosed.binding.azimuth_mdeg=-4000;diagnosed.binding.elevation_mdeg=0;
 CHECK(c9_result_current(&diagnosed,r->session,r->shaft_generation),"seven-degree refined diagnosis-to-current drift remains inside the guard");
 track->candidate.azimuth_mdeg=4000;
 CHECK(c9_track_direction_dot(&track->anchor_candidate,&track->candidate)>.9914448613738104&&c9_direction_dot(track->grid,diagnosed.binding.grid)>.9914448613738104,"eight-degree diagnosis drift fixture still passes anchor and coarse-grid comparisons");
 CHECK(!c9_result_current(&diagnosed,r->session,r->shaft_generation),"minus-four-degree diagnosed direction cannot bind a plus-four-degree current direction");
 *track=saved;ticks=saved_ticks;
 CHECK(c9_result_current(&r->diagnosis[0],r->session,r->shaft_generation),"focused angle test restores the original valid global track state");
}
static void pipeline_tests(const char *output){
 das_bus bus=das_axi_bus(0);c9_tasks_init();
 CHECK(cache_flushes==2&&noncache_maps==33,"32MiB history and task shared sections mapped noncached");
 unsigned release_before=release_calls;
 CHECK(route("GET /api/target/fault HTTP/1.1").code==202&&device.command==0xd3000000u&&release_calls==release_before+1u,"fault mode explicitly releases any old fine-steering commit and starts held D3");
 CHECK(route("GET /api/rpm?value=1500 HTTP/1.1").code==409&&!c9_shaft_confirmed,"RPM confirmation waits for a live capture session");
 rng=0x19327561;synthesize(scene,7,0,0);
 push_pcm(0,1);
 CHECK(route("GET /api/rpm?value=1500 HTTP/1.1").code==200&&c9_shaft_confirmed&&c9_shaft_millihz==25000,"operator RPM confirmation");
 uint32_t observed=c9_tracks.tracks[0].observations,retries=c9_map_retries;
 /* Deliberately change publication seqlock while a map is being copied. */
 ticks+=40000000u;device.sequence+=2;device.data_reads=0;device.mutate_at=80;
 device.pl_first=4800000u;map_scene(3);
 for(unsigned k=0;k<40;k++)c9_tasks_map_poll(&bus);
 device.mutate_at=0;
 CHECK(c9_map_retries>retries&&c9_tracks.tracks[0].observations==observed,"mid-copy map change discarded");
 retries=c9_map_retries;device.sequence+=2;device.pl_age=6000000u;
 for(unsigned k=0;k<40;k++)c9_tasks_map_poll(&bus);
 CHECK(c9_map_retries>retries&&!c9_tracks.tracks[0].id,"new seqlock with stale physical capture timestamp rejected");
 device.pl_age=300000u;
 map_publish(&bus,0,3);
 uint32_t next=1;
 for(unsigned sample=3125;sample<=156250;sample+=3125){push_pcm(next,sample+1);next=sample+1;map_publish(&bus,sample,3);}
 push_pcm(next,C9_SNAPSHOT_FRAMES+4);
 /* Re-polling one seqlock must never count the same map as a new observation. */
 observed=c9_tracks.tracks[0].observations;ticks+=40000000u;
 for(unsigned k=0;k<40;k++)c9_tasks_map_poll(&bus);
 CHECK(c9_tracks.tracks[0].observations==observed,"duplicate map never manufactures stability");
 CHECK(c9_map_copies>=51&&c9_map_max_us<1000,"bounded map copies complete inside publication interval in named mock timing");
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.count==3,"three stable candidates scheduled once");
 uint32_t scheduled=c9_jobs_started;c9_tasks_schedule();CHECK(c9_jobs_started==scheduled,"pending job never overwritten");
 struct ipc_page ipc={0};run_cpu1_pending(&ipc);CHECK(!ipc.busy&&c9_tasks_shared.data.job.state==0,"CPU1 completes owned job");
 c9_tasks_receive();CHECK(c9_latest_slot>=0,"CPU0 adopts completed result");
 c9_diagnostic_result *r=&c9_tasks_shared.data.results[c9_latest_slot];
 CHECK(r->count==3&&r->separation.ready_mask==7&&r->state==3,"one owned snapshot yields three separated outputs");
 for(unsigned i=0;i<r->count;i++){
  CHECK(r->diagnosis[i].label==C9_DIAG_UNKNOWN&&r->diagnosis[i].reason==C9_DIAG_NO_MODEL&&!r->diagnosis[i].fault_direction_valid,"unconfigured real PS diagnosis stays unknown");
  CHECK(r->diagnosis[i].binding.first_sample==r->first_sample&&r->diagnosis[i].binding.epoch==7,"same capture snapshot bound to every result");
  CHECK(r->diagnosis[i].binding.separation_contract==C9_DIAG_SEPARATION_CONTRACT&&!memcmp(r->diagnosis[i].binding.usable_mask,r->separation.usable_mask,sizeof(r->separation.usable_mask)),"actual separation mask bound to diagnosis");
  CHECK(r->diagnosis[i].feature_contract==0x43394632u&&r->diagnosis[i].extraction.fft_count==1&&r->diagnosis[i].extraction.observation_seconds>.99,"C9F2 extraction retains the full separated observation");
  c9_candidate forwarded=c9_track_candidate(&c9_tasks_shared.data.job.tracks[i]);int32_t az=0,el=0;c9_candidate_angles(&forwarded,&az,&el);
  CHECK(r->diagnosis[i].binding.azimuth_mdeg==az&&r->diagnosis[i].binding.elevation_mdeg==el,"actual forwarded candidate angles remain bound to separated diagnosis");
 }
 refined_result_guard(r);
 uint32_t commands=device.commands;c9_tasks_select_fault(&bus);
 CHECK(device.commands==commands&&device.command==0xd3000000u,"no-model audio cannot steer fault target");
 struct ui_reply rep=route("GET /api/candidates HTTP/1.1");
 CHECK(rep.code==200&&rep.len>0&&strstr(body,"\"label\":\"unknown\"")&&strstr(body,"\"fault_direction_valid\":0"),"HTTP candidate JSON contains honest unknown diagnosis");
 FILE *f=fopen(output,"wb");CHECK(f!=NULL,"JSON evidence output");if(f){fwrite(body,1,(size_t)rep.len,f);fclose(f);}
 CHECK(c9_candidates_json(body,64)<0,"short JSON capacity is rejected");
 struct ui_reply short_reply={0};CHECK(c9_tasks_route("GET /api/candidates HTTP/1.1",&short_reply,body,64)&&short_reply.code==500&&short_reply.len==0,"HTTP refuses truncated candidate JSON");
 uint32_t sequence=r->sequence;char request[200];
 snprintf(request,sizeof(request),"GET /api/candidate/audio?sequence=%u&index=0&offset=39999&count=1 HTTP/1.1",sequence);
 rep=route(request);uint16_t sample=(uint8_t)body[0]|(uint16_t)(uint8_t)body[1]<<8;
 CHECK(rep.code==200&&rep.len==2&&sample==(uint16_t)r->audio[0][39999],"last sample exported exact little endian");
 snprintf(request,sizeof(request),"GET /api/candidate/audio?sequence=%u&index=0&offset=40000&count=1 HTTP/1.1",sequence);CHECK(route(request).code==400,"audio end overrun rejected");
 snprintf(request,sizeof(request),"GET /api/candidate/audio?sequence=%u&index=0&offset=0&count=513 HTTP/1.1",sequence);CHECK(route(request).code==400,"audio chunk maximum enforced");
 snprintf(request,sizeof(request),"GET /api/candidate/audio?sequence=%u&index=3&offset=0&count=1 HTTP/1.1",sequence);CHECK(route(request).code==409,"missing candidate rejected");
 unsigned old=(unsigned)c9_latest_slot,other=old^1u;
 /* Force a second legitimate job eligible in the fixture without waiting two
  * seconds of host time. During JSON serialization only CPU1 completes; CPU0
  * adoption stays in its main loop, exactly as the runtime checkpoint does. */
 c9_schedule.have=0;c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1,"next job queued while prior audio pinned");
 r->audio[0][0]=12345;uint32_t hash=audio_hash(r->audio[0]);checkpoint_hook=complete_queued_job;
 rep=route("GET /api/candidates HTTP/1.1");
 char sequence_text[48];snprintf(sequence_text,sizeof(sequence_text),"\"sequence\":%u",sequence);
 CHECK(rep.code==200&&strstr(body,sequence_text)&&c9_latest_slot==(int)old,"HTTP metadata retains one pinned result during CPU1 completion");
 CHECK(r->state==3&&audio_hash(r->audio[0])==hash&&c9_tasks_shared.data.results[other].state==2,"CPU1 never overwrites HTTP-owned audio");
 c9_tasks_receive();r=&c9_tasks_shared.data.results[c9_latest_slot];
 CHECK(c9_latest_slot==(int)other&&c9_tasks_shared.data.results[old].state==0,"new result adoption releases previous audio slot");
 snprintf(request,sizeof(request),"GET /api/candidate/audio?sequence=%u&index=0&offset=0&count=1 HTTP/1.1",sequence);CHECK(route(request).code==409,"evicted snapshot audio expires by sequence");
 c9_tasks_shared.data.results[old].sequence=sequence;c9_tasks_shared.data.results[old].state=2;c9_tasks_receive();
 CHECK(c9_latest_slot==(int)other&&c9_tasks_shared.data.results[old].state==0,"older publication cannot replace newest result");
 /* When neither output is free CPU1 drops a job instead of borrowing the
  * pinned slot. Restore the synthetic occupied spare afterwards. */
 c9_tasks_shared.data.results[old].state=3;c9_tasks_shared.data.job.state=1;
 hash=audio_hash(r->audio[0]);run_cpu1_pending(&ipc);
 CHECK(c9_tasks_shared.data.job.state==0&&r->state==3&&audio_hash(r->audio[0])==hash,"full output slots never reuse owned audio");
 c9_tasks_shared.data.results[old].state=0;
 /* Use a declared synthetic score-space model solely to execute steering
  * ownership decisions. It is never installed as a machine model. */
 inject_fault(&r->diagnosis[1]);c9_tasks_select_fault(&bus);
 CHECK((device.command&0xff000000u)==0xd1000000u&&c9_fault_track==r->diagnosis[1].binding.track_id,"one current validated fixture fault selects its bound angle");
 c9_track *active=NULL;for(unsigned i=0;i<3;i++)if(c9_tracks.tracks[i].id==c9_fault_track)active=&c9_tracks.tracks[i];
 CHECK(active!=NULL,"selected fault still has a live track");
 if(active){
  c9_candidate saved=active->candidate;active->candidate.flags|=C9_CANDIDATE_REFINED;active->candidate.azimuth_mdeg+=1000;
  c9_tasks_select_fault(&bus);
  CHECK(applied_candidate.azimuth_mdeg==active->candidate.azimuth_mdeg&&applied_epoch==r->epoch,"fine steering commits the current supported track angle rather than the one-second-old diagnosis angle");
  active->candidate=saved;
 }
 apply_target_accept=0;c9_tasks_select_fault(&bus);
 CHECK(!c9_fault_track&&device.command==0xd3000000u,"failed fine-target commit releases instead of retaining an old direction");
 apply_target_accept=1;c9_tasks_select_fault(&bus);
 inject_fault(&r->diagnosis[0]);c9_tasks_select_fault(&bus);
 CHECK(device.command==0xd3000000u&&!c9_fault_track,"two fault candidates hold D3 instead of choosing strongest");
 r->diagnosis[0].fault_direction_valid=0;c9_tasks_select_fault(&bus);
 CHECK(c9_fault_track!=0,"unique fault becomes steerable again");
 /* A current-data support check prevents EMA history from fabricating the
  * missing peak. The old result remains pinned, but fault routing and new
  * diagnosis must pause until angular support has recovered. */
 uint32_t recovered_id=r->diagnosis[1].binding.track_id;
 unsigned missing=0;while(missing<3&&scene[missing].grid!=r->diagnosis[1].binding.grid)missing++;
 CHECK(missing<3,"fault binding identifies its independent scene direction");
 uint32_t recorded=C9_SNAPSHOT_FRAMES+4;
 for(uint32_t sample=159375;sample<=162500;sample+=3125){
  if(sample+4>recorded){push_pcm(recorded,sample+4);recorded=sample+4;}
  map_publish_mask(&bus,sample,7u&~(1u<<missing));
  c9_tasks_select_fault(&bus);c9_schedule.have=0;c9_tasks_schedule();
  CHECK(id_at(&c9_tracks,scene[missing].grid)==recovered_id&&!c9_fault_track&&device.command==0xd3000000u&&c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.count==2&&c9_tasks_shared.data.job.unresolved_tracks==1,"coasting source retains ID and blocks fault routing without starving independently covered sources");
 }
 for(uint32_t sample=165625;sample<=171875;sample+=3125){
  push_pcm(recorded,sample+4);recorded=sample+4;map_publish(&bus,sample,3);
  c9_tasks_select_fault(&bus);
  if(sample<171875)CHECK(!c9_fault_track,"first two fresh angular observations cannot revive old fault steering");
 }
 CHECK(c9_fault_track==recovered_id,"third fresh support update recovers the uniquely bound fault direction");
 c9_schedule.have=0;c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.count==3,"recovered angular coverage schedules all three candidates from one new snapshot");
 run_cpu1_pending(&ipc);c9_tasks_receive();r=&c9_tasks_shared.data.results[c9_latest_slot];
 CHECK(r->count==3&&r->separation.ready_mask==7&&r->diagnosis[1].label==C9_DIAG_UNKNOWN&&!r->diagnosis[1].fault_direction_valid,"fresh recovery job separates and diagnoses without copying the injected old fault label");
 unsigned recovered_index=0;while(recovered_index<r->count&&r->diagnosis[recovered_index].binding.track_id!=recovered_id)recovered_index++;
 CHECK(recovered_index<r->count,"full recovery preserves angular identity independently of result ordering");
 if(recovered_index<r->count){CHECK(r->diagnosis[recovered_index].label==C9_DIAG_UNKNOWN&&!r->diagnosis[recovered_index].fault_direction_valid,"recovered identity does not inherit old fault label");inject_fault(&r->diagnosis[recovered_index]);}
 c9_tasks_select_fault(&bus);
 /* Freeze capture and map publication: sample counters alone cannot make an
  * old result remain current forever. */
 ticks+=100000000u;c9_tasks_select_fault(&bus);
 CHECK(device.command==0xd3000000u&&!c9_fault_track,"stopped stream invalidates fault by wall clock");
 /* Restore only this predicate's named time input to isolate the next guard;
  * map ingestion separately proved frozen/duplicate maps cannot do this. */
 c9_tracks_last_tick=dia_gtimer_now();
 CHECK(c9_result_current(&r->diagnosis[1],r->session,r->shaft_generation),"wall-clock rejection is independently effective");
 /* Operator changes speed and changes it back: generation must reject the
  * old model result even though the numeric speed happens to match again. */
 CHECK(route("GET /api/rpm?value=1200 HTTP/1.1").code==200,"RPM changed");
 CHECK(route("GET /api/rpm?value=1500 HTTP/1.1").code==200,"RPM returned");
 CHECK(!c9_result_current(&r->diagnosis[1],r->session,r->shaft_generation),"RPM generation prevents old result revival");
 CHECK(c9_result_current(&r->diagnosis[1],r->session,c9_shaft_generation),"RPM generation rejection isolated from other guards");
 CHECK(route("GET /api/rpm?value=599 HTTP/1.1").code==400&&route("GET /api/rpm?value=1801 HTTP/1.1").code==400,"RPM bounds enforced");
 CHECK(route("GET /api/rpm?value=4294968796 HTTP/1.1").code==400&&
  route("GET /api/rpm?value=+1500 HTTP/1.1").code==400&&route("GET /api/rpm?value=-4294965796 HTTP/1.1").code==400&&
  route("GET /api/rpm?value=1500x HTTP/1.1").code==400,"RPM integer overflow signs and suffixes cannot change shaft state");
 uint32_t completed_count=r->count;
 c9_diagnostic_job *pending=&c9_tasks_shared.data.job;
 pending->sequence=++c9_job_sequence;pending->state=1;
 c9_record_reset();CHECK(!c9_result_current(&r->diagnosis[1],r->session,c9_shaft_generation),"capture gap invalidates prior diagnostic session");
 rep=route("GET /api/candidates HTTP/1.1");
 CHECK(rep.code==200&&strstr(body,"\"stale\":1")&&!strstr(body,"\"fault_direction_valid\":1"),"HTTP cannot expose stale session as current fault");
 run_cpu1_pending(&ipc);c9_tasks_receive();
 const c9_diagnostic_result *invalid=&c9_tasks_shared.data.results[c9_latest_slot];
 CHECK(!invalid->count&&!invalid->separation.ready_mask,"loss after scheduling publishes empty result without reusing old audio labels");
 c9_schedule.have=0;c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==0,"gap cannot reschedule old history");
 ticks+=100000000u;c9_tasks_map_poll(&bus);
 CHECK(!c9_tracks.tracks[0].id&&!c9_tracks.tracks[1].id&&!c9_tracks.tracks[2].id,"frozen map plus elapsed wall clock clears stale tracks");
 printf("PS_PIPELINE_PASS candidates=%u separation_ready=%u jobs_started=%u map_retries=%u map_copies=%u mock_map_max_us=%u checkpoints=%u loss_result_count=%u coasting_frames=2 recovery_frames=3 recovered_jobs=1 refined_angle_guard=1 proposal_rejected=%u feature_contract=%u geometry_fixture=1 real_model=0 arm_timing_measured=0\n",completed_count,r->separation.ready_mask,c9_jobs_started,c9_map_retries,c9_map_copies,c9_map_max_us,checkpoints,invalid->count,c9_proposals.rejected,C9_DIAG_FEATURE_CONTRACT);
}
static void advance_supported(uint32_t first,uint32_t end){
 push_pcm(first,end);uint32_t session=0,epoch=0,count=0,current=0;
 CHECK(c9_history_info(&c9_history_shared.history,&current,&count,&epoch,&session),"sample-domain scheduler has real history metadata");
 uint32_t begin=c9_tracks.have_sample?c9_tracks.last_update:0;
 for(uint32_t sample=begin+3125;sample<end;sample+=3125)c9_tracks_update(&c9_tracks,scene,3,sample,epoch,session);
 c9_tracks_update(&c9_tracks,scene,3,end,epoch,session);c9_tracks_last_tick=dia_gtimer_now();
}
static void overlap_and_overload_tests(void){
 c9_tasks_init();c9_tracks=(c9_tracker){0};c9_aux_tracks=(c9_tracker){.next_id=0x40000000u};
 c9_schedule=(c9_diagnostic_schedule){0};c9_latest_slot=-1;c9_latest_sequence=0;
 c9_shaft_confirmed=0;c9_shaft_waiting=0;c9_shaft_generation++;c9_aux_have=0;
 /* Isolate diagnosis scheduling from the separately tested auxiliary worker. */
 c9_tasks_shared.data.auxiliary.job.state=2;
 uint32_t end=C9_SNAPSHOT_FRAMES+4u;push_pcm(0,1);c9_tracks_update(&c9_tracks,scene,3,0,7,1);advance_supported(1,end);
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.end_sample==end,"initial diagnosis selects one exact capture endpoint");
 struct ipc_page ipc={0};c9_tasks_cpu1(&ipc);c9_tasks_receive();
 CHECK(c9_latest_slot>=0&&c9_tasks_shared.data.results[c9_latest_slot].first_sample==4u,"CPU1 copies scheduled endpoint instead of drifting to a later snapshot");
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==0,"no repeated window when PCM clock has not advanced");
 advance_supported(end,end+C9_DIAGNOSTIC_HOP_RAW-4u);end+=C9_DIAGNOSTIC_HOP_RAW-4u;
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==0,"wall clock cannot make a512ms job due four samples early");
 advance_supported(end,end+4u);end+=4u;c9_tasks_schedule();
 CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.end_sample==end,"next full1.024s observation advances exactly80000raw samples");
 uint32_t skipped=c9_jobs_skipped,replaced=c9_pending_replaced;
 advance_supported(end,end+3u*C9_DIAGNOSTIC_HOP_RAW+1000u);end+=3u*C9_DIAGNOSTIC_HOP_RAW+1000u;c9_tasks_schedule();
 CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.end_sample==end-1000u&&
  c9_jobs_skipped==skipped+2u&&c9_pending_replaced==replaced+1u,"overloaded pending work is replaced by one latest aligned hop without a backlog");
 advance_supported(end,end+C9_DIAGNOSTIC_HOP_RAW);end+=C9_DIAGNOSTIC_HOP_RAW;
 uint32_t rejects=c9_tasks_shared.data.metrics.snapshot_rejected;c9_tasks_cpu1(&ipc);c9_tasks_receive();
 CHECK(c9_tasks_shared.data.metrics.snapshot_rejected==rejects+1u&&
  !c9_tasks_shared.data.results[c9_latest_slot].count,"queued input older than512ms still rejected independently of compute budget");
 c9_schedule.have=0;c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1,"fresh complete snapshot is eligible after rejection");
 uint32_t misses=c9_tasks_shared.data.metrics.deadline_misses;
 delayed_timer_reads=2;delayed_timer_ticks=1000000000u;c9_tasks_cpu1(&ipc);c9_tasks_receive();
 CHECK(c9_tasks_shared.data.metrics.deadline_misses==misses+1u&&
  c9_tasks_shared.data.results[c9_latest_slot].deadline_missed&&!c9_tasks_shared.data.results[c9_latest_slot].count,
  "worker beyond3s still withheld even with frozen input");
 CHECK(c9_tasks_shared.data.metrics.processing_us_max>=C9_DIAGNOSTIC_DEADLINE_US,"CPU1 deadline statistics retain the measured overrun");
 c9_tasks_shared.data.auxiliary.job.state=0;
 puts("SCHEDULER_PIPELINE_PASS hop_raw=80000 window_raw=160256 history_bytes=33554432 pending_latest_only=1 queued_and_compute_deadline_rejected=1");
}
static void auxiliary_feedback_tests(void){
 c9_tasks_init();c9_tracks=(c9_tracker){0};c9_aux_tracks=(c9_tracker){.next_id=0x40000000u};
 c9_schedule=(c9_diagnostic_schedule){0};c9_aux_have=0;c9_aux_received_have=0;c9_aux_last_tick=0;
 c9_shaft_confirmed=0;c9_shaft_waiting=0;c9_shaft_generation++;
 push_pcm(0,C9_SEARCH_RAW_FRAMES+4u);c9_tasks_schedule();
 CHECK(c9_tasks_shared.data.job.state==0&&c9_tasks_shared.data.auxiliary.job.state==1,"real multiband discovery is scheduled with no existing direction track");
 struct ipc_page ipc={0};c9_tasks_cpu1(&ipc);
 c9_aux_result *published=NULL;
 for(unsigned i=0;i<3;i++)if(c9_tasks_shared.data.auxiliary.results[i].state==2)published=&c9_tasks_shared.data.auxiliary.results[i];
 CHECK(published&&published->feedback.count>0&&published->feedback.analysis_frames>=3,"CPU1 publishes candidates supported by actual captured samples and FFTs");
 if(!published)return;
 c9_aux_result genuine=*published;c9_tasks_receive();
 CHECK(c9_aux_tracks.have&&c9_aux_tracks.tracks[0].id>=0x40000000u&&c9_aux_tracks.tracks[0].observations==1,"one genuine search result creates only one fresh auxiliary observation");
 uint32_t written=C9_SEARCH_RAW_FRAMES+4u;
 for(unsigned round=0;round<2;round++){
  push_pcm(written,written+C9_AUX_HOP_RAW);written+=C9_AUX_HOP_RAW;c9_tasks_schedule();c9_tasks_cpu1(&ipc);
  for(unsigned i=0;i<3;i++)if(c9_tasks_shared.data.auxiliary.results[i].state==2)genuine=c9_tasks_shared.data.auxiliary.results[i];
  c9_tasks_receive();
 }
 CHECK(c9_aux_tracks.tracks[0].observations==3&&c9_aux_tracks.tracks[0].state==C9_TRACK_OBSERVED,"three distinct real FFT windows qualify auxiliary freshness without pretending to cover a full diagnostic span");
 uint32_t observations=c9_aux_tracks.tracks[0].observations,rejected=c9_aux_rejected,replayed=c9_aux_replayed;
 for(unsigned mode=0;mode<7;mode++){
  c9_aux_result *copy=&c9_tasks_shared.data.auxiliary.results[0];*copy=genuine;copy->sequence+=100+mode;
  if(mode==1)copy->feedback.session++;
  if(mode==2)copy->feedback.epoch++;
  if(mode==3)copy->feedback.geometry_version++;
  if(mode==4)copy->generation--;
  if(mode==5){copy->feedback.end_sample-=40000;copy->feedback.first_sample-=40000;copy->feedback.valid_until_sample-=40000;}
  if(mode==6)copy->feedback.support_frames[0]=2;
  copy->state=2;c9_tasks_receive();
  CHECK(c9_aux_tracks.tracks[0].observations==observations,"duplicate wrong-session old-generation expired or short-burst feedback cannot refresh support");
 }
 CHECK(c9_aux_rejected==rejected+7&&c9_aux_replayed==replayed+1,"auxiliary freshness and provenance rejection counters retain every negative control");
 uint32_t end=0,count=0,epoch=0,session=0;const c9_track *merged[3];
 CHECK(c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session),"auxiliary merge reads current capture era");
 unsigned n=c9_collect_tracks(merged,end,epoch,session);
 CHECK(n>0&&merged[0]->id>=0x40000000u&&!c9_track_covers_range(merged[0],0,C9_SNAPSHOT_FRAMES),"a short search cannot masquerade as a complete1.024s diagnostic direction");
 c9_candidate same=merged[0]->candidate;uint32_t auxiliary_id=merged[0]->id;
 c9_tracks=(c9_tracker){.have=1,.epoch=epoch,.session=session};
 for(unsigned i=0;i<3;i++)c9_tracks.tracks[i]=(c9_track){.id=10+i,.state=C9_TRACK_COASTING,.last_sample=end-1000u,.candidate=scene[i]};
 n=c9_collect_tracks(merged,end,epoch,session);
 CHECK(n>0&&merged[0]->id==auxiliary_id&&merged[0]->state==C9_TRACK_OBSERVED,"three held main slots cannot block a genuine fresh auxiliary source or take over its ID");
 c9_tracks=(c9_tracker){0};
 for(unsigned i=0;i<3;i++)c9_tracks_update(&c9_tracks,&same,1,end-6250u+3125u*i,epoch,session);
 n=c9_collect_tracks(merged,end,epoch,session);
 /* Full coverage must beat a new duplicate regardless of origin namespace. */
 c9_track *aux=&c9_aux_tracks.tracks[0];
 aux->state=C9_TRACK_OBSERVED;aux->fresh_observations=3;aux->observations=30;
 aux->first_sample=end-C9_SNAPSHOT_FRAMES;aux->coverage_first=aux->first_sample;
 aux->last_sample=end;aux->gap_open=0;aux->gap_count=0;
 n=c9_collect_tracks(merged,end,epoch,session);
 CHECK(n>0&&merged[0]->id==auxiliary_id,"covered auxiliary direction beats a new primary duplicate without transferring ID");
 c9_track *main=&c9_tracks.tracks[0];
 main->state=C9_TRACK_OBSERVED;main->fresh_observations=3;main->observations=31;
 main->first_sample=end-C9_SNAPSHOT_FRAMES;main->coverage_first=main->first_sample;
 main->last_sample=end;main->gap_open=0;main->gap_count=0;
 n=c9_collect_tracks(merged,end,epoch,session);
 CHECK(n>0&&merged[0]->id==main->id,"equally covered primary can retain its own better observed identity");
 aux->candidate=scene[1];aux->grid=scene[1].grid;
 n=c9_collect_tracks(merged,end,epoch,session);
 CHECK(n>=2,"independent directions are not collapsed by collection priority");
 printf("AUXILIARY_PIPELINE_PASS actual_FFT_candidates=%u support_frames=%u replay_wrong_era_expired_rejected=7 no_track_bootstrap=1\n",genuine.feedback.count,genuine.feedback.support_frames[0]);
}
#ifndef C9_PIPELINE_NO_MAIN
int main(int argc,char **argv){tracking_tests();pipeline_tests(argc>1?argv[1]:"pipeline_candidates.json");overlap_and_overload_tests();auxiliary_feedback_tests();if(fail)return 1;puts("CIRCULAR9_PIPELINE_PASS");return 0;}

#endif
