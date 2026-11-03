#ifndef CIRCULAR9_TRACKING_H
#define CIRCULAR9_TRACKING_H
#include <stdint.h>
#include <string.h>
#include "circular9_candidates.h"
#include "circular9_direction.h"

/* CPU0 owns tracks. A short missing peak retains its angular identity only:
 * it supplies no new acoustic evidence and cannot route a fault result.
 * All durations use the original 156250-Hz PCM sample clock. */
#define C9_TRACK_COAST_SAMPLES 23438u /* 150.0032 ms, strictly less than 200 ms. */
#define C9_TRACK_FRESH_OBSERVATIONS 3u
#define C9_TRACK_GAPS 32u
#define C9_TRACK_SUPPORT_PERCENT 90u
#define C9_TRACK_HISTORY_SAMPLES C9_SNAPSHOT_FRAMES
#define C9_TRACK_MAX_MAP_GAP_SAMPLES 6250u /* 40 ms; normal PS map poll is 20 ms. */
enum {C9_TRACK_EXPIRED=0,C9_TRACK_OBSERVED=1,C9_TRACK_COASTING=2,C9_TRACK_RECOVERING=3};
typedef struct {uint32_t first,end;} c9_track_gap;
typedef struct {
 uint32_t id,grid,anchor,first_sample,last_sample,observations;
 int32_t score;
 c9_candidate candidate,anchor_candidate;
 uint32_t state,fresh_observations,confidence_q15,last_observed_confidence_q15;
 uint32_t last_update,gap_open,gap_first,gap_count,coverage_first;
 c9_track_gap gaps[C9_TRACK_GAPS];
} c9_track;
typedef struct {
 c9_track tracks[3];uint32_t next_id,epoch,session,have,last_update,have_sample;
} c9_tracker;

