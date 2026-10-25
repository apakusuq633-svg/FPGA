/* Bare-metal AMP bridge: CPU0 captures/maps; CPU1 separates then diagnoses.
 * Shared sections have one uncached mapping on BOTH cores. Bulk work never
 * runs in an HTTP callback or in the DMA/audio service. */
#ifndef PS_CIRCULAR9_TASKS_H
#define PS_CIRCULAR9_TASKS_H
#include "circular9_tracking.h"
#include "circular9_diagnosis.h"
#include "circular9_proposals.h"
#include "circular9_schedule.h"
#include "xil_cache.h"
static void c9_realtime_checkpoint(void);
static int c9_apply_target(const das_bus*,const c9_candidate*,uint32_t);
static void c9_release_target(const das_bus*);
static int c9_control_route(const char*,struct ui_reply*,char*,size_t);
typedef struct {
 uint32_t state,sequence,count,epoch,session,map_sample,shaft_millihz,shaft_confirmed,shaft_generation,end_sample,queued_tick;
 c9_track tracks[3];
} c9_diagnostic_job;
typedef struct {
 uint32_t state,sequence,count,epoch,session,first_sample,processing_ms,shaft_generation;
 uint32_t processing_us,queue_wait_us,total_elapsed_us,queue_age_samples,result_age_samples,deadline_missed,rejection;
 c9_separation_report separation;
 c9_diag_report diagnosis[3];
 uint16_t gui_envelope[3][128];uint32_t gui_envelope_valid[3];
 int16_t audio[3][C9_AUDIO_FRAMES];
} c9_diagnostic_result;
typedef struct {
 uint32_t started,completed,deadline_misses,snapshot_rejected,coverage_rejected,no_output;
 uint32_t processing_us_max,queue_wait_us_max,total_elapsed_us_max,queue_age_samples_max,result_age_samples_max;
} c9_cpu1_metrics;
typedef struct {uint32_t state,sequence,end_sample,session,epoch,generation;} c9_aux_job;
typedef struct {uint32_t state,sequence,generation,processing_us;c9_search_feedback feedback;} c9_aux_result;
typedef struct {
 c9_aux_job job;c9_aux_result results[3];
 uint32_t started,completed,rejected,late,no_output,processing_us_max;
} c9_aux_memory;
typedef struct {c9_diagnostic_job job;c9_diagnostic_result results[2];c9_cpu1_metrics metrics;c9_aux_memory auxiliary;} c9_task_memory;
static union {c9_history history;uint8_t section[33554432];} c9_history_shared
 __attribute__((section(".c9_history"),aligned(1048576)));
static union {c9_task_memory data;uint8_t section[1048576];} c9_tasks_shared
 __attribute__((section(".c9_tasks"),aligned(1048576)));
