/* Native fixture: independent candidate eligibility must not relax evidence. */
#define C9_PIPELINE_NO_MAIN
#include "circular9_pipeline_test.c"
int main(void){
 c9_tasks_init();c9_tasks_shared.data.auxiliary.job.state=2;c9_tracks=(c9_tracker){0};c9_aux_tracks=(c9_tracker){0};c9_schedule=(c9_diagnostic_schedule){0};c9_shaft_confirmed=0;
 push_pcm(0,1);c9_tracks_update(&c9_tracks,scene,3,0,7,1);advance_supported(1,200000);
 c9_track stable=c9_tracks.tracks[0];
 c9_tracks.tracks[1].state=C9_TRACK_RECOVERING;c9_tracks.tracks[1].fresh_observations=1;
 c9_tracks.tracks[2].first_sample=199000;c9_tracks.tracks[2].coverage_first=199000;
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.count==1,"recovering and short observed neighbours do not veto covered source");
 CHECK(c9_tasks_shared.data.job.tracks[0].id==stable.id&&c9_tasks_shared.data.job.unresolved_tracks==2,"identity retained and unresolved context explicit");
 struct ipc_page ipc={0};c9_tasks_cpu1(&ipc);c9_tasks_receive();
 CHECK(c9_latest_slot>=0&&c9_tasks_shared.data.results[c9_latest_slot].count==1,"single eligible output published");
 CHECK(!(c9_tasks_shared.data.results[c9_latest_slot].diagnosis[0].binding.flags&C9_DIAG_BIND_DIRECTION),"unresolved neighbours cannot produce trusted fault attribution");
 c9_schedule.have=0;c9_tracks.tracks[0].gap_count=1;c9_tracks.tracks[0].gaps[0]=(c9_track_gap){50000,90000};
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==0,"more than10percent missing evidence still rejects every incomplete track");
 c9_tracks.tracks[0]=stable;c9_schedule.have=0;c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.count==1,"covered source can resume without changing thresholds");
 CHECK(c9_snapshot_map_time_valid(100000,100004,100004),"newer real map does not underflow hop-aligned snapshot age");
 CHECK(!c9_snapshot_map_time_valid(100000,100004,100005),"map from future uncollected PCM rejected");
 CHECK(c9_snapshot_map_time_valid(100000,100004,68750),"200ms observation boundary accepted");
 CHECK(!c9_snapshot_map_time_valid(100000,100004,68749),"older observation still rejected");
 CHECK(c9_snapshot_map_time_valid(16,20,0xfffffff0u),"map age handles uint32 sample wrap");
 CHECK(!c9_snapshot_map_time_valid(16,20,21),"wrapped future map rejected");
 /* A close pair must not make the separator discard an independent source. */
 c9_tasks_shared.data.job.state=0;c9_schedule.have=0;c9_aux_tracks=(c9_tracker){0};
 c9_tracks=(c9_tracker){.have=1,.epoch=7,.session=1};
 const int angles[3]={0,20000,-50000};
 for(unsigned i=0;i<3;i++){
  c9_tracks.tracks[i]=stable;c9_tracks.tracks[i].id=10+i;
  unsigned x=(unsigned)((angles[i]+90000)*32/180000);
  c9_tracks.tracks[i].candidate=(c9_candidate){.grid=16*32+x,.score=1000,.azimuth_mdeg=angles[i],.elevation_mdeg=0,.flags=C9_CANDIDATE_REFINED};
  c9_tracks.tracks[i].grid=c9_tracks.tracks[i].candidate.grid;
 }
 c9_tasks_schedule();CHECK(c9_tasks_shared.data.job.state==1&&c9_tasks_shared.data.job.count==2,"close angular neighbour cannot starve a separable independent source");
 CHECK(c9_tasks_shared.data.job.unresolved_tracks==1,"close neighbour remains unresolved for fault guards");
 CHECK(c9_track_direction_dot(&c9_tasks_shared.data.job.tracks[0].candidate,&c9_tasks_shared.data.job.tracks[1].candidate)<=.90630778703665,"submitted job satisfies separator angular contract");
 CHECK(!fail,"snapshot scheduling regressions");puts("SNAPSHOT_SCHEDULE_PASS synthetic_only=1 independent_candidates=1 unresolved_fault_withheld=1 ninety_percent_retained=1");return fail?1:0;
}
