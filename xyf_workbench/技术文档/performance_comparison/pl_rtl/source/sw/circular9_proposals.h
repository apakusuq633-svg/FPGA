#ifndef CIRCULAR9_PROPOSALS_H
#define CIRCULAR9_PROPOSALS_H
#include <stdint.h>
#include <string.h>
#include "circular9_candidates.h"
/* CPU0 slow path only. Four-observation exponential evidence smooths brief
 * competing peaks without changing RV32's fast map or its timing contract.
 * A smoothed peak MUST also have a current local maximum nearby. Historical
 * evidence alone can never keep an absent source in OBSERVED state. */
typedef struct {
 int32_t evidence[1024];
 uint32_t have,sample,epoch,session,updates,supported,rejected;
} c9_proposal_map;
static inline void c9_proposals_reset(c9_proposal_map *s){s->have=0;}
static inline int c9_proposal_local_peak(const int32_t p[1024],unsigned g){
 unsigned x=g%32,y=g/32;
 for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){
  int xx=(int)x+dx,yy=(int)y+dy;
  if(xx>=0&&xx<32&&yy>=0&&yy<32&&p[yy*32+xx]>p[g])return 0;
 }
 return p[g]>0;
}
static inline unsigned c9_proposals_update(c9_proposal_map *s,const int32_t p[1024],
 uint32_t sample,uint32_t epoch,uint32_t session,c9_candidate out[3]){
 if(s->have&&epoch==s->epoch&&session==s->session&&(int32_t)(sample-s->sample)<=0)return 0;
 int fresh=!s->have||epoch!=s->epoch||session!=s->session||(uint32_t)(sample-s->sample)>31250u;
 int32_t largest=0;
 for(unsigned i=0;i<1024;i++){
  if(fresh)s->evidence[i]=p[i];
  else s->evidence[i]+=(int32_t)(((int64_t)p[i]-s->evidence[i])/4);
  if(p[i]>largest)largest=p[i];
 }
 s->have=1;s->sample=sample;s->epoch=epoch;s->session=session;s->updates++;
 c9_candidate proposed[3];unsigned n=c9_candidates_extract(s->evidence,proposed),accepted=0;
 unsigned used_grid[3];
 for(unsigned i=0;i<n;i++){
  unsigned x=proposed[i].grid%32,y=proposed[i].grid/32;
  c9_candidate current={0};double reference[3],best_dot=.9914448613738104;
  c9_candidate_unit(&proposed[i],reference);
  /* EMA ranks proposals only. The returned bearing comes from THIS map,
   * within7.5 degrees, with one-to-one support. One present source must not
   * refresh two historical IDs or hide motion behind an old smoothed angle. */
  for(int dy=-2;dy<=2;dy++)for(int dx=-2;dx<=2;dx++){
   int xx=(int)x+dx,yy=(int)y+dy;
   if(xx>=0&&xx<32&&yy>=0&&yy<32){
    unsigned g=(unsigned)yy*32u+(unsigned)xx;
    int used=0;for(unsigned k=0;k<accepted;k++)if(used_grid[k]==g)used=1;
    if(used||p[g]<=0||(int64_t)p[g]*40<largest||!c9_proposal_local_peak(p,g))continue;
    c9_candidate candidate;double unit[3],dot=0;
    if(!c9_candidate_at_peak(p,g,&candidate))continue;
    c9_candidate_unit(&candidate,unit);
    for(unsigned k=0;k<3;k++)dot+=reference[k]*unit[k];
    if(dot>best_dot||(dot==best_dot&&candidate.score>current.score)){best_dot=dot;current=candidate;}
   }
  }
  if(current.score>0){used_grid[accepted]=current.grid;out[accepted++]=current;s->supported++;}
  else s->rejected++;
 }
 return accepted;
}
#endif
