#include <assert.h>
#include <stdio.h>
#include "circular9_deadline.h"

int main(void)
{
 circular9_deadline s={0};
 /* The first PCM counter wraps before PS receipt. Both are in the PL domain. */
 uint32_t first=UINT32_MAX-200000u,receipt=first+400000u;
 assert(c9_deadline_receive(&s,2,1,first,receipt,1)==1);
 assert(s.last_us==10000 && s.samples==1 && s.misses==0);
 /* HTTP refreshes and aging the SAME publication never recount a deadline. */
 for(unsigned i=0;i<1000;i++)assert(c9_deadline_receive(&s,2,1,first,receipt+40*i,1)==0);
 assert(s.samples==1 && s.misses==0);
 assert(!c9_deadline_stale(&s,first+(uint32_t)C9_STALE_AFTER_US*40u));
 assert(c9_deadline_stale(&s,first+(uint32_t)C9_STALE_AFTER_US*40u+1u));
 assert(s.misses==0 && s.samples==1);
 /* Stale latches until another complete publication (even over counter wrap). */
 assert(c9_deadline_stale(&s,first));
 assert(c9_deadline_receive(&s,4,2,100u,400101u,1)==1);
 assert(s.last_us==10001 && s.misses==1 && s.valid_misses==1 && !s.stale);
 assert(c9_deadline_receive(&s,7,3,0,123,1)==0); /* odd/in-progress seqlock */
 assert(c9_deadline_receive(&s,8,4,1000,500000,0)==1);
 assert(s.skipped_publications==1 && s.misses==2 && s.valid_misses==1);
 assert(c9_deadline_receive(&s,10,5,1000,999,1)==-1 && s.clock_errors==1);
 assert(s.samples==3); /* invalid clock observations do not pollute quantiles */
 memset(&s,0,sizeof(s));
 for(unsigned i=0;i<100;i++) {
  unsigned us=7000+50*i;
  assert(c9_deadline_receive(&s,2*(i+1),i+1,0,40*us,i%2)==1);
 }
 /* Nearest-rank quantile 95 is 11700 us; 99 is 11900 us. Bins bound above. */
 assert(s.samples==100 && s.max_us==11950 && s.valid_samples==50);
 assert(c9_deadline_percentile_upper(&s,95)==11750);
 assert(c9_deadline_percentile_upper(&s,99)==12000);
 unsigned total=0;for(unsigned i=0;i<C9_LATENCY_BINS;i++)total+=s.histogram[i];
 assert(total==100 && s.misses==39);
 memset(&s,0,sizeof(s));
 assert(c9_deadline_receive(&s,2,1,0,20000u*40u,1)==1);
 assert(c9_deadline_percentile_upper(&s,99)==20000); /* overflow bin uses max */
 printf("CIRCULAR9_DEADLINE_PASS target_us=%u hop_us=%u stale_after_us=%u hardware=UNVERIFIED\n",
        C9_LOCATION_TARGET_US,(unsigned)C9_HOP_US,(unsigned)C9_STALE_AFTER_US);
 return 0;
}
