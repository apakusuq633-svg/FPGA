#include "circular9_proposals.h"
#include <assert.h>
#include <stdio.h>
static c9_proposal_map s;
static int32_t map[1024];
static int has(const c9_candidate *c,unsigned n,unsigned grid){for(unsigned i=0;i<n;i++)if(c[i].grid==grid)return 1;return 0;}
int main(void){
 c9_candidate c[3];unsigned n=0;
 const unsigned strong=16u*32u+4u,weak=16u*32u+26u;
 for(unsigned k=0;k<40;k++){
  memset(map,0,sizeof(map));map[strong]=100000;map[weak]=12000;
  /* Instantaneous distractors exceed the weaker source but change direction.
   * Their scores decay while the stationary weak source accumulates. */
  map[(k%4u)*32u+16u]=21000;map[(27u+k%4u)*32u+16u]=19000;
  n=c9_proposals_update(&s,map,512u+k*3072u,1,1,c);
 }
 assert(has(c,n,strong)&&has(c,n,weak));
 uint32_t updates=s.updates;
 assert(c9_proposals_update(&s,map,s.sample,1,1,c)==0&&s.updates==updates);
 memset(map,0,sizeof(map));map[strong]=100000;
 n=c9_proposals_update(&s,map,s.sample+3072u,1,1,c);
 assert(!has(c,n,weak)); /* EMA tail must not turn a disappeared source into observed. */
 memset(map,0,sizeof(map));map[weak]=15000;
 n=c9_proposals_update(&s,map,0,2,2,c);assert(has(c,n,weak)&&!has(c,n,strong));
 c9_proposals_reset(&s);memset(map,0,sizeof(map));
 assert(c9_proposals_update(&s,map,100,2,2,c)==0);
 /* One merged middle peak cannot refresh two separated historical sources. */
 c9_proposals_reset(&s);memset(map,0,sizeof(map));
 const unsigned a=14u*32u+11u,b=18u*32u+15u,mid=16u*32u+13u;
 map[a]=100000;map[b]=90000;
 assert(c9_proposals_update(&s,map,0,3,3,c)==2);
 memset(map,0,sizeof(map));map[mid]=40000;
 assert(c9_proposals_update(&s,map,3125,3,3,c)==0);
 /* A current peak displaced11.25 degrees may not authorize the old angle. */
 c9_proposals_reset(&s);memset(map,0,sizeof(map));map[strong]=100000;
 assert(c9_proposals_update(&s,map,0,4,4,c)==1);
 memset(map,0,sizeof(map));map[strong+2]=100000;
 assert(c9_proposals_update(&s,map,3125,4,4,c)==0);
 /* Small motion uses the actual current angle, never the smoothed old one. */
 c9_proposals_reset(&s);memset(map,0,sizeof(map));map[strong]=100000;
 assert(c9_proposals_update(&s,map,0,5,5,c)==1);
 memset(map,0,sizeof(map));map[strong+1]=100000;
 n=c9_proposals_update(&s,map,3125,5,5,c);assert(n==1&&c[0].grid==strong+1);
 puts("CIRCULAR9_PROPOSALS_PASS weak_stationary_retained current_support_required one_to_one_current_angles duplicate_rejected epoch_reset");
 return 0;
}
