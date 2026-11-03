#ifndef CIRCULAR9_AUDIO_H
#define CIRCULAR9_AUDIO_H
#include "gsc9.h"
#include "circular9_profile.h"
#include "ps_das_audio.h"
#define C9_FINE_CACHE 64u
typedef struct {uint32_t version,epoch,grid,delay_q16[9];} c9_audio_direction;
typedef struct {
 gsc9_state adaptive;
 das_audio_block block;
 uint32_t count,block_sequence,have_sample,last_sample,last_version,last_epoch;
 uint32_t discontinuities,reason,filter_head,filter_count,pending_flags;
 int16_t filter_history[128];
 uint32_t fine_cache_head,target_guard_requested;
 c9_audio_direction fine_cache[C9_FINE_CACHE];
} circular9_audio;
void circular9_audio_init(circular9_audio *s);
int circular9_audio_store_direction(circular9_audio *s,uint32_t version,uint32_t epoch,
 unsigned grid,const uint32_t delay_q16[9]);
/* Exactly one validated packet, output and complete-block indication (1/0).
 * A changed direction/epoch never shares a classification block with its predecessor. */
int circular9_audio_push(circular9_audio *s,const uint32_t words[16],
 const uint32_t *steer_lut,const uint32_t *fir,int enabled,int freeze,
 uint32_t drops,int16_t *output);
#endif
