/* PS receiver and DDR segment queue. No synthetic fallback on a missing PL window. */
#ifndef PS_DAS_AUDIO_H
#define PS_DAS_AUDIO_H
#include <string.h>
#include "das_audio_contract.h"
typedef uint32_t (*das_read_fn)(void *, uint32_t);
typedef void (*das_write_fn)(void *, uint32_t, uint32_t);
typedef struct { void *ctx; das_read_fn read; das_write_fn write; } das_bus;
enum { DAS_EMPTY=0, DAS_OK=1, DAS_UNSUPPORTED=-1, DAS_BAD_BLOCK=-2, DAS_QUEUE_FULL=-3 };

/* Call from one owning CPU only. DATA advances INDEX in 32-bit words:
 * low 16 bits = earlier sample, high 16 bits = next sample. */
static inline int das_read_block(const das_bus *b, das_audio_block *out)
{
    uint32_t status, bank, i, word, seq0;
    if (b->read(b->ctx,DAS_R_MAGIC)!=DAS_AUDIO_MAGIC) return DAS_UNSUPPORTED;
    if (b->read(b->ctx,DAS_R_FS_NUM)!=DAS_AUDIO_FS_NUM ||
        b->read(b->ctx,DAS_R_FS_DEN)!=DAS_AUDIO_FS_DEN ||
        b->read(b->ctx,DAS_R_CHANNELS)!=DAS_AUDIO_INPUT_CHANNELS) return DAS_UNSUPPORTED;
    status=b->read(b->ctx,DAS_R_STATUS)&3u;
    if (!status) return DAS_EMPTY;
    bank=(status&1u)?0u:1u;
    /* If both ready, consume the older sequence, including uint32 wrap. */
    if (status==3u) {
        uint32_t seq1;
        b->write(b->ctx,DAS_R_SELECT,0u); seq0=b->read(b->ctx,DAS_R_SEQ);
        b->write(b->ctx,DAS_R_SELECT,1u); seq1=b->read(b->ctx,DAS_R_SEQ);
        bank=((int32_t)(seq1-seq0)<0)?1u:0u;
    }
    b->write(b->ctx,DAS_R_SELECT,bank);
    out->desc.block_seq=b->read(b->ctx,DAS_R_SEQ);
    out->desc.first_sample=b->read(b->ctx,DAS_R_FIRST_LO);
    out->desc.first_sample|=(uint64_t)b->read(b->ctx,DAS_R_FIRST_HI)<<32;
    out->desc.sample_count=b->read(b->ctx,DAS_R_LEN);
    out->desc.target_grid=b->read(b->ctx,DAS_R_TARGET);
    out->desc.grid_w=b->read(b->ctx,DAS_R_GRID_W);
    out->desc.steer_seq=b->read(b->ctx,DAS_R_STEER_SEQ);
    out->desc.flags=b->read(b->ctx,DAS_R_FLAGS);
    out->desc.dropped_samples=b->read(b->ctx,DAS_R_DROP);
    if (!out->desc.sample_count || out->desc.sample_count>DAS_AUDIO_BLOCK ||
        !out->desc.grid_w || out->desc.grid_w>32u ||
        out->desc.target_grid>=out->desc.grid_w*out->desc.grid_w) return DAS_BAD_BLOCK;
    b->write(b->ctx,DAS_R_INDEX,0u);
    for (i=0;i<out->desc.sample_count;i+=2u) {
        word=b->read(b->ctx,DAS_R_DATA);
        out->pcm[i]=(int16_t)(uint16_t)word;
        if(i+1u<out->desc.sample_count) out->pcm[i+1u]=(int16_t)(uint16_t)(word>>16);
    }
    if (b->read(b->ctx,DAS_R_SEQ)!=out->desc.block_seq) return DAS_BAD_BLOCK;
    /* All samples now live in PS memory. Classification does not hold the PL bank. */
    b->write(b->ctx,DAS_R_ACK_SEQ,out->desc.block_seq);
    b->write(b->ctx,DAS_R_RELEASE,1u);
    return DAS_OK;
}

