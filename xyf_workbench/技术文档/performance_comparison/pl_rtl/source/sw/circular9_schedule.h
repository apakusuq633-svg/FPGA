#ifndef CIRCULAR9_SCHEDULE_H
#define CIRCULAR9_SCHEDULE_H
#include <stdint.h>
/* Scheduling uses the acquisition sample clock, never a guessed CPU GTIMER rate. */
#define C9_DIAGNOSTIC_HOP_RAW 80000u /*512ms at156250Hz; observation remains160000raw.*/
/* 512ms remains the hop and maximum queued-input age. Completed work has
 * a separate3s budget; stage5 board measured678ms processing/779ms total. */
#define C9_DIAGNOSTIC_DEADLINE_US 3000000u
#define C9_DIAGNOSTIC_RESULT_AGE_RAW 468750u
/* Observation may be newer than an earlier hop-aligned snapshot, but never
 * newer than captured PCM. A newer observation is not a huge unsigned age.
 * Coverage of the actual snapshot is independently checked by the worker. */
static inline int c9_snapshot_map_time_valid(uint32_t snapshot_end,uint32_t captured_end,uint32_t map_sample){
 return (int32_t)(captured_end-map_sample)>=0&&
        (int32_t)(snapshot_end-map_sample)<=31250;
}
typedef struct {uint32_t have,end,session,epoch,generation;} c9_diagnostic_schedule;
static inline int c9_diagnostic_due(const c9_diagnostic_schedule *s,uint32_t end,
 uint32_t session,uint32_t epoch,uint32_t generation,uint32_t *selected,uint32_t *skipped){
 end&=~3u;*skipped=0;
 if(!s->have||s->session!=session||s->epoch!=epoch||s->generation!=generation){*selected=end;return 1;}
 uint32_t advance=end-s->end;
 if(advance>=0x80000000u||advance<C9_DIAGNOSTIC_HOP_RAW)return 0;
 uint32_t steps=advance/C9_DIAGNOSTIC_HOP_RAW;
 *selected=s->end+steps*C9_DIAGNOSTIC_HOP_RAW;*skipped=steps-1u;
 return 1;
}
static inline void c9_diagnostic_issued(c9_diagnostic_schedule *s,uint32_t end,
 uint32_t session,uint32_t epoch,uint32_t generation){
 *s=(c9_diagnostic_schedule){1,end,session,epoch,generation};
}
#endif