static inline double c9_direction_dot(unsigned a,unsigned b){
 return (double)c9_direction_dot_q30(a,b)/1073741824.0;
}
static inline double c9_track_direction_dot(const c9_candidate *a,const c9_candidate *b){
 double ua[3],ub[3],dot=0;c9_candidate_unit(a,ua);c9_candidate_unit(b,ub);
 for(unsigned k=0;k<3;k++)dot+=ua[k]*ub[k];
 return dot;
}
static inline c9_candidate c9_track_candidate(const c9_track *t){return t->candidate;}
static inline void c9_tracks_reset(c9_tracker *s){
 uint32_t next=s->next_id;memset(s,0,sizeof(*s));s->next_id=next;
}
static inline void c9_track_expire(c9_track *t){memset(t,0,sizeof(*t));}
static inline void c9_track_prune_gaps(c9_track *t,uint32_t sample){
 unsigned remove=0;
 while(remove<t->gap_count&&(uint32_t)(sample-t->gaps[remove].end)>=C9_TRACK_HISTORY_SAMPLES)remove++;
 if(remove){
  t->coverage_first=t->gaps[remove-1u].end;
  memmove(t->gaps,t->gaps+remove,(t->gap_count-remove)*sizeof(t->gaps[0]));
  t->gap_count-=remove;
 }
}
static inline void c9_track_restart_stability(c9_track *t,const c9_candidate *c,uint32_t sample){
 t->anchor=c->grid;t->anchor_candidate=*c;t->first_sample=sample;
 t->coverage_first=sample;
 t->observations=0;t->fresh_observations=0;t->gap_open=0;t->gap_count=0;
}
static inline void c9_track_observe_window(c9_track *t,const c9_candidate *c,uint32_t first,uint32_t sample){
 c9_track_prune_gaps(t,sample);
 /* Refinement is retained in association, anchor stability and CPU1 jobs;
  * coarse grid addresses remain available for the PL steering interface. */
 if(c9_track_direction_dot(&t->anchor_candidate,c)<.9914448613738104){
  c9_track_restart_stability(t,c,first); /* More than 7.5 degrees. */
 }else if(t->gap_open){
  if(t->gap_count==C9_TRACK_GAPS){
   /* Too much unresolved history: never silently discard missing evidence. */
   c9_track_restart_stability(t,c,first);
  }else{
   if((int32_t)(first-t->gap_first)>0)t->gaps[t->gap_count++]=(c9_track_gap){t->gap_first,first};
   t->gap_open=0;
  }
 }
 t->candidate=*c;t->grid=c->grid;t->score=c->score;t->last_sample=sample;t->last_update=sample;
 if(t->observations<UINT32_MAX)t->observations++;
 if(t->fresh_observations<C9_TRACK_FRESH_OBSERVATIONS)t->fresh_observations++;
 t->state=t->fresh_observations>=C9_TRACK_FRESH_OBSERVATIONS?C9_TRACK_OBSERVED:C9_TRACK_RECOVERING;
 t->confidence_q15=t->fresh_observations*32767u/C9_TRACK_FRESH_OBSERVATIONS;
 t->last_observed_confidence_q15=t->confidence_q15;
}
static inline void c9_tracks_update_mode(c9_tracker *s,const c9_candidate *c,unsigned n,
 uint32_t first,uint32_t sample,uint32_t epoch,uint32_t session,unsigned interval,
 const uint32_t *firsts,const uint32_t *ends){
 if(!s->have||epoch!=s->epoch||session!=s->session){
  c9_tracks_reset(s);s->have=1;s->epoch=epoch;s->session=session;
 }
 if(s->have_sample){
  int32_t advance=(int32_t)(sample-s->last_update);
  if(advance<=0)return; /* Duplicate/out-of-order maps cannot create support. */
  if(sample<s->last_update){
   /* A PCM counter wrap starts a new identity era and clears old intervals. */
   c9_tracks_reset(s);s->have=1;s->epoch=epoch;s->session=session;
  }
 }
 uint32_t prior=s->have_sample?s->last_update:sample;
 s->last_update=sample;s->have_sample=1;
 if(n>3)n=3;
 unsigned valid=0,assigned=0,used=0,related=0;
 for(unsigned j=0;j<n;j++)if(c&&c[j].grid<C9_DIRECTION_COUNT&&c[j].score>0)valid|=1u<<j;
 for(unsigned t=0;t<3;t++)if(s->tracks[t].id&&
    (uint32_t)(sample-s->tracks[t].last_sample)>=C9_TRACK_COAST_SAMPLES)c9_track_expire(&s->tracks[t]);
 for(unsigned t=0;t<3;t++)if(s->tracks[t].id&&
    !interval&&sample-prior>C9_TRACK_MAX_MAP_GAP_SAMPLES){
  c9_track *track=&s->tracks[t];
  if(!track->gap_open){track->gap_open=1;track->gap_first=prior;}
  track->fresh_observations=0;
 }
 for(unsigned j=0;j<n;j++)if(valid&(1u<<j))
  for(unsigned t=0;t<3;t++)if(s->tracks[t].id&&
      c9_track_direction_dot(&c[j],&s->tracks[t].candidate)>=.9781476007338057)related|=1u<<j;
 /* Match globally, independent of score rank. At an unresolved angular merge
  * equal nearest directions remain uncertain rather than manufacturing two
  * source observations from one peak. Real physical identity through a merge
  * is not guaranteed by angular tracking alone. */
 for(unsigned k=0;k<n;k++){
  double best=.9781476007338057;int oi=-1,ti=-1; /* <=12-degree association. */
  for(unsigned j=0;j<n;j++)if((valid&(1u<<j))&&!(assigned&(1u<<j))){
   double local_best=.9781476007338057,second=-2;int local_t=-1;
   for(unsigned t=0;t<3;t++)if(s->tracks[t].id&&!(used&(1u<<t))){
    double dot=c9_track_direction_dot(&c[j],&s->tracks[t].candidate);
    if(dot>local_best){second=local_best;local_best=dot;local_t=(int)t;}
    else if(dot>second)second=dot;
   }
   if(local_t>=0&&local_best-second>.00001&&local_best>best){best=local_best;oi=(int)j;ti=local_t;}
  }
  if(oi<0)break;
  c9_track *track=&s->tracks[ti];
  uint32_t begin=firsts?firsts[oi]:(interval?first:sample),finish=ends?ends[oi]:sample;
  if(interval&&!track->gap_open&&(int32_t)(begin-track->last_sample)>0){track->gap_open=1;track->gap_first=track->last_sample;}
  c9_track_observe_window(track,&c[oi],begin,finish);used|=1u<<ti;assigned|=1u<<oi;
 }
 for(unsigned t=0;t<3;t++)if(s->tracks[t].id&&!(used&(1u<<t))){
  c9_track *track=&s->tracks[t];
  if(!track->gap_open){track->gap_open=1;track->gap_first=interval?track->last_sample:prior;}
  track->state=C9_TRACK_COASTING;track->fresh_observations=0;track->last_update=sample;
  track->confidence_q15=(uint32_t)((uint64_t)track->last_observed_confidence_q15*
   (C9_TRACK_COAST_SAMPLES-(sample-track->last_sample))/C9_TRACK_COAST_SAMPLES);
 }
 for(unsigned j=0;j<n;j++)if((valid&(1u<<j))&&!(assigned&(1u<<j))&&!(related&(1u<<j))){
  int free_slot=-1;for(unsigned t=0;t<3;t++)if(!s->tracks[t].id){free_slot=(int)t;break;}
  if(free_slot<0)break; /* A louder newcomer cannot preempt a coasting track. */
  c9_track *track=&s->tracks[free_slot];
  do{if(++s->next_id==0)++s->next_id;}while(
   s->next_id==s->tracks[0].id||s->next_id==s->tracks[1].id||s->next_id==s->tracks[2].id);
  uint32_t begin=firsts?firsts[j]:(interval?first:sample),finish=ends?ends[j]:sample;
  track->id=s->next_id;c9_track_restart_stability(track,&c[j],begin);
  c9_track_observe_window(track,&c[j],begin,finish);
 }
}
static inline void c9_track_observe(c9_track *t,const c9_candidate *c,uint32_t sample){
 c9_track_observe_window(t,c,sample,sample);
}
static inline void c9_tracks_update(c9_tracker *s,const c9_candidate *c,unsigned n,
 uint32_t sample,uint32_t epoch,uint32_t session){
 c9_tracks_update_mode(s,c,n,sample,sample,epoch,session,0,NULL,NULL);
}
/* Genuine analyzed intervals only. Replaying one end cannot add observations;
 * an overlap supports only its measured interval and cannot fill older gaps. */
