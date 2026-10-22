#ifndef FW_OVERLAP12_H
#define FW_OVERLAP12_H
#include <stdint.h>
/* Raw PCM only. Caller must release the immutable view before ingest. */
typedef struct {
 int16_t half[2][12][512];
 int64_t sum[2][12];
 uint32_t seq,first,window_id;
 unsigned bank,warm,locked;
} overlap12;
typedef struct {
 const int16_t (*old_half)[512];
 const int16_t (*new_half)[512];
 int64_t sum[12];
 uint32_t first,window_id;
} overlap12_view;
enum { OVERLAP_WARMUP=0,OVERLAP_WINDOW=1,OVERLAP_BUSY=-1,OVERLAP_GAP=-2 };
static inline void overlap12_reset(overlap12 *s) {
 s->seq=0;s->first=0;s->window_id=0;s->bank=0;s->warm=0;s->locked=0;
}
static inline int overlap12_ingest(overlap12 *s,const int16_t (*raw)[512],
                                  uint32_t seq,uint32_t first) {
 if(s->locked)return OVERLAP_BUSY;
 if(s->warm && (seq-s->seq!=1u || first-s->first!=512u))return OVERLAP_GAP;
 unsigned b=s->warm?(s->bank^1u):0;
 for(unsigned c=0;c<12;c++) {
  int64_t sum=0;
  for(unsigned i=0;i<512;i++){int16_t x=raw[c][i];s->half[b][c][i]=x;sum+=x;}
  s->sum[b][c]=sum;
 }
 s->bank=b;s->seq=seq;s->first=first;
 if(!s->warm){s->warm=1;return OVERLAP_WARMUP;}
 s->window_id++;s->locked=1;return OVERLAP_WINDOW;
}
static inline int overlap12_acquire(const overlap12 *s,overlap12_view *v) {
 if(!s->locked)return 0;
 v->old_half=s->half[s->bank^1u];v->new_half=s->half[s->bank];
 for(unsigned c=0;c<12;c++)v->sum[c]=s->sum[0][c]+s->sum[1][c];
 v->first=s->first-512u;v->window_id=s->window_id;return 1;
}
static inline int overlap12_release(overlap12 *s,uint32_t id) {
 if(!s->locked || id!=s->window_id)return 0;
 s->locked=0;return 1;
}
#endif
