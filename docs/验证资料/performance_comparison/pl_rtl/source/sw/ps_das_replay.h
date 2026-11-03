/* Explicitly synthetic block source. No PL or MMIO, but uses the real block pipeline. */
#ifndef PS_DAS_REPLAY_H
#define PS_DAS_REPLAY_H
#include <string.h>
#include "das_audio_contract.h"
/* Two AM fixtures alternate every four diagnostic segments, even inside a block. */
static inline void das_replay_dynamic_block(const double *a,const double *b,
                                           uint32_t source_n,uint32_t seq,
                                           uint64_t first,das_audio_block *block)
{
    unsigned i;
    memset(block,0,sizeof *block);
    block->desc.first_sample=first;block->desc.block_seq=seq;
    block->desc.sample_count=DAS_AUDIO_BLOCK;block->desc.grid_w=16;
    block->desc.target_grid=53;block->desc.steer_seq=1;
    block->desc.flags=DAS_FLAG_SYNTHETIC;
    for(i=0;i<DAS_AUDIO_BLOCK;i++) {
        uint64_t sample=first+i;
        const double *source=((sample/source_n)/4u)%2u ? b : a;
        double v=source[sample%source_n]*32768.0;
        if(v>32767){v=32767;block->desc.flags|=DAS_FLAG_CLIPPED;}
        if(v< -32768){v= -32768;block->desc.flags|=DAS_FLAG_CLIPPED;}
        block->pcm[i]=(int16_t)v;
    }
}
static inline void das_replay_block(const double *source,uint32_t source_n,
                                   uint32_t seq,uint64_t first,das_audio_block *b)
{
    unsigned i;
    memset(b,0,sizeof *b);
    b->desc.first_sample=first;b->desc.block_seq=seq;b->desc.sample_count=DAS_AUDIO_BLOCK;
    b->desc.grid_w=16;b->desc.target_grid=53;b->desc.steer_seq=1;
    b->desc.flags=DAS_FLAG_SYNTHETIC;
    for(i=0;i<DAS_AUDIO_BLOCK;i++) {
        double v=source[(first+i)%source_n]*32768.0;
        if(v>32767.0){v=32767.0;b->desc.flags|=DAS_FLAG_CLIPPED;}
        if(v< -32768.0){v= -32768.0;b->desc.flags|=DAS_FLAG_CLIPPED;}
        b->pcm[i]=(int16_t)v;
    }
}
#endif
