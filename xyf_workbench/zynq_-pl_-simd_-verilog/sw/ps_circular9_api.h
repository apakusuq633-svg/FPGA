#ifndef PS_CIRCULAR9_API_H
#define PS_CIRCULAR9_API_H
#include "circular9_http_args.h"
static int c9_candidates_json(char *out,size_t cap){
 const c9_diag_model *model=c9_diag_configured_model();
 const c9_diagnostic_result *r=c9_latest_slot<0?NULL:&c9_tasks_shared.data.results[c9_latest_slot];
 int n=snprintf(out,cap,"{\"fstf_experiment_enabled\":%u,\"ps_search_mode\":\"PS_JOINT_FORMAL\",\"pl_candidates_enabled\":true,\"scan_model\":\"far_field_direction\",\"direction_convention\":\"azimuth=atan2(x,z),elevation=asin(y);front=0,right/up=positive\","
  "\"geometry_confirmed\":%u,\"calibration_version\":%u,\"model_version\":%u,\"model_validated\":%u,"
  "\"shaft_millihz\":%u,\"shaft_confirmed\":%u,\"target_mode\":\"%s\",\"sequence\":%u,\"result_age_ms\":%u,"
  "\"snapshot_session\":%u,\"snapshot_epoch\":%u,\"snapshot_first_sample\":%u,\"processing_ms\":%u,"
  "\"diagnostic_window_ms\":1024,\"diagnostic_core\":1,\"jobs_started\":%u,\"map_retries\":%u,\"map_copies\":%u,\"map_copy_max_us\":%u,"
  "\"sample_rate_num\":78125,\"sample_rate_den\":2,\"separation_contract\":%u,\"feature_contract\":%u,"
  "\"candidate_map_period_ms\":20,\"proposal_updates\":%u,\"proposal_supported\":%u,\"proposal_rejected\":%u,\"candidate_service_max_us\":%u,\"candidate_service_over_100us\":%u,\"candidates\":[",
  c9_fstf_experiment_enabled(),ACOUSTIC_GEOMETRY_CONFIRMED,ACOUSTIC_CALIBRATION_VERSION,(unsigned)model->version,(unsigned)model->validated,
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
   "\"label\":\"%s\",\"provisional_label\":\"%s\",\"reason\":\"%s\",\"fault_direction_valid\":%u,\"clipped_samples\":%u,\"fstf_experimental\":{\"enabled\":%u,\"available\":%u,\"class_id\":%u,\"label\":\"%s\",\"version\":%u,\"validated\":0,\"distance\":%.10g,\"margin\":%.10g},\"features\":[",
   i?",":"",(unsigned)b->track_id,(unsigned)b->grid,(int)b->azimuth_mdeg,(int)b->elevation_mdeg,
   !!(b->flags&C9_DIAG_BIND_STABLE),!current,!!(r->separation.ready_mask&(1u<<i)),
   (unsigned)b->track_id,(unsigned)b->grid,(unsigned)b->epoch,(unsigned)b->first_sample,(unsigned)b->sample_count,
   (unsigned)b->flags,(int)b->azimuth_mdeg,(int)b->elevation_mdeg,
   (unsigned)d->feature_contract,(unsigned)d->model_version,(unsigned)d->model_kind,(unsigned)d->model_validated,
   d->shaft_hz,d->rms,c9_diag_label_name(current?d->label:C9_DIAG_UNKNOWN),
   c9_diag_label_name(d->provisional_label),c9_diag_reason_name(d->reason),current&&d->fault_direction_valid,(unsigned)d->clipped_samples,
   c9_fstf_experiment_enabled(),d->fstf_available,d->fstf_class,c9_fstf_class_name(d->fstf_available?d->fstf_class:6u),d->fstf_version,d->fstf_distance,d->fstf_margin);
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
 n=ui_append(out,(int)cap,n,",\"snapshot_debug\":{\"revision\":\"snapshot-stage7-independent-20261026\",\"now_sample\":%u,\"aux_interval_raw\":%u,\"aux_interval_max_raw\":%u,\"aux_age_raw\":%u,\"aux_age_max_raw\":%u,\"last_reject_track\":%u,\"last_reject_reason\":%u,\"reasons\":[",end,c9_aux_interval_raw,c9_aux_interval_max_raw,c9_aux_age_raw,c9_aux_age_max_raw,c9_schedule_last_reject_track,c9_schedule_last_reject_reason);
 for(unsigned k=0;k<8;k++)n=ui_append(out,(int)cap,n,"%s%u",k?",":"",c9_schedule_reasons[k]);
 n=ui_append(out,(int)cap,n,"],\"tracks\":[");
 for(unsigned i=0;i<merged_count;i++){
  const c9_track *t=merged[i];uint32_t missing=0,tail=0;
  uint32_t why=c9_track_coverage_reason(t,end-C9_SNAPSHOT_FRAMES,end,&missing,&tail);
  n=ui_append(out,(int)cap,n,"%s{\"id\":%u,\"state\":%u,\"observations\":%u,\"fresh\":%u,\"first\":%u,\"coverage_first\":%u,\"last\":%u,\"gap_count\":%u,\"gap_open\":%u,\"missing_raw\":%u,\"tail_raw\":%u,\"reason\":%u}",i?",":"",t->id,t->state,t->observations,t->fresh_observations,t->first_sample,t->coverage_first,t->last_sample,t->gap_count,t->gap_open,missing,tail,why);
 }
 n=ui_append(out,(int)cap,n,"]}");
 n=ui_append(out,(int)cap,n,",\"diagnostic_eligibility\":{\"nonobserved_skipped\":%u,\"ineligible_skipped\":%u,\"unresolved_directions\":%u}",c9_schedule_nonobserved_skipped,c9_schedule_ineligible_skipped,r?r->unresolved_tracks:0u);
 const c9_cpu1_metrics *metrics=&c9_tasks_shared.data.metrics;
 n=ui_append(out,(int)cap,n,",\"diagnostic_scheduler\":{\"hop_raw_samples\":%u,\"hop_ms\":512,\"deadline_ms\":3000,\"result_age_limit_ms\":3000,\"latest_only\":true,"
  "\"history_frames\":%u,\"history_bytes\":%u,\"skipped_hops\":%u,\"pending_replaced\":%u,\"coverage_rejected\":%u,"
  "\"cpu1_started\":%u,\"cpu1_completed\":%u,\"deadline_misses\":%u,\"snapshot_rejected\":%u,\"worker_coverage_rejected\":%u,\"no_output_slot\":%u,"
  "\"processing_us_max\":%u,\"queue_wait_us_max\":%u,\"total_elapsed_us_max\":%u,\"queue_age_samples_max\":%u,\"result_age_samples_max\":%u,"
  "\"last_processing_us\":%u,\"last_queue_age_samples\":%u,\"last_result_age_samples\":%u,\"last_deadline_missed\":%u,\"last_rejection\":%u},"
  "\"auxiliary_search\":{\"feedback_abi\":%u,\"support_semantics\":\"actual_stft_window_union\",\"hop_raw_samples\":%u,\"window_raw_samples\":%u,\"max_age_raw_samples\":%u,\"no_CPU0_FFT\":true,"
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
  (unsigned)C9_SEARCH_FEEDBACK_ABI,(unsigned)C9_AUX_HOP_RAW,(unsigned)C9_AUX_WINDOW_RAW,(unsigned)C9_SEARCH_MAX_AGE_SAMPLES,
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
static int c9_trace_json(char *out,size_t cap,int n,const c9_trace_track views[3]){
 unsigned emitted=0;for(unsigned i=0;i<3;i++)if(views[i].id){const c9_trace_track *v=&views[i];
 n=ui_append(out,(int)cap,n,"%s{\"id\":%u,\"state\":%u,\"observations\":%u,\"last_sample\":%u,\"az\":%d,\"el\":%d}",emitted++?",":"",v->id,v->state,v->observations,v->last_sample,v->az,v->el);}
 return n;
}
static int c9_aux_evidence_json(char *out,size_t cap,int n,const c9_aux_result *v){
 const c9_search_debug *d=&v->debug;
 n=ui_append(out,(int)cap,n,"{\"origin\":\"PS_AUX\",\"stage\":\"cpu0_accepted\",\"sequence\":%u,\"session\":%u,\"epoch\":%u,\"first\":%u,\"end\":%u,\"analysis_frames\":%u,\"band_valid_mask\":%u,\"peaks_after_nms\":[",v->sequence,d->session,d->epoch,d->first,d->end,v->feedback.analysis_frames,v->feedback.band_valid_mask);
 unsigned emitted=0;
 for(unsigned i=0;i<9;i++)if(d->count&(1u<<i)){
  const c9_debug_peak *p=&d->peaks[i];
  n=ui_append(out,(int)cap,n,"%s{\"index\":%u,\"band\":%u,\"grid\":%u,\"az\":%d,\"el\":%d,\"score\":%d,\"quality\":%u,\"shoulder\":%d,\"checks\":%u,\"cross_checked\":%u,\"direct_mask\":%u,\"residual_mask\":%u,\"combined_mask\":%u,\"residual_peer\":%u,\"selected_slot_plus_one\":%u,\"band_score\":[%d,%d,%d],\"band_quality\":[%u,%u,%u],\"band_support\":[%u,%u,%u]}",emitted++?",":"",i,p->band,p->grid,p->az,p->el,p->score,p->quality,p->shoulder,p->checks,p->cross_checked,p->direct_mask,p->residual_mask,p->combined_mask,p->peer,p->selected,p->band_score[0],p->band_score[1],p->band_score[2],p->band_quality[0],p->band_quality[1],p->band_quality[2],p->band_support[0],p->band_support[1],p->band_support[2]);
 }
 n=ui_append(out,(int)cap,n,"],\"band_peak_semantics\":\"pre_joint_intermediate_not_joint_peaks\",\"joint_raw_peaks\":[");
 for(unsigned i=0;i<d->joint_raw_count;i++){const c9_candidate *p=&d->joint_raw[i];n=ui_append(out,(int)cap,n,"%s{\"local_index\":%u,\"grid\":%u,\"az\":%d,\"el\":%d,\"score\":%d,\"quality\":%u,\"shoulder\":%d}",i?",":"",i,p->grid,p->azimuth_mdeg,p->elevation_mdeg,p->score,d->joint_quality[i],d->joint_shoulder[i]);}
 n=ui_append(out,(int)cap,n,"],\"raw_peak_scope\":\"top3_after_existing_nms_not_all_local_maxima\",\"peak12_gap_available\":%s,\"peak12_score_gap\":%lld,\"formal_feedback\":{\"count\":%u,\"candidates\":[",d->joint_raw_count>=2?"true":"false",d->joint_raw_count>=2?(long long)d->joint_raw[0].score-d->joint_raw[1].score:0ll,v->feedback.count);
 for(unsigned i=0;i<v->feedback.count;i++){const c9_candidate *p=&v->feedback.candidates[i];n=ui_append(out,(int)cap,n,"%s{\"index\":%u,\"local_peak_index\":%u,\"az\":%d,\"el\":%d,\"grid\":%u,\"score\":%d,\"quality\":%u,\"bands\":%u,\"support_mask\":%u,\"support_first\":%u,\"support_end\":%u}",i?",":"",i,d->joint_selected_raw[i],p->azimuth_mdeg,p->elevation_mdeg,p->grid,p->score,v->feedback.quality_permille[i],v->feedback.band_mask[i],v->feedback.support_mask[i],v->feedback.support_first_sample[i],v->feedback.support_end_sample[i]);}
 n=ui_append(out,(int)cap,n,"]},\"tracking_trace_valid\":%u,\"tracks_before\":[",d->tracking_trace_valid);n=c9_trace_json(out,cap,n,d->before);
 n=ui_append(out,(int)cap,n,"],\"tracks_after\":[");n=c9_trace_json(out,cap,n,d->after);
 return ui_append(out,(int)cap,n,"]}");
}

/* Debug response is CPU0-owned latest evidence, never a physical-source claim. */
static int c9_evidence_json(char *out,size_t cap){
 int n=snprintf(out,cap,"{\"revision\":2,\"semantics\":\"latest_only_not_all_windows\",\"geometry_version\":%u,\"primary\":{\"origin\":\"PL_MAIN_MAP\",\"sequence\":%u,\"first\":%u,\"end\":%u,\"reason\":%u,\"session\":%u,\"epoch\":%u,\"tracker_input\":[",(unsigned)ACOUSTIC_GEOMETRY_VERSION,(unsigned)c9_debug_primary.sequence,(unsigned)c9_debug_primary.first,(unsigned)c9_debug_primary.end,(unsigned)c9_debug_primary.reason,(unsigned)c9_debug_primary.session,(unsigned)c9_debug_primary.epoch);
 for(unsigned i=0;i<c9_debug_primary.count;i++){
  c9_candidate *p=&c9_debug_primary.peaks[i];int32_t a,e;c9_candidate_angles(p,&a,&e);
  n=ui_append(out,(int)cap,n,"%s{\"index\":%u,\"grid\":%u,\"az\":%d,\"el\":%d,\"score\":%d}",i?",":"",i,p->grid,a,e,p->score);
 }
 n=ui_append(out,(int)cap,n,"]},\"auxiliary\":");
 n=c9_aux_evidence_json(out,cap,n,&c9_debug_aux);
 n=ui_append(out,(int)cap,n,",\"tracks_before_merge\":[");unsigned emitted=0;
 for(unsigned origin=0;origin<2;origin++){
  const c9_tracker *tr=origin?&c9_aux_tracks:&c9_tracks;
  for(unsigned i=0;i<3;i++){
   const c9_observation_ref *ref=&c9_debug_refs[origin][i];
   const c9_track *p=&tr->tracks[i];if(!p->id)continue;int32_t a,e;c9_candidate_angles(&p->candidate,&a,&e);
   n=ui_append(out,(int)cap,n,"%s{\"origin\":\"%s\",\"id\":%u,\"state\":%u,\"observations\":%u,\"source_key_known\":%u,\"source_sequence\":%u,\"source_first\":%u,\"source_end\":%u,\"source_output_index\":%u,\"last_observation_sample\":%u,\"last_sample_kind\":\"%s\",\"session\":%u,\"epoch\":%u,\"az\":%d,\"el\":%d}",emitted++?",":"",origin?"PS_AUX":"PL_MAIN_MAP",p->id,p->state,p->observations,ref->known,ref->sequence,ref->first,ref->end,ref->peak,p->last_sample,origin?"support_end":"window_first",tr->session,tr->epoch,a,e);
  }
 }
 uint32_t end=0,available=0,epoch=0,session=0;const c9_track *merged[3];unsigned mc=0;
 if(c9_history_info(&c9_history_shared.history,&end,&available,&epoch,&session))mc=c9_collect_tracks(merged,end,epoch,session);
 n=ui_append(out,(int)cap,n,"],\"merged_ids\":[");
 for(unsigned i=0;i<mc;i++)n=ui_append(out,(int)cap,n,"%s%u",i?",":"",merged[i]->id);
 const c9_diagnostic_result *z=c9_latest_slot<0?NULL:&c9_tasks_shared.data.results[c9_latest_slot];
 n=ui_append(out,(int)cap,n,"],\"diagnostic_sequence\":%u,\"diagnostic_bindings\":[",z?z->sequence:0);
 if(z)for(unsigned i=0;i<z->count;i++){const c9_diag_binding *b=&z->diagnosis[i].binding;n=ui_append(out,(int)cap,n,"%s{\"id\":%u,\"first\":%u,\"az\":%d,\"el\":%d}",i?",":"",b->track_id,b->first_sample,b->azimuth_mdeg,b->elevation_mdeg);}
 n=ui_append(out,(int)cap,n,"],\"job_created\":{\"sequence\":%u,\"session\":%u,\"epoch\":%u,\"end\":%u,\"queued_tick\":%u,\"count\":%u,\"tracks\":[",c9_debug_created_job.sequence,c9_debug_created_job.session,c9_debug_created_job.epoch,c9_debug_created_job.end,c9_debug_created_job.queued_tick,c9_debug_created_job.count);
 n=c9_trace_json(out,cap,n,c9_debug_created_job.tracks);
 n=ui_append(out,(int)cap,n,"],\"source_keys\":[");
 for(unsigned i=0;i<c9_debug_created_job.count;i++){const c9_observation_ref *r=&c9_debug_created_job.refs[i];unsigned o=c9_debug_created_job.origins[i];n=ui_append(out,(int)cap,n,"%s{\"id\":%u,\"known\":%u,\"origin\":\"%s\",\"source_sequence\":%u,\"first\":%u,\"end\":%u,\"output_index\":%u}",i?",":"",c9_debug_created_job.tracks[i].id,r->known,o==1?"PS_AUX":o==0?"PL_MAIN_MAP":"UNKNOWN",r->sequence,r->first,r->end,r->peak);}
 n=ui_append(out,(int)cap,n,"]},\"diagnostic_timing\":{\"sequence\":%u,\"session\":%u,\"epoch\":%u,\"queued_tick\":%u,\"started_tick\":%u,\"finished_tick\":%u,\"started_sample\":%u,\"finished_sample\":%u,\"tick_unit\":\"GTIMER32_ticks_modulo_wrap\"}",z?z->sequence:0,z?z->session:0,z?z->epoch:0,z?z->queued_tick:0,z?z->started_tick:0,z?z->finished_tick:0,z?z->started_sample:0,z?z->finished_sample:0);
 return ui_append(out,(int)cap,n,",\"evidence_build_id\":\"%s\",\"json_timing\":{\"previous_us\":%u,\"max_us\":%u,\"calls\":%u}}",C9_EVIDENCE_BUILD_ID,c9_debug_json_last_us,c9_debug_json_max_us,c9_debug_json_calls);
}

/* CPU0 serializes CPU0-owned rings; no scheduler re-entry. */
static int c9_source_events_json(const char *p,char *out,size_t cap){
 unsigned origin;uint32_t after=0,limit=0;
 if(!strncmp(p,"PS_AUX&after=",13)){origin=1;p+=13;}
 else if(!strncmp(p,"PL_MAIN_MAP&after=",18)){origin=0;p+=18;}else return -2;
 if(!c9_source_uint(&p,UINT32_MAX,&after)||strncmp(p,"&limit=",7))return -2;
 p+=7;
 if(!c9_source_uint(&p,origin?4u:32u,&limit)||!limit||*p!=' ')return -2;
 uint32_t writes=origin?c9_source_aux.writes:c9_source_pl.writes;
 uint32_t capacity=origin?C9_SOURCE_AUX_CAP:C9_SOURCE_PL_CAP;
 uint32_t oldest=writes>capacity?writes-capacity:0;
 if(after>writes)return -2;
 uint32_t lost=after<oldest?oldest-after:0,cursor=after<oldest?oldest:after;
 int n=snprintf(out,cap,"{\"evidence_build_id\":\"%s\",\"geometry_version\":%u,\"origin\":\"%s\",\"writes\":%u,\"capacity\":%u,\"lost_before_cursor\":%u,\"events\":[",C9_EVIDENCE_BUILD_ID,(unsigned)ACOUSTIC_GEOMETRY_VERSION,origin?"PS_AUX":"PL_MAIN_MAP",(unsigned)writes,(unsigned)capacity,(unsigned)lost);
 unsigned emitted=0;
 while(cursor<writes&&emitted<limit){
  if(emitted++)n=ui_append(out,(int)cap,n,",");
  if(origin)n=c9_aux_evidence_json(out,cap,n,&c9_source_aux.events[cursor%C9_SOURCE_AUX_CAP]);
  else{
   const c9_source_primary *v=&c9_source_pl.events[cursor%C9_SOURCE_PL_CAP];
   n=ui_append(out,(int)cap,n,"{\"origin\":\"PL_MAIN_MAP\",\"sequence\":%u,\"session\":%u,\"epoch\":%u,\"first\":%u,\"end\":%u,\"reason\":%u,\"tracker_input\":[",v->sequence,v->session,v->epoch,v->first,v->end,v->reason);
   for(unsigned i=0;i<v->count;i++){int32_t az,el;c9_candidate_angles(&v->peaks[i],&az,&el);
    n=ui_append(out,(int)cap,n,"%s{\"az\":%d,\"el\":%d,\"grid\":%u,\"score\":%d}",i?",":"",az,el,v->peaks[i].grid,v->peaks[i].score);}
   n=ui_append(out,(int)cap,n,"]}");
  }
  cursor++;
 }
 return ui_append(out,(int)cap,n,"],\"next_after\":%u,\"more\":%s}",cursor,cursor<writes?"true":"false");
}

static int c9_source_events_request(const char *request,char *body,size_t cap){
 const char *prefix="GET /api/candidates?events=";
 if(strncmp(request,prefix,strlen(prefix)))return -3;
 return c9_source_events_json(request+strlen(prefix),body,cap);
}

static int c9_joint_json(char *out,size_t cap){
#if !C9_JOINT_SHADOW
 return snprintf(out,cap,"{\"source\":\"PS_JOINT_SHADOW\",\"enabled\":false}");
#else
 const c9_joint_slot *v=&c9_joint_latest;const c9_joint_report *r=&v->report;c9_joint_mailbox *m=&c9_tasks_shared.data.auxiliary.joint;
 uint32_t end=0,count=0,ep=0,se=0;int have=c9_history_info(&c9_history_shared.history,&end,&count,&ep,&se);
 int n=snprintf(out,cap,"{\"source\":\"PS_JOINT_SHADOW\",\"enabled\":true,\"have\":%u,\"evidence_build_id\":\"%s\",\"geometry_version\":%u,\"session\":%u,\"epoch\":%u,\"sequence\":%u,\"first\":%u,\"end\":%u,\"era_matches\":%s,\"age_samples\":%u,\"status\":%u,\"budget_us\":%u,\"total_us\":%u,\"formal_us\":%u,\"shadow_pipeline_us\":%u,\"combined_us\":%u,\"score_us\":%u,\"peak_us\":%u,\"support_us\":%u,\"band_mask\":%u,\"raw_peaks\":%u,\"produced\":%u,\"received\":%u,\"no_slot\":%u,\"budget_skipped\":%u,\"total_us_max\":%u,\"original\":{\"origin\":\"PS_AUX\",\"session\":%u,\"epoch\":%u,\"sequence\":%u,\"first\":%u,\"end\":%u,\"candidates\":[",(unsigned)(v->state!=0),C9_EVIDENCE_BUILD_ID,(unsigned)ACOUSTIC_GEOMETRY_VERSION,(unsigned)v->session,(unsigned)v->epoch,(unsigned)v->sequence,(unsigned)v->first,(unsigned)v->end,have&&ep==v->epoch&&se==v->session?"true":"false",(unsigned)(end-v->end),(unsigned)r->status,(unsigned)r->budget_us,(unsigned)r->total_us,(unsigned)v->formal_us,(unsigned)v->shadow_pipeline_us,(unsigned)(v->formal_us+v->shadow_pipeline_us),(unsigned)r->score_us,(unsigned)r->peak_us,(unsigned)r->support_us,(unsigned)r->band_mask,(unsigned)r->raw_peaks,(unsigned)__atomic_load_n(&m->produced,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&m->received,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&m->no_slot,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&m->budget_skipped,__ATOMIC_ACQUIRE),(unsigned)__atomic_load_n(&m->total_us_max,__ATOMIC_ACQUIRE),(unsigned)v->session,(unsigned)v->epoch,(unsigned)v->sequence,(unsigned)v->first,(unsigned)v->end);
 for(unsigned i=0;i<v->original.count;i++){const c9_candidate *p=&v->original.candidates[i];n=ui_append(out,(int)cap,n,"%s{\"grid\":%u,\"az\":%d,\"el\":%d,\"quality\":%u,\"bands\":%u}",i?",":"",p->grid,p->azimuth_mdeg,p->elevation_mdeg,v->original.quality_permille[i],v->original.band_mask[i]);}
 n=ui_append(out,(int)cap,n,"]},\"candidates\":[");
 for(unsigned i=0;i<r->count;i++){const c9_candidate *p=&r->candidates[i];n=ui_append(out,(int)cap,n,"%s{\"grid\":%u,\"az\":%d,\"el\":%d,\"score\":%d,\"shoulder\":%d,\"quality\":%u,\"support_bands\":%u,\"support_mask\":%u,\"unit_direction_q30\":[%d,%d,%d]}",i?",":"",p->grid,p->azimuth_mdeg,p->elevation_mdeg,p->score,r->shoulder[i],r->quality[i],r->support_band_mask[i],r->support_mask[i],r->direction_q30[i][0],r->direction_q30[i][1],r->direction_q30[i][2]);}
 return ui_append(out,(int)cap,n,"]}");
#endif
}

#include "ps_joint_score_api.h"
static int c9_tasks_route(const char *request,struct ui_reply *rep,char *body,size_t cap){
 if(c9_joint_panel_route(request,rep,body,cap))return 1;
 if(c9_control_route(request,rep,body,cap))return 1;
 if(!strncmp(request,"GET /api/candidates?joint_shadow=1 ",sizeof("GET /api/candidates?joint_shadow=1 ")-1)){
  uint32_t t=dia_gtimer_now();int len=c9_joint_json(body,cap);c9_debug_json_last_us=c9_ticks_to_us(dia_gtimer_now()-t);c9_debug_json_calls++;if(c9_debug_json_last_us>c9_debug_json_max_us)c9_debug_json_max_us=c9_debug_json_last_us;
  *rep=(struct ui_reply){len<0||(size_t)len>=cap?500:200,len<0||(size_t)len>=cap?"Internal Server Error":"OK","application/json",len<0||(size_t)len>=cap?0:len};return 1;
 }

 if(!strncmp(request,"GET /api/candidates?events=",sizeof("GET /api/candidates?events=")-1)){
  uint32_t t0=dia_gtimer_now();int len=c9_source_events_request(request,body,cap);
  c9_debug_json_last_us=c9_ticks_to_us(dia_gtimer_now()-t0);c9_debug_json_calls++;
  if(c9_debug_json_last_us>c9_debug_json_max_us)c9_debug_json_max_us=c9_debug_json_last_us;
  *rep=(struct ui_reply){len<0?400:200,len<0?"Bad Request":"OK","application/json",len<0?0:len};return 1;
 }

 if(strncmp(request,"GET /api/candidates?debug=1 ",sizeof("GET /api/candidates?debug=1 ")-1)==0){
  uint32_t t0=dia_gtimer_now();int len=c9_evidence_json(body,cap);
  c9_debug_json_last_us=c9_ticks_to_us(dia_gtimer_now()-t0);c9_debug_json_calls++;
  if(c9_debug_json_last_us>c9_debug_json_max_us)c9_debug_json_max_us=c9_debug_json_last_us;
  *rep=(struct ui_reply){len<0||(size_t)len>=cap?500:200,len<0||(size_t)len>=cap?"Internal Server Error":"OK","application/json",len<0||(size_t)len>=cap?0:len};return 1;
 }
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
   c9_shaft_default=0;c9_shaft_millihz=(rpm*1000u+30u)/60u;c9_shaft_confirmed=1;
   *rep=(struct ui_reply){200,"OK","application/json",snprintf(body,cap,"{\"rpm\":%u,\"shaft_millihz\":%u,\"source\":\"operator_confirmed\"}",(unsigned)rpm,(unsigned)c9_shaft_millihz)};
  }else *rep=(struct ui_reply){400,"Bad Request","application/json",snprintf(body,cap,"{\"error\":\"rpm_must_be_600_to_1800\"}")};
  return 1;
 }
 if(strncmp(request,"GET /api/target/fault ",22)==0){
  das_bus b=das_axi_bus(RV32_BASE);c9_gsc_manual_ready=0;c9_target_fault_mode=1;c9_fault_track=0;c9_fault_grid=UINT32_MAX;
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