_Static_assert(sizeof(c9_history)<=33554432,"history shared section overflow");
_Static_assert(sizeof(c9_task_memory)<=1048576,"task shared section overflow");
static c9_tracker c9_tracks;
static c9_tracker c9_aux_tracks;
static c9_proposal_map c9_proposals;
static uint32_t c9_job_sequence,c9_jobs_started,c9_map_retries;
static uint32_t c9_map_copies,c9_map_max_us,c9_tracks_last_tick,c9_tracks_last_sequence;
static uint32_t c9_candidate_service_max_us,c9_candidate_service_overruns;
static uint32_t c9_latest_tick,c9_latest_sequence;
static c9_diagnostic_schedule c9_schedule;
static uint32_t c9_jobs_skipped,c9_pending_replaced,c9_schedule_coverage_rejected;
static int c9_latest_slot=-1;
static uint32_t c9_shaft_millihz=UI_SHAFT_MILLIHZ,c9_shaft_confirmed;
static uint32_t c9_shaft_generation=1,c9_shaft_first_sample;
static uint32_t c9_shaft_session,c9_shaft_epoch,c9_shaft_waiting;
static unsigned c9_target_fault_mode=1;
static uint32_t c9_fault_track,c9_fault_grid=UINT32_MAX;
/* These arrays belong only to CPU1 and remain cached. */
static int16_t c9_snapshot[C9_SNAPSHOT_FRAMES][9];
static c9_separation_workspace c9_separator;
static double c9_separated[3][C9_AUDIO_FRAMES];
static void c9_metric_increment(uint32_t *value){__atomic_fetch_add(value,1u,__ATOMIC_RELAXED);}
static void c9_metric_max(uint32_t *value,uint32_t observed){
 if(observed>__atomic_load_n(value,__ATOMIC_RELAXED))__atomic_store_n(value,observed,__ATOMIC_RELAXED);
}
#include "ps_circular9_aux.h"
static void c9_record_sample(const uint32_t packet[16]){c9_history_push(&c9_history_shared.history,packet);}
static void c9_record_reset(void){c9_history_reset(&c9_history_shared.history);}
static void c9_record_info(uint32_t info[4]){c9_history_info(&c9_history_shared.history,&info[0],&info[1],&info[2],&info[3]);}
static void c9_tasks_init(void){
 Xil_DCacheFlushRange((INTPTR)&c9_history_shared,sizeof(c9_history_shared));
 Xil_DCacheFlushRange((INTPTR)&c9_tasks_shared,sizeof(c9_tasks_shared));
 for(unsigned off=0;off<sizeof(c9_history_shared);off+=1048576)
  Xil_SetTlbAttributes((INTPTR)&c9_history_shared+off,NORM_NONCACHE);
 Xil_SetTlbAttributes((INTPTR)&c9_tasks_shared,NORM_NONCACHE);
 c9_history_init(&c9_history_shared.history);
 memset(&c9_tasks_shared.data,0,sizeof(c9_tasks_shared.data));
 c9_aux_tracks.next_id=0x40000000u;
}
/* Atomic result ownership pins audio until CPU0 adopts a newer result. */
static void c9_tasks_receive(void){
 c9_aux_receive();
 for(unsigned i=0;i<2;i++){
  c9_diagnostic_result *r=&c9_tasks_shared.data.results[i];
  if(__atomic_load_n(&r->state,__ATOMIC_ACQUIRE)!=2u)continue;
  if((int32_t)(r->sequence-c9_latest_sequence)<=0){__atomic_store_n(&r->state,0u,__ATOMIC_RELEASE);continue;}
  if(c9_latest_slot>=0)__atomic_store_n(&c9_tasks_shared.data.results[c9_latest_slot].state,0u,__ATOMIC_RELEASE);
  c9_latest_slot=(int)i;c9_latest_sequence=r->sequence;c9_latest_tick=dia_gtimer_now();
  __atomic_store_n(&r->state,3u,__ATOMIC_RELEASE);
 }
}
static int c9_result_current(const c9_diag_report *d,uint32_t session,uint32_t generation){
 uint32_t end,count,epoch,current_session;
 c9_candidate diagnosed={.grid=d->binding.grid,.score=1,.azimuth_mdeg=d->binding.azimuth_mdeg,
  .elevation_mdeg=d->binding.elevation_mdeg,.flags=C9_CANDIDATE_REFINED};
 uint32_t now=dia_gtimer_now();
 if(((!c9_tracks_last_tick||(uint32_t)(now-c9_tracks_last_tick)>66666666u)&&
     (!c9_aux_last_tick||(uint32_t)(now-c9_aux_last_tick)>66666666u))||
    generation!=c9_shaft_generation||!c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&current_session)||
    session!=current_session||epoch!=d->binding.epoch||!count||
    (uint32_t)(end-d->binding.first_sample)>C9_HISTORY_FRAMES||
    (uint32_t)(end-(d->binding.first_sample+C9_SNAPSHOT_FRAMES))>C9_DIAGNOSTIC_HOP_RAW)return 0;
 const c9_track *tracks[3];unsigned n=c9_collect_tracks(tracks,end,epoch,current_session);
 for(unsigned i=0;i<n;i++){
  const c9_track *t=tracks[i];
  if(t->id==d->binding.track_id&&c9_track_covers_range(t,d->binding.first_sample,d->binding.first_sample+C9_SNAPSHOT_FRAMES)&&
     (uint32_t)(end-t->last_sample)<=31250u&&
     c9_track_direction_dot(&t->candidate,&diagnosed)>=.9914448613738104)return 1;
 }
 return 0;
}
/* CPU1 sole caller. A bounded owned snapshot feeds ALL candidate outputs. */
static void c9_tasks_cpu1(volatile struct ipc_page *ipc){
 static unsigned auxiliary_burst;
 if((auxiliary_burst<2u||__atomic_load_n(&c9_tasks_shared.data.job.state,__ATOMIC_ACQUIRE)!=1u)&&c9_aux_cpu1(ipc)){if(auxiliary_burst<2u)auxiliary_burst++;return;}
 auxiliary_burst=0;
 c9_diagnostic_job *shared=&c9_tasks_shared.data.job,job;
 uint32_t expected=1u;
 if(!__atomic_compare_exchange_n(&shared->state,&expected,2u,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE))return;
 memcpy(&job,shared,sizeof(job));
 c9_cpu1_metrics *metrics=&c9_tasks_shared.data.metrics;c9_metric_increment(&metrics->started);
 int slot=-1;
 for(unsigned i=0;i<2;i++)if(__atomic_load_n(&c9_tasks_shared.data.results[i].state,__ATOMIC_ACQUIRE)==0u){slot=(int)i;break;}
 if(slot<0){c9_metric_increment(&metrics->no_output);__atomic_store_n(&shared->state,0u,__ATOMIC_RELEASE);return;}
 c9_diagnostic_result *r=&c9_tasks_shared.data.results[slot];
 __atomic_store_n(&r->state,1u,__ATOMIC_RELEASE);
 uint32_t first=0,epoch=0,session=0,t0=dia_gtimer_now();
 r->queue_wait_us=c9_ticks_to_us(t0-job.queued_tick);
 ipc->busy=1u;
 uint32_t end_before=0,available=0,now_epoch=0,now_session=0;
 int info=c9_history_info(&c9_history_shared.history,&end_before,&available,&now_epoch,&now_session);
 r->queue_age_samples=info?end_before-job.end_sample:UINT32_MAX;
 int valid=info&&r->queue_age_samples<C9_DIAGNOSTIC_HOP_RAW&&r->queue_wait_us<C9_DIAGNOSTIC_DEADLINE_US&&
  c9_history_snapshot_at(&c9_history_shared.history,c9_snapshot,job.end_sample,&first,&epoch,&session);
 if(!valid)c9_metric_increment(&metrics->snapshot_rejected);
 valid=valid&&epoch==job.epoch&&session==job.session&&
  (uint32_t)(first+C9_SNAPSHOT_FRAMES-job.map_sample)<=31250u;
 c9_candidate candidates[3];
 for(unsigned i=0;i<job.count;i++){
  candidates[i]=c9_track_candidate(&job.tracks[i]);
  if(!c9_track_covers_range(&job.tracks[i],first,first+C9_SNAPSHOT_FRAMES)){valid=0;c9_metric_increment(&metrics->coverage_rejected);}
 }
 memset(&r->separation,0,sizeof(r->separation));
 r->sequence=job.sequence;r->epoch=epoch;r->session=session;r->first_sample=first;r->count=0;
 r->deadline_missed=0;r->rejection=valid?0u:1u;
 r->shaft_generation=job.shaft_generation;
 if(valid&&c9_candidates_separate(c9_snapshot,candidates,job.count,acoustic_steer_lut,
                                 &c9_separator,c9_separated,&r->separation)>0){
  r->count=job.count;
  for(unsigned i=0;i<job.count;i++){
   c9_diag_binding binding={0};
   binding.track_id=job.tracks[i].id;binding.grid=job.tracks[i].grid;binding.epoch=epoch;
   binding.first_sample=first;binding.sample_count=C9_AUDIO_FRAMES;
   binding.separation_contract=C9_DIAG_SEPARATION_CONTRACT;
   memcpy(binding.usable_mask,r->separation.usable_mask,sizeof(binding.usable_mask));
   c9_candidate_angles(&candidates[i],&binding.azimuth_mdeg,&binding.elevation_mdeg);
   binding.flags=C9_DIAG_BIND_SNAPSHOT|C9_DIAG_BIND_STABLE;
   if(ACOUSTIC_GEOMETRY_CONFIRMED&&ACOUSTIC_CALIBRATION_VERSION)binding.flags|=C9_DIAG_BIND_DIRECTION;
   if(r->separation.ready_mask&(1u<<i))binding.flags|=C9_DIAG_BIND_SEPARATED;
   /* Without a confirmed RPM the input contract is incomplete. Keep audio
    * export available, but never infer a bearing fault from a guessed speed. */
   if(binding.flags&C9_DIAG_BIND_SEPARATED)
    c9_diagnose(c9_separated[i],job.shaft_confirmed?job.shaft_millihz/1000.0:0.0,&binding,&r->diagnosis[i]);
   else {
    memset(&r->diagnosis[i],0,sizeof(r->diagnosis[i]));r->diagnosis[i].binding=binding;
    r->diagnosis[i].feature_contract=C9_DIAG_FEATURE_CONTRACT;r->diagnosis[i].reason=C9_DIAG_BAD_BINDING;
    r->diagnosis[i].shaft_hz=job.shaft_confirmed?job.shaft_millihz/1000.0:0.0;
   }
   r->gui_envelope_valid[i]=r->diagnosis[i].extraction.fft_count==1u;
   if(r->gui_envelope_valid[i])c9_diag_export_envelope(r->gui_envelope[i]);
   else memset(r->gui_envelope[i],0,sizeof(r->gui_envelope[i]));
   for(unsigned n=0;n<C9_AUDIO_FRAMES;n++){
    double v=c9_separated[i][n]*32768.0;
    r->audio[i][n]=v>=32767?32767:v<=-32768?-32768:(int16_t)v;
   }
  }
 }
 uint32_t finished_tick=dia_gtimer_now();
 r->processing_us=c9_ticks_to_us(finished_tick-t0);r->processing_ms=r->processing_us/1000u;
 r->total_elapsed_us=c9_ticks_to_us(finished_tick-job.queued_tick);
 uint32_t end_after=0;
 info=c9_history_info(&c9_history_shared.history,&end_after,&available,&now_epoch,&now_session);
 r->result_age_samples=info?end_after-job.end_sample:UINT32_MAX;
 r->deadline_missed=!info||now_epoch!=job.epoch||now_session!=job.session||
  r->result_age_samples>=C9_DIAGNOSTIC_HOP_RAW||r->total_elapsed_us>=C9_DIAGNOSTIC_DEADLINE_US;
 if(r->deadline_missed){r->count=0;r->rejection=2u;c9_metric_increment(&metrics->deadline_misses);}
 c9_metric_max(&metrics->processing_us_max,r->processing_us);
 c9_metric_max(&metrics->queue_wait_us_max,r->queue_wait_us);
 c9_metric_max(&metrics->total_elapsed_us_max,r->total_elapsed_us);
 if(r->queue_age_samples!=UINT32_MAX)c9_metric_max(&metrics->queue_age_samples_max,r->queue_age_samples);
 if(r->result_age_samples!=UINT32_MAX)c9_metric_max(&metrics->result_age_samples_max,r->result_age_samples);
 c9_metric_increment(&metrics->completed);
 ipc->busy=0u;
 __atomic_store_n(&r->state,2u,__ATOMIC_RELEASE);
 __atomic_store_n(&shared->state,0u,__ATOMIC_RELEASE);
}
/* Incremental, protected map read. Restoring MMIO INDEX every slice lets the
 * location/audio service interleave safely. Changed seqlocks discard maps. */
