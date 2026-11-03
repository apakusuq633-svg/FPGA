/* Event model with hypothetical costs; actual tracking/schedule helpers.
 * Not CPU execution, full task scheduler, RTOS, cache or board measurement. */
#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include "circular9_tracking.h"
#include "circular9_schedule.h"
static uint32_t sample(uint32_t us){return (uint32_t)((uint64_t)us*156250/1000000);}
int main(void){
 const unsigned ac[]={20000,50000,100000,140000,180000,210000};
 const unsigned dc[]={0,100000,678000,1300000};
 puts("[");
 for(unsigned a=0;a<6;a++)for(unsigned d=0;d<4;d++){
 c9_tracker tr={0};c9_diagnostic_schedule sched={0};
 c9_candidate c={.grid=528,.score=1000,.azimuth_mdeg=0,.elevation_mdeg=0,.flags=C9_CANDIDATE_REFINED};
 uint32_t issued=0,pending_end=0,capture=0,done=0,lastid=0,maxgap=0,prev=0;
 unsigned pending=0,busy=0,diagpending=0,burst=0,searches=0,accepted=0,late=0,eligible=0,diags=0,completed=0,identities=0,reasons[8]={0},have=0;
 for(uint32_t us=110000;us<20000000;us+=1000){
  uint32_t end=sample(us)&~3u;
  if(!have||end-issued>=8192){uint32_t steps=have?(end-issued)/8192:1;issued=have?issued+steps*8192:end;pending_end=issued;pending=1;have=1;}
  if(busy&&us>=done){
   if(busy==1){searches++;if(us-done+ac[a]<=200000u&&end-capture<=C9_SEARCH_MAX_AGE_SAMPLES){
    uint32_t first[3]={capture-C9_SEARCH_RAW_FRAMES+256},ends[3]={capture};
    c9_tracks_update_intervals(&tr,&c,1,first,ends,capture,1,1);accepted++;
    if(prev&&capture-prev>maxgap)maxgap=capture-prev;prev=capture;
    if(tr.tracks[0].id!=lastid){lastid=tr.tracks[0].id;identities++;}
   }else late++;
   }else completed++;
   busy=0;
  }
  uint32_t selected=0,skip=0;
  if(end>C9_SNAPSHOT_FRAMES+3&&c9_diagnostic_due(&sched,end,1,1,0,&selected,&skip)){
   uint32_t why=c9_track_coverage_reason(&tr.tracks[0],selected-C9_SNAPSHOT_FRAMES,selected,0,0);
   if(end-tr.tracks[0].last_sample>31250)why|=128;
   if(!why){eligible++;diagpending=1;c9_diagnostic_issued(&sched,selected,1,1,0);}
   else for(unsigned k=0;k<8;k++)if(why&(1u<<k))reasons[k]++;
  }
  /* Model source worker priority: at most2 auxiliary jobs before diagnostic.
   * Queue replacement is newest-window coalescing; no FFT or real CPU time. */
  if(!busy){
   if(pending&&(burst<2||!diagpending)){capture=pending_end;pending=0;busy=1;done=us+ac[a];if(burst<2)burst++;}
   else if(diagpending){burst=0;diagpending=0;diags++;busy=2;done=us+dc[d];}
  }
 }
 if(ac[a]>200000)assert(!accepted&&!diags);
 printf("%s{\"aux_cost_us\":%u,\"diagnostic_cost_us\":%u,\"search_completed\":%u,\"search_accepted\":%u,\"late\":%u,\"eligible\":%u,\"diagnostic_started\":%u,\"diagnostic_completed\":%u,\"identities\":%u,\"max_evidence_end_gap_ms\":%.4f,\"reject_bit_counts\":[",(a||d)?",\n":"",ac[a],dc[d],searches,accepted,late,eligible,diags,completed,identities,maxgap/156.25);
 for(unsigned k=0;k<8;k++)printf("%s%u",k?",":"",reasons[k]);printf("]}");
 }
 puts("\n]");return 0;
}