typedef struct {
    double samples[DAS_AUDIO_SEGMENT];
    das_block_desc desc; /* first sample/target; flags aggregated over the segment */
    uint32_t count, ticket;
    unsigned state; /* 0 free, 1 filling, 2 ready, 3 consumer-owned */
} das_segment;
typedef struct {
    das_segment slots[2];
    uint64_t next_sample;
    uint32_t next_seq, steer_seq, target_grid, grid_w, source, ticket;
    unsigned have_previous;
    uint32_t discontinuities, dropped_samples;
} das_segment_queue;
/* One producer (CPU0), one consumer (CPU1). Payload memory must be coherent:
 * the board reserves a whole aligned noncached DDR section for this queue. */
static inline unsigned das_slot_state(const das_segment *s)
{ return __atomic_load_n(&s->state,__ATOMIC_ACQUIRE); }
static inline void das_slot_publish(das_segment *s,unsigned state)
{ __atomic_store_n(&s->state,state,__ATOMIC_RELEASE); }
static inline void das_queue_init(das_segment_queue *q) { memset(q,0,sizeof *q); }
static inline void das_queue_break(das_segment_queue *q)
{
    unsigned j;
    for(j=0;j<2;j++) if(das_slot_state(&q->slots[j])==1u) {
        q->slots[j].count=0;das_slot_publish(&q->slots[j],0);
    }
    q->have_previous=0; q->discontinuities++;
}
static inline int das_queue_push(das_segment_queue *q, const das_audio_block *b)
{
    unsigned j; uint32_t i;
    const das_block_desc *d=&b->desc;
    if(!d->sample_count || d->sample_count>DAS_AUDIO_BLOCK || !d->grid_w ||
       d->grid_w>32u || d->target_grid>=d->grid_w*d->grid_w) return DAS_BAD_BLOCK;
    if(d->flags&DAS_FLAG_INVALID) {das_queue_break(q); return DAS_BAD_BLOCK;}
    if((d->flags&DAS_FLAG_GAP) || (q->have_previous &&
       (d->first_sample!=q->next_sample || d->block_seq!=q->next_seq ||
        d->steer_seq!=q->steer_seq || d->target_grid!=q->target_grid ||
        d->grid_w!=q->grid_w || (d->flags&DAS_FLAG_SYNTHETIC)!=q->source))) das_queue_break(q);
    for(i=0;i<d->sample_count;i++) {
        das_segment *s=0;
        for(j=0;j<2;j++) if(das_slot_state(&q->slots[j])==1u) {s=&q->slots[j];break;}
        if(!s) for(j=0;j<2;j++) if(das_slot_state(&q->slots[j])==0u) {
            s=&q->slots[j];s->count=0;s->desc=*d;
            s->desc.first_sample=d->first_sample+i;s->desc.flags=d->flags;
            das_slot_publish(s,1);
            break;
        }
        if(!s) {
            /* Preserve completed segments; explicitly count the unaccepted tail. */
            q->dropped_samples+=d->sample_count-i;
            das_queue_break(q);return DAS_QUEUE_FULL;
        }
        s->samples[s->count++]=(double)b->pcm[i]/32768.0;
        s->desc.flags|=d->flags;
        s->desc.dropped_samples=d->dropped_samples;
        if(s->count==DAS_AUDIO_SEGMENT) {
            s->desc.sample_count=DAS_AUDIO_SEGMENT;s->ticket=q->ticket++;das_slot_publish(s,2);
        }
    }
    q->next_sample=d->first_sample+d->sample_count;q->next_seq=d->block_seq+1u;
    q->steer_seq=d->steer_seq;q->target_grid=d->target_grid;q->grid_w=d->grid_w;
    q->source=d->flags&DAS_FLAG_SYNTHETIC;q->have_previous=1;
    return DAS_OK;
}
static inline das_segment *das_queue_take(das_segment_queue *q)
{
    das_segment *s=0;unsigned j;
    for(j=0;j<2;j++) if(das_slot_state(&q->slots[j])==2u &&
        (!s || (int32_t)(q->slots[j].ticket-s->ticket)<0)) s=&q->slots[j];
    if(s) das_slot_publish(s,3);
    return s;
}
static inline void das_queue_release(das_segment *s) { s->count=0;das_slot_publish(s,0); }
/* Only producer uses push/break; only consumer uses take/release. Init before both start. */
#endif