static void c9_tasks_map_poll(const das_bus *b){
 static struct {uint32_t seq,ptr,frame,sample,reason,position,start,first_tick;int32_t scores[1024];} m;
 static uint32_t last;
 uint32_t now=dia_gtimer_now();
 if(c9_tracks_last_tick&&(uint32_t)(now-c9_tracks_last_tick)>66666666u){
  c9_tracks_reset(&c9_tracks);c9_proposals_reset(&c9_proposals);c9_tracks_last_tick=0;
 }
 if(!m.seq){
  if((uint32_t)(now-last)<6666666u)return; /* 20 ms slow evidence path; fast RV32 unchanged. */
  uint32_t seq=mic_read_word(b,90);if(!seq||(seq&1u))return;
  if(seq==c9_tracks_last_sequence)return;
  m.ptr=mic_read_word(b,235);m.frame=mic_read_word(b,1);
  m.sample=mic_read_word(b,93);m.reason=mic_read_word(b,97);
  m.first_tick=mic_read_word(b,239);
  if((m.ptr&3u)||m.ptr>0x2800u-sizeof(m.scores))return;
  m.seq=seq;m.position=0;m.start=now;
 }
 uint32_t slice_start=dia_gtimer_now();
 do {
  if(mic_read_word(b,90)!=m.seq){m.seq=0;c9_map_retries++;return;}
  b->write(b->ctx,0x80,0x80000000u+m.ptr/4u+m.position);
  for(unsigned k=0;k<32;k++)m.scores[m.position++]=(int32_t)b->read(b->ctx,0x88);
  c9_realtime_checkpoint();
  if(m.position==1024)break;
 }while(c9_ticks_to_us(dia_gtimer_now()-slice_start)<500u);
 if(m.position<1024)return;
 uint32_t seq=mic_read_word(b,90),end,count,epoch,session;
 if(seq!=m.seq||!c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)||
    (uint32_t)(end-m.sample)>31250u||
    (uint32_t)(b->read(b->ctx,0x3e0)-m.first_tick)>C9_STALE_AFTER_US*C9_PL_TICKS_PER_US){m.seq=0;c9_map_retries++;return;}
 uint32_t duration=c9_ticks_to_us(dia_gtimer_now()-m.start);if(duration>c9_map_max_us)c9_map_max_us=duration;
 c9_map_copies++;c9_tracks_last_sequence=m.seq;c9_tracks_last_tick=dia_gtimer_now();
 last=now;m.seq=0;
 c9_candidate candidates[3];unsigned n=0;
 uint32_t process_start=dia_gtimer_now();
 /* A second source is allowed: single-peak ambiguity/confirmation flags do
  * not invalidate a multi-source map. Silence, clipping and deadline do. */
 if(!(m.reason&(1u|2u|4u|64u)))n=c9_proposals_update(&c9_proposals,m.scores,m.sample,epoch,session,candidates);
 else c9_proposals_reset(&c9_proposals);
 c9_tracks_update(&c9_tracks,candidates,n,m.sample,epoch,session);
 uint32_t process_us=c9_ticks_to_us(dia_gtimer_now()-process_start);
 if(process_us>c9_candidate_service_max_us)c9_candidate_service_max_us=process_us;
 if(process_us>100u)c9_candidate_service_overruns++;
}
static void c9_tasks_schedule(void){
 c9_aux_schedule();
 c9_diagnostic_job *j=&c9_tasks_shared.data.job;
 uint32_t state=__atomic_load_n(&j->state,__ATOMIC_ACQUIRE);
 if(state!=0u&&state!=1u)return;
 uint32_t now=dia_gtimer_now(),end,count,epoch,session;
 if(!c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)||count<C9_SNAPSHOT_FRAMES+3)return;
 uint32_t selected=0,skipped=0;
 if(!c9_diagnostic_due(&c9_schedule,end,session,epoch,c9_shaft_generation,&selected,&skipped))return;
 if(c9_shaft_confirmed&&(session!=c9_shaft_session||epoch!=c9_shaft_epoch)){
  c9_shaft_confirmed=0;++c9_shaft_generation;c9_shaft_waiting=0;
 }
 if(c9_shaft_confirmed&&c9_shaft_waiting){
  if((int32_t)(selected-C9_SNAPSHOT_FRAMES-c9_shaft_first_sample)<0)return;
  c9_shaft_waiting=0;
 }
 if((!c9_tracks_last_tick||(uint32_t)(now-c9_tracks_last_tick)>66666666u)&&
    (!c9_aux_last_tick||(uint32_t)(now-c9_aux_last_tick)>66666666u))return;
 c9_track tracks[3];
 unsigned n=0;
 const c9_track *merged[3];unsigned merged_count=c9_collect_tracks(merged,end,epoch,session);
 for(unsigned i=0;i<merged_count;i++){
  const c9_track *t=merged[i];
  /* All existing sources participate in null constraints; a newly appearing
   * source waits for a full common stable window rather than being omitted. */
  if(!c9_track_covers_range(t,selected-C9_SNAPSHOT_FRAMES,selected)||
     (uint32_t)(end-t->last_sample)>31250u){c9_schedule_coverage_rejected++;return;}
  tracks[n++]=*t;
 }
 if(!n)return;
 uint32_t expected=state;
 if(!__atomic_compare_exchange_n(&j->state,&expected,3u,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE))return;
 if(state==1u)c9_pending_replaced++;
 memcpy(j->tracks,tracks,n*sizeof(tracks[0]));j->end_sample=selected;j->queued_tick=now;
 j->sequence=++c9_job_sequence;j->count=n;j->epoch=epoch;j->session=session;
 j->map_sample=j->tracks[0].last_sample;j->shaft_millihz=c9_shaft_millihz;j->shaft_confirmed=c9_shaft_confirmed;
 j->shaft_generation=c9_shaft_generation;
 c9_diagnostic_issued(&c9_schedule,selected,session,epoch,c9_shaft_generation);
 c9_jobs_skipped+=skipped;c9_jobs_started++;
 __atomic_store_n(&j->state,1u,__ATOMIC_RELEASE);
}
static void c9_tasks_select_fault(const das_bus *b){
 if(!c9_target_fault_mode)return;
 unsigned matches=0;const c9_diag_report *chosen=NULL;
 if(c9_latest_slot>=0){
  const c9_diagnostic_result *r=&c9_tasks_shared.data.results[c9_latest_slot];
  for(unsigned i=0;i<r->count;i++){
   const c9_diag_report *d=&r->diagnosis[i];
   if(d->fault_direction_valid&&c9_result_current(d,r->session,r->shaft_generation)&&
      d->shaft_hz==c9_shaft_millihz/1000.0&&c9_shaft_confirmed){chosen=d;matches++;}
  }
 }
 if(matches==1u){
  uint32_t end=0,count=0,epoch=0,session=0;const c9_track *merged[3];unsigned n=0;
  unsigned found=0;
  if(c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session))n=c9_collect_tracks(merged,end,epoch,session);
  for(unsigned i=0;i<n;i++)if(merged[i]->id==chosen->binding.track_id){
   found=1;
   c9_candidate current=c9_track_candidate(merged[i]);
   if(c9_apply_target(b,&current,chosen->binding.epoch)){
    c9_fault_track=chosen->binding.track_id;c9_fault_grid=current.grid;
   }else{c9_release_target(b);c9_fault_track=0;c9_fault_grid=UINT32_MAX;}
   break;
  }
  if(!found){c9_release_target(b);c9_fault_track=0;c9_fault_grid=UINT32_MAX;}
 }else {
  /* Withhold target on expiry/ambiguity. RV32 still publishes all scores. */
  c9_release_target(b);c9_fault_track=0;c9_fault_grid=UINT32_MAX;
 }
}
#endif
