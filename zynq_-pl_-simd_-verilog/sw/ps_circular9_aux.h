#ifndef PS_CIRCULAR9_AUX_H
#define PS_CIRCULAR9_AUX_H
/* Included by tasks after its shared structures. No FFT runs on CPU0. */
#define C9_AUX_HOP_RAW 8192u
/* 256 warmup + 52.4288ms, three complete overlapping STFT observations.
 * Keep the 200ms freshness bound; the old seven-observation job exceeded it. */
#define C9_AUX_WINDOW_RAW C9_SEARCH_MIN_RAW_FRAMES
static uint32_t c9_aux_last_tick,c9_aux_issued_end,c9_aux_issued_session,c9_aux_issued_epoch,c9_aux_issued_generation,c9_aux_have;
static uint32_t c9_aux_sequence,c9_aux_skipped,c9_aux_replaced,c9_aux_accepted,c9_aux_rejected,c9_aux_replayed,c9_aux_receive_us_max;
static uint32_t c9_aux_received_end,c9_aux_received_session,c9_aux_received_epoch,c9_aux_received_have;
static unsigned c9_collect_tracks(const c9_track *out[3],uint32_t end,uint32_t epoch,uint32_t session){
 unsigned n=0;
 /* Fresh observed sources come first (main before auxiliary), then recovery,
  * then held identities. A coasting main slot cannot hide genuine new FFT
  * evidence. IDs are never transferred or replaced by score/loudness. */
 const uint32_t states[3]={C9_TRACK_OBSERVED,C9_TRACK_RECOVERING,C9_TRACK_COASTING};
 for(unsigned priority=0;priority<3&&n<3;priority++)for(unsigned origin=0;origin<2&&n<3;origin++){
  const c9_tracker *tracker=origin?&c9_aux_tracks:&c9_tracks;
  if(!tracker->have||tracker->epoch!=epoch||tracker->session!=session)continue;
  for(unsigned i=0;i<3&&n<3;i++){
   const c9_track *t=&tracker->tracks[i];
   if(!t->id||t->state!=states[priority]||(uint32_t)(end-t->last_sample)>C9_SEARCH_MAX_AGE_SAMPLES)continue;
   unsigned duplicate=0;for(unsigned j=0;j<n;j++)if(c9_track_direction_dot(&t->candidate,&out[j]->candidate)>=.9781476007338057)duplicate=1;
   if(!duplicate)out[n++]=t;
  }
 }
 return n;
}
static void c9_aux_schedule(void){
 c9_aux_job *job=&c9_tasks_shared.data.auxiliary.job;
 uint32_t state=__atomic_load_n(&job->state,__ATOMIC_ACQUIRE);
 if(state!=0u&&state!=1u)return;
 uint32_t end=0,count=0,epoch=0,session=0;
 if(!c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)||count<C9_AUX_WINDOW_RAW+3u)return;
 end&=~3u;uint32_t selected=end,steps=1;
 if(c9_aux_have&&session==c9_aux_issued_session&&epoch==c9_aux_issued_epoch&&c9_shaft_generation==c9_aux_issued_generation){
  uint32_t advance=end-c9_aux_issued_end;
  if(advance>=0x80000000u||advance<C9_AUX_HOP_RAW)return;
  steps=advance/C9_AUX_HOP_RAW;selected=c9_aux_issued_end+steps*C9_AUX_HOP_RAW;
 }
 uint32_t expected=state;
 if(!__atomic_compare_exchange_n(&job->state,&expected,3u,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE))return;
 if(state==1u)c9_aux_replaced++;
 c9_aux_skipped+=steps-1u;job->sequence=++c9_aux_sequence;job->end_sample=selected;
 job->session=session;job->epoch=epoch;job->generation=c9_shaft_generation;
 c9_aux_have=1;c9_aux_issued_end=selected;c9_aux_issued_session=session;c9_aux_issued_epoch=epoch;c9_aux_issued_generation=c9_shaft_generation;
 __atomic_store_n(&job->state,1u,__ATOMIC_RELEASE);
}
static int c9_aux_feedback_current(const c9_aux_result *result,uint32_t end,uint32_t epoch,uint32_t session){
 const c9_search_feedback *f=&result->feedback;
 if(f->abi!=C9_SEARCH_FEEDBACK_ABI||f->count>3||f->invalid_input||
    result->generation!=c9_shaft_generation||f->session!=session||f->epoch!=epoch||
    f->geometry_version!=ACOUSTIC_GEOMETRY_VERSION||f->calibration_version!=ACOUSTIC_CALIBRATION_VERSION||
    f->geometry_confirmed!=ACOUSTIC_GEOMETRY_CONFIRMED||
    (uint32_t)(f->end_sample-f->first_sample)!=C9_AUX_WINDOW_RAW||
    f->valid_until_sample!=f->end_sample+C9_SEARCH_MAX_AGE_SAMPLES||
    (uint32_t)(end-f->end_sample)>C9_SEARCH_MAX_AGE_SAMPLES||
    f->analysis_frames<3||f->analysis_frames>8||(f->band_valid_mask&~7u)||(!f->band_valid_mask&&f->count))return 0;
 for(unsigned i=0;i<f->count;i++){
  unsigned bits=0;for(unsigned k=0;k<8;k++)bits+=(f->support_mask[i]>>k)&1u;
  if(f->candidates[i].grid>=1024||f->candidates[i].score<=0||(f->candidates[i].flags&~C9_CANDIDATE_REFINED)||
     !f->band_mask[i]||(f->band_mask[i]&~f->band_valid_mask)||
     !f->quality_permille[i]||f->quality_permille[i]>1000||f->support_frames[i]<3||f->support_frames[i]>bits||
     (f->support_mask[i]>>f->analysis_frames)||(int32_t)(f->support_first_sample[i]-(f->first_sample+256u))<0||
     (int32_t)(f->support_end_sample[i]-f->support_first_sample[i])<=0||
     (int32_t)(f->end_sample-f->support_end_sample[i])<0||
     (uint32_t)(end-f->support_end_sample[i])>C9_SEARCH_MAX_AGE_SAMPLES)return 0;
 }
 return 1;
}
static void c9_aux_receive(void){
 for(unsigned pass=0;pass<3;pass++){
  c9_aux_result *chosen=NULL;
  for(unsigned i=0;i<3;i++){
   c9_aux_result *r=&c9_tasks_shared.data.auxiliary.results[i];
   if(__atomic_load_n(&r->state,__ATOMIC_ACQUIRE)==2u&&(!chosen||(int32_t)(r->sequence-chosen->sequence)<0))chosen=r;
  }
  if(!chosen)break;
  uint32_t start=dia_gtimer_now(),end=0,count=0,epoch=0,session=0;
  c9_realtime_checkpoint();
  int valid=c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)&&c9_aux_feedback_current(chosen,end,epoch,session);
  const c9_search_feedback *f=&chosen->feedback;
  if(valid&&c9_aux_received_have&&f->session==c9_aux_received_session&&f->epoch==c9_aux_received_epoch&&
     (int32_t)(f->end_sample-c9_aux_received_end)<=0){valid=0;c9_aux_replayed++;}
  if(valid){
   c9_tracks_update_intervals(&c9_aux_tracks,f->candidates,f->count,f->support_first_sample,f->support_end_sample,f->end_sample,f->epoch,f->session);
   c9_aux_received_have=1;c9_aux_received_end=f->end_sample;c9_aux_received_session=f->session;c9_aux_received_epoch=f->epoch;
   c9_aux_last_tick=dia_gtimer_now();c9_aux_accepted++;
  }else c9_aux_rejected++;
  __atomic_store_n(&chosen->state,0u,__ATOMIC_RELEASE);
  c9_realtime_checkpoint();uint32_t duration=c9_ticks_to_us(dia_gtimer_now()-start);
  if(duration>c9_aux_receive_us_max)c9_aux_receive_us_max=duration;
 }
}
static int c9_aux_cpu1(volatile struct ipc_page *ipc){
 c9_aux_memory *memory=&c9_tasks_shared.data.auxiliary;c9_aux_job job;
 uint32_t expected=1u;
 if(!__atomic_compare_exchange_n(&memory->job.state,&expected,2u,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE))return 0;
 memcpy(&job,&memory->job,sizeof(job));c9_metric_increment(&memory->started);ipc->busy=1;
 /* Coalesce delayed work to the newest requested window. Do not replay up
  * to three expensive old searches, which makes the newest result stale. */
 uint32_t first_end=job.end_sample;
 for(uint32_t selected=first_end;;selected+=C9_AUX_HOP_RAW){
  c9_aux_result *result=NULL;
  for(unsigned i=0;i<3;i++)if(__atomic_load_n(&memory->results[i].state,__ATOMIC_ACQUIRE)==0u){result=&memory->results[i];break;}
  if(!result){c9_metric_increment(&memory->no_output);break;}
  __atomic_store_n(&result->state,1u,__ATOMIC_RELEASE);
  uint32_t t0=dia_gtimer_now(),first=0,epoch=0,session=0;
  int valid=c9_history_copy(&c9_history_shared.history,c9_snapshot,C9_AUX_WINDOW_RAW,selected,&first,&epoch,&session)&&epoch==job.epoch&&session==job.session;
  c9_search_context context={.session=session,.epoch=epoch,.first_sample=first,.end_sample=selected,
   .geometry_version=ACOUSTIC_GEOMETRY_VERSION,.calibration_version=ACOUSTIC_CALIBRATION_VERSION,.geometry_confirmed=ACOUSTIC_GEOMETRY_CONFIRMED};
  __atomic_store_n(&memory->copy_us,c9_ticks_to_us(dia_gtimer_now()-t0),__ATOMIC_RELEASE);
  memset(&result->feedback,0,sizeof(result->feedback));
  if(valid)valid=c9_candidates_search(c9_snapshot,C9_AUX_WINDOW_RAW,acoustic_steer_lut,&c9_separator,&context,&result->feedback)>0;
  __atomic_store_n(&memory->decimator_vector_status,c9_candidates_acceleration(),__ATOMIC_RELEASE);
  __atomic_store_n(&memory->prepare_us,c9_ticks_to_us(c9_separator.search_ticks[0]),__ATOMIC_RELEASE);
  __atomic_store_n(&memory->observations_us,c9_ticks_to_us(c9_separator.search_ticks[1]),__ATOMIC_RELEASE);
  __atomic_store_n(&memory->search_us,c9_ticks_to_us(c9_separator.search_ticks[2]),__ATOMIC_RELEASE);
  uint32_t end=0,count=0,current_epoch=0,current_session=0;
  result->processing_us=c9_ticks_to_us(dia_gtimer_now()-t0);
  c9_metric_max(&memory->processing_us_max,result->processing_us);
  if(!c9_history_info(&c9_history_shared.history,&end,&count,&current_epoch,&current_session)||
     current_epoch!=job.epoch||current_session!=job.session||(uint32_t)(end-selected)>C9_SEARCH_MAX_AGE_SAMPLES||result->processing_us>200000u){valid=0;c9_metric_increment(&memory->late);}
  if(valid){
   result->sequence=job.sequence*4u+(selected-first_end)/C9_AUX_HOP_RAW;result->generation=job.generation;
   __atomic_store_n(&result->state,2u,__ATOMIC_RELEASE);c9_metric_increment(&memory->completed);

  }else{c9_metric_increment(&memory->rejected);__atomic_store_n(&result->state,0u,__ATOMIC_RELEASE);}
  if(selected==job.end_sample)break;
 }
 ipc->busy=0;__atomic_store_n(&memory->job.state,0u,__ATOMIC_RELEASE);return 1;
}
#endif
