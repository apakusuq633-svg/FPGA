#ifndef CIRCULAR9_CANDIDATES_H
#define CIRCULAR9_CANDIDATES_H
#include <stdint.h>
#define C9_HISTORY_FRAMES 625000u /* Four seconds at 156250 Hz. */
#define C9_SNAPSHOT_FRAMES 160256u /* 1.024 seconds plus filter/delay warmup. */
typedef struct {int16_t pcm[10];volatile uint32_t sequence;} c9_history_frame;
typedef struct {
 volatile uint32_t end,count,epoch;
 c9_history_frame frames[C9_HISTORY_FRAMES];
} c9_history;
typedef struct {uint32_t grid;int32_t score;} c9_candidate;
void c9_history_init(c9_history *s);
void c9_history_push(c9_history *s,const uint32_t packet[16]);
/* Returns zero on gaps/overwrite. Copy has independent sample ownership. */
int c9_history_snapshot(const c9_history *s,int16_t (*pcm)[9],uint32_t *first,uint32_t *epoch);
unsigned c9_candidates_extract(const int32_t scores[1024],c9_candidate out[3]);
void c9_candidate_audio(const int16_t (*raw)[9],unsigned grid,const uint32_t *lut,
 const uint32_t fir[32],int16_t *work,double out[40000]);
#endif