static inline void c9_tracks_update_interval(c9_tracker *s,const c9_candidate *c,unsigned n,
 uint32_t first,uint32_t end,uint32_t epoch,uint32_t session){
 if((int32_t)(end-first)<=0||(uint32_t)(end-first)>C9_SNAPSHOT_FRAMES)return;
 c9_tracks_update_mode(s,c,n,first,end,epoch,session,1,NULL,NULL);
}
static inline void c9_tracks_update_intervals(c9_tracker *s,const c9_candidate *c,unsigned n,
 const uint32_t firsts[3],const uint32_t ends[3],uint32_t publication_end,uint32_t epoch,uint32_t session){
 if(n>3||(!c&&n)||(!firsts&&n)||(!ends&&n))return;
 for(unsigned i=0;i<n;i++)if((int32_t)(ends[i]-firsts[i])<=0||
    (uint32_t)(ends[i]-firsts[i])>C9_SNAPSHOT_FRAMES||(int32_t)(publication_end-ends[i])<0)return;
 c9_tracks_update_mode(s,c,n,publication_end,publication_end,epoch,session,1,firsts,ends);
}
enum {C9_COVER_NO_ID=1u,C9_COVER_STATE=2u,C9_COVER_OBSERVATIONS=4u,
 C9_COVER_OPEN_GAP=8u,C9_COVER_ORIGIN=16u,C9_COVER_RANGE=32u,C9_COVER_MISSING=64u};
/* Same acceptance contract; expose why a real interval cannot qualify. */
static inline uint32_t c9_track_coverage_reason(const c9_track *t,uint32_t first,uint32_t end,
 uint32_t *missing_out,uint32_t *tail_out){
 uint32_t reason=0;uint64_t missing=0;uint32_t tail=0;
 if(!t->id)reason|=C9_COVER_NO_ID;
 if(t->state!=C9_TRACK_OBSERVED)reason|=C9_COVER_STATE;
 if(t->fresh_observations<C9_TRACK_FRESH_OBSERVATIONS||t->observations<C9_TRACK_FRESH_OBSERVATIONS)reason|=C9_COVER_OBSERVATIONS;
 if(t->gap_open)reason|=C9_COVER_OPEN_GAP;
 if((int32_t)(first-t->first_sample)<0||(int32_t)(first-t->coverage_first)<0)reason|=C9_COVER_ORIGIN;
 if((int32_t)(t->last_sample-first)<0||(int32_t)(end-first)<=0)reason|=C9_COVER_RANGE;
 if((int32_t)(end-t->last_sample)>0)missing=tail=end-t->last_sample;
 for(unsigned i=0;i<t->gap_count;i++){
  const c9_track_gap *g=&t->gaps[i];
  if((int32_t)(g->end-first)<=0)continue;
  uint32_t start=(int32_t)(g->first-first)<0?first:g->first;
  uint32_t gap_end=(int32_t)(g->end-end)>0?end:g->end;
  if((int32_t)(gap_end-start)>0)missing+=gap_end-start;
 }
 if(!(reason&C9_COVER_RANGE)&&missing*100u>(uint64_t)(end-first)*(100u-C9_TRACK_SUPPORT_PERCENT))reason|=C9_COVER_MISSING;
 if(missing_out)*missing_out=missing>UINT32_MAX?UINT32_MAX:(uint32_t)missing;
 if(tail_out)*tail_out=tail;
 return reason;
}
static inline int c9_track_covers_range(const c9_track *t,uint32_t first,uint32_t end){
 return c9_track_coverage_reason(t,first,end,NULL,NULL)==0;
}
static inline int c9_track_covers(const c9_track *t,uint32_t first){
 return c9_track_covers_range(t,first,t->last_sample);
}
#endif
