#ifndef PS_CIRCULAR9_API_H
#define PS_CIRCULAR9_API_H
#include "circular9_http_args.h"
static int c9_candidates_json(char *out,size_t cap){
 const c9_diag_model *model=c9_diag_configured_model();
 const c9_diagnostic_result *r=c9_latest_slot<0?NULL:&c9_tasks_shared.data.results[c9_latest_slot];
 int n=snprintf(out,cap,"{\"scan_model\":\"far_field_direction\",\"direction_convention\":\"azimuth=atan2(x,z),elevation=asin(y);front=0,right/up=positive\","
  "\"geometry_confirmed\":%u,\"calibration_version\":%u,\"model_version\":%u,\"model_validated\":%u,"
  "\"shaft_millihz\":%u,\"shaft_confirmed\":%u,\"target_mode\":\"%s\",\"sequence\":%u,\"result_age_ms\":%u,"
  "\"snapshot_session\":%u,\"snapshot_epoch\":%u,\"snapshot_first_sample\":%u,\"processing_ms\":%u,"
  "\"diagnostic_window_ms\":1024,\"diagnostic_core\":1,\"jobs_started\":%u,\"map_retries\":%u,\"map_copies\":%u,\"map_copy_max_us\":%u,"
  "\"sample_rate_num\":78125,\"sample_rate_den\":2,\"separation_contract\":%u,\"feature_contract\":%u,"
  "\"candidate_map_period_ms\":20,\"proposal_updates\":%u,\"proposal_supported\":%u,\"proposal_rejected\":%u,\"candidate_service_max_us\":%u,\"candidate_service_over_100us\":%u,\"candidates\":[",
  ACOUSTIC_GEOMETRY_CONFIRMED,ACOUSTIC_CALIBRATION_VERSION,(unsigned)model->version,(unsigned)model->validated,
  (unsigned)c9_shaft_millihz,(unsigned)c9_shaft_confirmed,c9_target_fault_mode?"fault":"manual_or_strongest",
  r?(unsigned)r->sequence:0,r?(unsigned)dia_ticks_to_ms(dia_gtimer_now()-c9_latest_tick):0,
  r?(unsigned)r->session:0,r?(unsigned)r->epoch:0,r?(unsigned)r->first_sample:0,r?(unsigned)r->processing_ms:0,
  (unsigned)c9_jobs_started,(unsigned)c9_map_retries,(unsigned)c9_map_copies,(unsigned)c9_map_max_us,(unsigned)C9_DIAG_SEPARATION_CONTRACT,
  (unsigned)C9_DIAG_FEATURE_CONTRACT,(unsigned)c9_proposals.updates,(unsigned)c9_proposals.supported,(unsigned)c9_proposals.rejected,
  (unsigned)c9_candidate_service_max_us,(unsigned)c9_candidate_service_overruns);
 if(r)for(unsigned i=0;i<r->count;i++){
  const c9_diag_report *d=&r->diagnosis[i];const c9_diag_binding *b=&d->binding;
  int current=c9_result_current(d,r->session,r->shaft_generation)&&c9_shaft_confirmed&&d->shaft_hz==c9_shaft_millihz/1000.0;
  n=ui_append(out,(int)cap,n,"%s{\"track_id\":%u,\"grid\":%u,\"azimuth_mdeg\":%d,\"elevation_mdeg\":%d,"
   "\"stable\":%u,\"stale\":%u,\"separation_ready\":%u,\"diagnosis\":{"
   "\"binding\":{\"track_id\":%u,\"grid\":%u,\"epoch\":%u,\"first_sample\":%u,\"sample_count\":%u,\"flags\":%u,\"azimuth_mdeg\":%d,\"elevation_mdeg\":%d},"
   "\"feature_contract\":%u,\"model_version\":%u,\"model_kind\":%u,\"model_validated\":%u,\"shaft_hz\":%.8g,\"rms\":%.10g,"
   "\"label\":\"%s\",\"provisional_label\":\"%s\",\"reason\":\"%s\",\"fault_direction_valid\":%u,\"clipped_samples\":%u,\"features\":[",
   i?",":"",(unsigned)b->track_id,(unsigned)b->grid,(int)b->azimuth_mdeg,(int)b->elevation_mdeg,
   !!(b->flags&C9_DIAG_BIND_STABLE),!current,!!(r->separation.ready_mask&(1u<<i)),
   (unsigned)b->track_id,(unsigned)b->grid,(unsigned)b->epoch,(unsigned)b->first_sample,(unsigned)b->sample_count,
   (unsigned)b->flags,(int)b->azimuth_mdeg,(int)b->elevation_mdeg,
   (unsigned)d->feature_contract,(unsigned)d->model_version,(unsigned)d->model_kind,(unsigned)d->model_validated,
   d->shaft_hz,d->rms,c9_diag_label_name(current?d->label:C9_DIAG_UNKNOWN),
   c9_diag_label_name(d->provisional_label),c9_diag_reason_name(d->reason),current&&d->fault_direction_valid,(unsigned)d->clipped_samples);
  for(unsigned j=0;j<C9_DIAG_FEATURES;j++){
   n=ui_append(out,(int)cap,n,"%s%.17g",j?",":"",d->features[j]);
   if((j&3u)==3u)c9_realtime_checkpoint();
  }
  n=ui_append(out,(int)cap,n,"],\"distance\":[%.10g,%.10g,%.10g],\"margin\":%.10g,\"extraction\":{"
   "\"status\":%u,\"envelope_samples\":%u,\"fft_size\":%u,\"fft_count\":%u,\"fir_multiplications\":%u,"
   "\"observation_seconds\":%.9g,\"envelope_rate_hz\":%.9g,\"bin_spacing_hz\":%.9g,\"hann_enbw_hz\":%.9g,\"hann_first_null_hz\":%.9g,",
   d->distance[0],d->distance[1],d->distance[2],d->margin,
   (unsigned)d->extraction.status,(unsigned)d->extraction.envelope_samples,(unsigned)d->extraction.fft_size,
   (unsigned)d->extraction.fft_count,(unsigned)d->extraction.fir_multiplications,
   d->extraction.observation_seconds,d->extraction.envelope_rate_hz,d->extraction.bin_spacing_hz,d->extraction.hann_enbw_hz,d->extraction.hann_first_null_hz);
  c9_realtime_checkpoint();
  n=ui_append(out,(int)cap,n,"\"carrier_rms\":%.9g,\"modulation_rms\":%.9g,\"carrier_low_hz\":%.9g,\"carrier_high_hz\":%.9g,\"carrier_transition_guard_hz\":%.9g,\"envelope_lowpass_hz\":%.9g}}}",
   d->extraction.carrier_rms,d->extraction.modulation_rms,d->extraction.carrier_low_hz,d->extraction.carrier_high_hz,d->extraction.carrier_transition_guard_hz,d->extraction.envelope_lowpass_hz);
  c9_realtime_checkpoint();
 }
 n=ui_append(out,(int)cap,n,"],\"proposals\":[");
 uint32_t end=0,available=0,epoch=0,session=0;const c9_track *merged[3];unsigned merged_count=0;
 if(c9_history_info(&c9_history_shared.history,&end,&available,&epoch,&session))merged_count=c9_collect_tracks(merged,end,epoch,session);
 for(unsigned i=0;i<merged_count;i++){
  const c9_track *t=merged[i];int32_t az=0,el=0;c9_candidate candidate=c9_track_candidate(t);c9_candidate_angles(&candidate,&az,&el);
  n=ui_append(out,(int)cap,n,"%s{\"track_id\":%u,\"grid\":%u,\"score\":%d,\"azimuth_mdeg\":%d,\"elevation_mdeg\":%d,\"observations\":%u,\"track_state\":%u,\"confidence_q15\":%u,\"angle_refined\":%u,\"uncertainty_mdeg\":%u}",
    i?",":"",(unsigned)t->id,(unsigned)t->grid,(int)t->score,(int)az,(int)el,(unsigned)t->observations,
    (unsigned)t->state,(unsigned)t->confidence_q15,!!(candidate.flags&C9_CANDIDATE_REFINED),(unsigned)candidate.uncertainty_mdeg);
 }
 if(r){n=ui_append(out,(int)cap,n,"],\"separation\":{\"ready_mask\":%u,\"usable_bins\":%u,\"total_bins\":%u,\"invalid_input\":%u,\"target_error\":%.10g,\"max_null_leakage\":%.10g,\"max_weight_norm\":%.10g,"
  "\"carrier_bins\":%u,\"carrier_usable_bins\":%u,\"carrier_max_gap\":%u,\"min_sector_gain\":%.9g,\"max_sector_gain\":%.9g,\"max_sector_leakage\":%.9g,\"usable_mask\":[",
  (unsigned)r->separation.ready_mask,(unsigned)r->separation.usable_bins,(unsigned)r->separation.total_bins,
  (unsigned)r->separation.invalid_input,r->separation.target_error,r->separation.max_null_leakage,r->separation.max_weight_norm,
  (unsigned)r->separation.carrier_bins,(unsigned)r->separation.carrier_usable_bins,(unsigned)r->separation.carrier_max_gap,
  r->separation.min_sector_gain,r->separation.max_sector_gain,r->separation.max_sector_leakage);
  for(unsigned i=0;i<7;i++)n=ui_append(out,(int)cap,n,"%s%u",i?",":"",(unsigned)r->separation.usable_mask[i]);
  n=ui_append(out,(int)cap,n,"]}");
 }
 else n=ui_append(out,(int)cap,n,"]");
 const c9_cpu1_metrics *metrics=&c9_tasks_shared.data.metrics;
 n=ui_append(out,(int)cap,n,",\"diagnostic_scheduler\":{\"hop_raw_samples\":%u,\"hop_ms\":512,\"latest_only\":true,"
  "\"history_frames\":%u,\"history_bytes\":%u,\"skipped_hops\":%u,\"pending_replaced\":%u,\"coverage_rejected\":%u,"
  "\"cpu1_started\":%u,\"cpu1_completed\":%u,\"deadline_misses\":%u,\"snapshot_rejected\":%u,\"worker_coverage_rejected\":%u,\"no_output_slot\":%u,"
  "\"processing_us_max\":%u,\"queue_wait_us_max\":%u,\"total_elapsed_us_max\":%u,\"queue_age_samples_max\":%u,\"result_age_samples_max\":%u,"
  "\"last_processing_us\":%u,\"last_queue_age_samples\":%u,\"last_result_age_samples\":%u,\"last_deadline_missed\":%u,\"last_rejection\":%u},"
  "\"auxiliary_search\":{\"hop_raw_samples\":%u,\"window_raw_samples\":%u,\"max_age_raw_samples\":%u,\"no_CPU0_FFT\":true,"
  "\"accepted\":%u,\"rejected\":%u,\"replayed\":%u,\"skipped_hops\":%u,\"pending_replaced\":%u,\"receive_us_max\":%u,"
  "\"cpu1_started\":%u,\"cpu1_completed\":%u,\"cpu1_rejected\":%u,\"cpu1_late\":%u,\"cpu1_processing_us_max\":%u,\"copy_us\":%u,\"prepare_us\":%u,\"observations_us\":%u,\"search_us\":%u,\"decimator_vector_status\":%u}}",
  (unsigned)C9_DIAGNOSTIC_HOP_RAW,(unsigned)C9_HISTORY_FRAMES,(unsigned)sizeof(c9_history_shared),
  (unsigned)c9_jobs_skipped,(unsigned)c9_pending_replaced,(unsigned)c9_schedule_coverage_rejected,
  (unsigned)__atomic_load_n(&metrics->started,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&metrics->completed,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&metrics->deadline_misses,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&metrics->snapshot_rejected,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&metrics->coverage_rejected,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&metrics->no_output,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&metrics->processing_us_max,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&metrics->queue_wait_us_max,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&metrics->total_elapsed_us_max,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&metrics->queue_age_samples_max,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&metrics->result_age_samples_max,__ATOMIC_ACQUIRE),r?(unsigned)r->processing_us:0,
  r?(unsigned)r->queue_age_samples:0,r?(unsigned)r->result_age_samples:0,r?(unsigned)r->deadline_missed:0,r?(unsigned)r->rejection:0,
  (unsigned)C9_AUX_HOP_RAW,(unsigned)C9_AUX_WINDOW_RAW,(unsigned)C9_SEARCH_MAX_AGE_SAMPLES,
  (unsigned)c9_aux_accepted,(unsigned)c9_aux_rejected,(unsigned)c9_aux_replayed,(unsigned)c9_aux_skipped,(unsigned)c9_aux_replaced,(unsigned)c9_aux_receive_us_max,
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.started,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.completed,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.rejected,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.late,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.processing_us_max,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.copy_us,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.prepare_us,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.observations_us,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.search_us,__ATOMIC_ACQUIRE),
  (unsigned)__atomic_load_n(&c9_tasks_shared.data.auxiliary.decimator_vector_status,__ATOMIC_ACQUIRE));
 return n;
}
static int c9_tasks_route(const char *request,struct ui_reply *rep,char *body,size_t cap){
 if(c9_control_route(request,rep,body,cap))return 1;
 if(strncmp(request,"GET /api/candidates ",20)==0){
  int len=c9_candidates_json(body,cap);
  if(len<0||(size_t)len>=cap)*rep=(struct ui_reply){500,"Internal Server Error","application/json",0};
  else *rep=(struct ui_reply){200,"OK","application/json",len};
  return 1;
 }
 if(strncmp(request,"GET /api/rpm?value=",19)==0){
  uint32_t rpm=0;
  if(c9_http_decimal(request+19,600,1800,&rpm)){
   uint32_t end=0,count=0;
   if(!c9_history_info(&c9_history_shared.history,&end,&count,&c9_shaft_epoch,&c9_shaft_session)||!count){
    *rep=(struct ui_reply){409,"Conflict","application/json",snprintf(body,cap,"{\"error\":\"wait_for_live_capture_before_rpm_confirmation\"}")};return 1;
   }
   c9_shaft_first_sample=end;++c9_shaft_generation;c9_schedule.have=0;c9_shaft_waiting=1;
   c9_shaft_millihz=(rpm*1000u+30u)/60u;c9_shaft_confirmed=1;
   *rep=(struct ui_reply){200,"OK","application/json",snprintf(body,cap,"{\"rpm\":%u,\"shaft_millihz\":%u,\"source\":\"operator_confirmed\"}",(unsigned)rpm,(unsigned)c9_shaft_millihz)};
  }else *rep=(struct ui_reply){400,"Bad Request","application/json",snprintf(body,cap,"{\"error\":\"rpm_must_be_600_to_1800\"}")};
  return 1;
 }
 if(strncmp(request,"GET /api/target/fault ",22)==0){
  das_bus b=das_axi_bus(RV32_BASE);c9_target_fault_mode=1;c9_fault_track=0;c9_fault_grid=UINT32_MAX;
  c9_release_target(&b);
  *rep=(struct ui_reply){202,"Accepted","application/json",snprintf(body,cap,"{\"mode\":\"fault\",\"state\":\"waiting_for_validated_fault_direction\"}")};return 1;
 }
 if(strncmp(request,"GET /api/candidate/audio?",25)==0){
  unsigned sequence,index,offset,count;char tail;
  int valid=sscanf(request,"GET /api/candidate/audio?sequence=%u&index=%u&offset=%u&count=%u%c",&sequence,&index,&offset,&count,&tail)==5&&tail==' '&&count>0&&count<=512u&&offset<=C9_AUDIO_FRAMES&&count<=C9_AUDIO_FRAMES-offset&&2u*count<=cap;
  const c9_diagnostic_result *r=c9_latest_slot<0?NULL:&c9_tasks_shared.data.results[c9_latest_slot];
  if(!valid)*rep=(struct ui_reply){400,"Bad Request","application/json",snprintf(body,cap,"{\"error\":\"invalid_audio_range\"}")};
  else if(!r||r->sequence!=sequence||index>=r->count)*rep=(struct ui_reply){409,"Conflict","application/json",snprintf(body,cap,"{\"error\":\"snapshot_expired_or_missing\"}")};
  else {
   for(unsigned i=0;i<count;i++){uint16_t v=(uint16_t)r->audio[index][offset+i];body[2*i]=(char)v;body[2*i+1]=(char)(v>>8);}
   *rep=(struct ui_reply){200,"OK","application/octet-stream",(int)(2u*count)};
  }
  return 1;
 }
 return 0;
}
#endif
