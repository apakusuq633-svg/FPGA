/* Adapter for the implemented 0x380 DAS/FIR FIFO. One reader owns pop DATA. */
#ifndef PS_DAS_FIFO_H
#define PS_DAS_FIFO_H
#include "ps_das_audio.h"
#define DAS_FIFO_BASE 0x380u
#define DAS_FIFO_VERSION 0x44415301u
typedef struct {
    das_audio_block partial;
    uint64_t consumed;
    uint32_t seq,count;
} das_fifo_receiver;
static inline void das_fifo_init(das_fifo_receiver *r) { memset(r,0,sizeof *r); }
/* Bus offsets are relative to AXI base, not the old 0x700 block window.
 * Position and steering attribution are unavailable in this PL ABI. The sample
 * counter is relative to the software session; any hardware loss is fatal. */
static inline int das_fifo_poll(const das_bus *bus,das_fifo_receiver *r,
                               das_audio_block *out,uint32_t *drops)
{
    uint32_t status,n,i;
    if(bus->read(bus->ctx,0x39c)!=DAS_FIFO_VERSION)return DAS_UNSUPPORTED;
    status=bus->read(bus->ctx,0x384);
    *drops=bus->read(bus->ctx,0x390);
    if((status&4u)||*drops)return DAS_BAD_BLOCK;
    n=(status>>3)&511u;
    if(n>256u)return DAS_BAD_BLOCK;
    if(n>DAS_AUDIO_BLOCK-r->count)n=DAS_AUDIO_BLOCK-r->count;
    if(!n)return DAS_EMPTY;
    if(!r->count) {
        memset(&r->partial.desc,0,sizeof r->partial.desc);
        r->partial.desc.first_sample=r->consumed;
        r->partial.desc.block_seq=r->seq;
        r->partial.desc.sample_count=DAS_AUDIO_BLOCK;
        r->partial.desc.grid_w=16;
        r->partial.desc.flags=DAS_FLAG_POSITION_UNKNOWN;
    }
    for(i=0;i<n;i++) {
        uint32_t pair=bus->read(bus->ctx,0x38c);
        /* high half is filtered output; low half is unfiltered DAS, not sample+1. */
        r->partial.pcm[r->count++]=(int16_t)(uint16_t)(pair>>16);
        r->consumed++;
    }
    /* Reject a partial/complete block if an overflow happened during the drain. */
    *drops=bus->read(bus->ctx,0x390);
    if(*drops||(bus->read(bus->ctx,0x384)&4u))return DAS_BAD_BLOCK;
    if(r->count<DAS_AUDIO_BLOCK)return DAS_EMPTY;
    *out=r->partial;r->count=0;r->seq++;
    return DAS_OK;
}
#endif
