/* Real task/search/track/separate/diagnose/API code, with named host-only
 * clock/cache/MMIO fixtures. PCM is synthetic propagation of FSTF recordings. */
#define C9_PIPELINE_NO_MAIN
#include "circular9_pipeline_test.c"
#include <assert.h>
void c9_debug_peak_support(c9_separation_workspace *,const c9_candidate *,const uint32_t *,unsigned,unsigned[3]);
int main(int argc,char **argv){
 if(argc<4||argc>5)return 2;unsigned total=(unsigned)strtoul(argv[2],0,10);
 int16_t (*pcm)[9]=malloc((size_t)total*sizeof(*pcm));assert(pcm);
 FILE *f=fopen(argv[1],"rb");assert(f&&fread(pcm,sizeof(*pcm),total,f)==total);fclose(f);
 c9_tasks_init();c9_tracks=(c9_tracker){0};c9_aux_tracks=(c9_tracker){.next_id=0x40000000u};
 c9_schedule=(c9_diagnostic_schedule){0};c9_latest_slot=-1;c9_shaft_confirmed=1;c9_shaft_millihz=30000;
 const char *replay_rpm=getenv("C9_REPLAY_SHAFT_MILLIHZ");if(replay_rpm){c9_shaft_millihz=(uint32_t)strtoul(replay_rpm,0,10);c9_shaft_confirmed=c9_shaft_millihz>=10000u&&c9_shaft_millihz<=30000u;}
 char tracepath[1024];snprintf(tracepath,sizeof(tracepath),"%s.trace.jsonl",argv[3]);FILE *trace=fopen(tracepath,"wb");assert(trace);
 unsigned searches=0,written=0;uint32_t end=0,available=0,epoch=0,session=0;struct ipc_page ipc={0};
 for(unsigned finish=C9_SEARCH_RAW_FRAMES;finish<=total;finish+=8192u){
  for(unsigned n=written;n<finish;n++){
   uint32_t words[16];packet(words,n,7);memset(words+8,0,5*sizeof(uint32_t));
   for(unsigned ch=0;ch<9;ch++)words[8+ch/2]|=(uint32_t)(uint16_t)pcm[n][ch]<<(16*(ch&1));
   c9_history_push(&c9_history_shared.history,words);
  }
  written=finish;assert(c9_history_info(&c9_history_shared.history,&end,&available,&epoch,&session));
  c9_shaft_session=session;c9_shaft_epoch=epoch;c9_shaft_waiting=0;
  c9_search_context ctx={.session=session,.epoch=epoch,.first_sample=finish-C9_SEARCH_RAW_FRAMES,.end_sample=finish,.geometry_version=ACOUSTIC_GEOMETRY_VERSION,.calibration_version=ACOUSTIC_CALIBRATION_VERSION,.geometry_confirmed=ACOUSTIC_GEOMETRY_CONFIRMED};
  c9_search_feedback result;assert(c9_candidates_search(pcm+ctx.first_sample,C9_SEARCH_RAW_FRAMES,acoustic_steer_lut,&c9_separator,&ctx,&result));
  if(!result.invalid_input)assert(c9_search_feedback_current(&result,finish,session,epoch,ctx.geometry_version,ctx.calibration_version));
  else assert(!result.count);
  c9_tracks_update_intervals(&c9_aux_tracks,result.candidates,result.count,result.support_first_sample,result.support_end_sample,finish,epoch,session);searches++;
  fprintf(trace,"{\"end\":%u,\"bands\":[",finish);
  for(unsigned band=0;band<3;band++){
   c9_candidate peaks[3];unsigned np=result.invalid_input?0:c9_candidates_extract(c9_separator.search_scores[band],peaks);
   fprintf(trace,"%s[",band?",":"");
   for(unsigned k=0;k<np;k++){int32_t az,el;c9_candidate_angles(&peaks[k],&az,&el);unsigned dbg[3];c9_debug_peak_support(&c9_separator,&peaks[k],acoustic_steer_lut,band,dbg);fprintf(trace,"%s{\"az\":%d,\"el\":%d,\"score\":%d,\"quality\":%u,\"support\":%u,\"mask\":%u}",k?",":"",az,el,peaks[k].score,dbg[0],dbg[1],dbg[2]);}fprintf(trace,"]");
  }
  fprintf(trace,"],\"selected\":[");
  for(unsigned k=0;k<result.count;k++){
   int32_t az,el;c9_candidate_angles(&result.candidates[k],&az,&el);
   fprintf(trace,"%s{\"az\":%d,\"el\":%d,\"bands\":%u,\"frames\":%u,\"first\":%u,\"last\":%u}",k?",":"",az,el,result.band_mask[k],result.support_frames[k],result.support_first_sample[k],result.support_end_sample[k]);
  }
  fprintf(trace,"],\"tracks\":[");
  for(unsigned k=0;k<3;k++){const c9_track *t=&c9_aux_tracks.tracks[k];int32_t az,el;c9_candidate c=c9_track_candidate(t);c9_candidate_angles(&c,&az,&el);fprintf(trace,"%s{\"id\":%u,\"az\":%d,\"el\":%d,\"state\":%u,\"obs\":%u,\"first\":%u,\"last\":%u,\"gaps\":%u}",k?",":"",t->id,az,el,t->state,t->observations,t->first_sample,t->last_sample,t->gap_count);}
  c9_aux_last_tick=dia_gtimer_now();c9_tasks_shared.data.auxiliary.job.state=2u;
  c9_tasks_schedule();run_cpu1_pending(&ipc);c9_tasks_receive();
  unsigned fresh=0,count=0;if(c9_latest_slot>=0){const c9_diagnostic_result *r=&c9_tasks_shared.data.results[c9_latest_slot];count=r->count;for(unsigned i=0;i<count;i++)fresh+=c9_result_current(&r->diagnosis[i],r->session,r->shaft_generation)!=0;}
  fprintf(trace,"],\"snapshot_sequence\":%u,\"snapshot_count\":%u,\"fresh_snapshot_count\":%u,\"diagnostic_started\":%u}\n",c9_latest_sequence,count,fresh,c9_tasks_shared.data.metrics.started);
 }
 for(unsigned n=written;n<total;n++){
  uint32_t words[16];packet(words,n,7);memset(words+8,0,5*sizeof(uint32_t));
  for(unsigned ch=0;ch<9;ch++)words[8+ch/2]|=(uint32_t)(uint16_t)pcm[n][ch]<<(16*(ch&1));
  c9_history_push(&c9_history_shared.history,words);
 }
 fclose(trace);c9_aux_last_tick=dia_gtimer_now();
 int length=c9_candidates_json(body,sizeof(body));assert(length>0);f=fopen(argv[3],"wb");assert(f);fputs("{\"_evidence_source\":\"HOST_FSTF_PLANE_WAVE_SIMULATION\",\"_mock_clock_not_ARM_timing\":true,\"_geometry_fixture_not_physical_calibration\":true,",f);fwrite(body+1,1,length-1,f);fclose(f);
 if(c9_latest_slot>=0){
  c9_diagnostic_result *r=&c9_tasks_shared.data.results[c9_latest_slot];
  for(unsigned i=0;i<r->count;i++){
   assert(r->diagnosis[i].label==C9_DIAG_UNKNOWN&&!r->diagnosis[i].fault_direction_valid);
   char path[1024];snprintf(path,sizeof(path),"%s.audio%u.f64",argv[3],i);f=fopen(path,"wb");assert(f);fwrite(c9_separated[i],sizeof(double),40000,f);fclose(f);
  }
 }
 printf("FSTF_SIM_TASK_PASS searches=%u results=%u sequence=%u no_trusted_fault=1 real_hardware=0\n",searches,c9_latest_slot>=0?c9_tasks_shared.data.results[c9_latest_slot].count:0,c9_latest_slot>=0?c9_tasks_shared.data.results[c9_latest_slot].sequence:0);
 if(argc==5){
  /* Isolated downstream control only: truth directions never enter the automatic job above. */
  c9_candidate known[3];unsigned count=0;char *next=argv[4];
  while(*next&&count<3){char *tail;double az=strtod(next,&tail);assert(tail!=next&&az>=-90&&az<=90);double el=0;if(*tail==':'){next=tail+1;el=strtod(next,&tail);assert(tail!=next&&el>=-90&&el<=90);}unsigned row=(unsigned)((el+90)*32/180);if(row>31)row=31;unsigned col=(unsigned)((az+90)*32/180);if(col>31)col=31;
   known[count++]=(c9_candidate){.grid=row*32u+col,.score=1000,.azimuth_mdeg=(int32_t)(az*1000),.elevation_mdeg=(int32_t)(el*1000),.flags=C9_CANDIDATE_REFINED,.uncertainty_mdeg=3000};
   next=*tail==','?tail+1:tail;
  }
  c9_separation_report sep={0};int separated=c9_candidates_separate(pcm+total-C9_SNAPSHOT_FRAMES,known,count,acoustic_steer_lut,&c9_separator,c9_separated,&sep);
  char path[1024];snprintf(path,sizeof(path),"%s.known_direction_control.json",argv[3]);f=fopen(path,"wb");assert(f);
  fprintf(f,"{\"known_direction_control_only\":true,\"automatic_pipeline_success\":false,\"separated\":%d,\"ready_mask\":%u,\"outputs\":[",separated,sep.ready_mask);
  for(unsigned i=0;i<count;i++){
   c9_diag_binding bind={.track_id=i+1,.grid=known[i].grid,.epoch=7,.first_sample=total-C9_SNAPSHOT_FRAMES,.sample_count=40000,.flags=C9_DIAG_BIND_REQUIRED,.azimuth_mdeg=known[i].azimuth_mdeg,.elevation_mdeg=known[i].elevation_mdeg,.separation_contract=C9_DIAG_SEPARATION_CONTRACT};
   memcpy(bind.usable_mask,sep.usable_mask,sizeof(bind.usable_mask));c9_diag_report d={0};
   if(sep.ready_mask&(1u<<i))c9_diagnose(c9_separated[i],30,&bind,&d);
   fprintf(f,"%s{\"azimuth_mdeg\":%d,\"ready\":%u,\"experimental_available\":%u,\"experimental_label\":\"%s\",\"trusted_label\":%u}",i?",":"",known[i].azimuth_mdeg,!!(sep.ready_mask&(1u<<i)),d.fstf_available,c9_fstf_class_name(d.fstf_available?d.fstf_class:6u),d.label);
   assert(d.label==C9_DIAG_UNKNOWN&&!d.fault_direction_valid);
  }
  fprintf(f,"]}");fclose(f);
 }
 free(pcm);return 0;
}
