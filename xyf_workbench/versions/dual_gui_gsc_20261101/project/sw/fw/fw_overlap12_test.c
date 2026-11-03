#include "fw_overlap12.h"
#include <assert.h>
#include <stdio.h>
static overlap12 state;
static int16_t raw[12][512];
static int16_t sample(unsigned block,unsigned c,unsigned i) {
 if(c==0)return -32768;
 if(c==1)return 32767;
 return (int16_t)((block*512u+i)*73u+c*977u);
}
int main(void) {
 unsigned windows=0;
 for(unsigned run=0;run<3;run++) {
  overlap12_reset(&state);
  uint32_t seq=run==1?UINT32_MAX-2u:19u;
  uint32_t first=run==1?UINT32_MAX-1023u:0u;
  unsigned blocks=run==0?4u:run==1?16u:256u;
  for(unsigned b=0;b<blocks;b++) {
   for(unsigned c=0;c<12;c++)for(unsigned i=0;i<512;i++)raw[c][i]=sample(b,c,i);
   assert(overlap12_ingest(&state,raw,seq+b,first+b*512u)==(b?OVERLAP_WINDOW:OVERLAP_WARMUP));
   if(!b)continue;
   overlap12_view v;assert(overlap12_acquire(&state,&v));
   assert(v.first==first+(b-1u)*512u);
   for(unsigned c=0;c<12;c++) {
    int64_t sum=0;
    for(unsigned i=0;i<512;i++) {
     assert(v.old_half[c][i]==sample(b-1,c,i));assert(v.new_half[c][i]==sample(b,c,i));
     sum+=(int64_t)sample(b-1,c,i)+sample(b,c,i);
    }
    assert(sum==v.sum[c]);assert(sum/1024==v.sum[c]/1024);
   }
   assert(overlap12_ingest(&state,raw,seq+b+1,first+(b+1)*512u)==OVERLAP_BUSY);
   assert(!overlap12_release(&state,v.window_id+1));
   assert(overlap12_release(&state,v.window_id));
   assert(overlap12_ingest(&state,raw,seq+b+2,first+(b+1)*512u)==OVERLAP_GAP);
   assert(overlap12_ingest(&state,raw,seq+b+1,first+(b+1)*512u+1)==OVERLAP_GAP);
   windows++;
  }
 }
 overlap12_reset(&state);assert(!state.locked && !state.warm);
 printf("OVERLAP12_HOST_PASS windows=%u bytes=%zu signed_endpoints_wrap_busy_gap_reset=PASS\n",windows,sizeof state);
 return 0;
}
