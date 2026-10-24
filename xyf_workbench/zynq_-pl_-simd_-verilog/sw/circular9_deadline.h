#ifndef CIRCULAR9_DEADLINE_H
#define CIRCULAR9_DEADLINE_H
#include <stdint.h>
#include <string.h>
#include "circular9_profile.h"

/* Publication-to-receipt statistics use the PL 40 MHz counter at both ends.
 * The start is the first PCM sample, NOT PDM power-up or microphone latency.
 * Percentiles are histogram upper bounds, not interpolated exact quantiles. */
#define C9_LOCATION_TARGET_US 10000u
#define C9_LOCATION_POLL_US 100u
#define C9_PL_TICKS_PER_US 40u
#define C9_LATENCY_BIN_US 250u
#define C9_LATENCY_BINS 64u
#define C9_HOP_US ((ACOUSTIC_LOCALIZER_HOP * 1000000ull * ACOUSTIC_SAMPLE_RATE_DEN + ACOUSTIC_SAMPLE_RATE_NUM - 1u) / ACOUSTIC_SAMPLE_RATE_NUM)
#define C9_STALE_AFTER_US (C9_LOCATION_TARGET_US + C9_HOP_US + C9_LOCATION_POLL_US)
typedef struct {
 uint32_t have,sequence,frame,first_tick,receipt_tick,stale;
 uint32_t samples,valid_samples,misses,valid_misses,skipped_publications,clock_errors;
 uint32_t last_us,max_us,histogram[C9_LATENCY_BINS];
} circular9_deadline;

static inline int c9_deadline_receive(circular9_deadline *s,uint32_t sequence,
 uint32_t frame,uint32_t first_tick,uint32_t receipt_tick,int accepted)
{
 if(!sequence || (sequence&1u) || (s->have&&sequence==s->sequence))return 0;
 uint32_t elapsed=receipt_tick-first_tick;
 if(elapsed>=0x80000000u){s->clock_errors++;return -1;}
 if(s->have) {
  uint32_t delta=frame-s->frame;
  if(delta>1u && delta<0x80000000u)s->skipped_publications+=delta-1u;
 }
 s->have=1;s->sequence=sequence;s->frame=frame;s->first_tick=first_tick;
 s->receipt_tick=receipt_tick;s->stale=0;
 s->last_us=(elapsed+C9_PL_TICKS_PER_US-1u)/C9_PL_TICKS_PER_US;
 if(s->last_us>s->max_us)s->max_us=s->last_us;
 if(s->samples!=UINT32_MAX) {
  unsigned bin=s->last_us?(s->last_us-1u)/C9_LATENCY_BIN_US:0u;
  if(bin>=C9_LATENCY_BINS)bin=C9_LATENCY_BINS-1u;
  s->samples++;s->histogram[bin]++;
  if(accepted)s->valid_samples++;
  if(s->last_us>C9_LOCATION_TARGET_US){s->misses++;if(accepted)s->valid_misses++;}
 }
 return 1;
}
static inline int c9_deadline_stale(circular9_deadline *s,uint32_t now)
{
 if(s->have && (uint32_t)(now-s->first_tick)>C9_STALE_AFTER_US*C9_PL_TICKS_PER_US)s->stale=1;
 return s->have&&s->stale;
}
static inline uint32_t c9_deadline_percentile_upper(const circular9_deadline *s,unsigned percent)
{
 if(!s->samples || percent<1u || percent>100u)return 0;
 uint32_t rank=(uint32_t)(((uint64_t)s->samples*percent+99u)/100u),sum=0;
 for(unsigned i=0;i<C9_LATENCY_BINS;i++) {
  sum+=s->histogram[i];
  if(sum>=rank)return i==C9_LATENCY_BINS-1u?s->max_us:(i+1u)*C9_LATENCY_BIN_US;
 }
 return s->max_us;
}
#endif
