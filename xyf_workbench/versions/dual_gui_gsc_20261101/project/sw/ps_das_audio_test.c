/* Host test: two-bank PL protocol model, PCM decoding, segment continuity/ownership. */
#include <assert.h>
#include <stdio.h>
#include "ps_das_audio.h"
typedef struct {
    das_audio_block bank[2];
    uint32_t ready, selected, index, ack, reads, releases, magic;
    unsigned corrupt_seq;
} mock_pl;
static uint32_t read_reg(void *ctx,uint32_t reg)
{
    mock_pl *m=ctx;das_block_desc *d=&m->bank[m->selected].desc;
    switch(reg) {
    case DAS_R_MAGIC:return m->magic;
    case DAS_R_FS_NUM:return DAS_AUDIO_FS_NUM;
    case DAS_R_FS_DEN:return DAS_AUDIO_FS_DEN;
    case DAS_R_CHANNELS:return 8;
    case DAS_R_STATUS:return m->ready;
    case DAS_R_SEQ:return d->block_seq+(m->corrupt_seq && m->reads>0);
    case DAS_R_FIRST_LO:return (uint32_t)d->first_sample;
    case DAS_R_FIRST_HI:return (uint32_t)(d->first_sample>>32);
    case DAS_R_LEN:return d->sample_count;
    case DAS_R_TARGET:return d->target_grid;
    case DAS_R_GRID_W:return d->grid_w;
    case DAS_R_STEER_SEQ:return d->steer_seq;
    case DAS_R_FLAGS:return d->flags;
    case DAS_R_DROP:return d->dropped_samples;
    case DAS_R_DATA: {
        uint32_t i=m->index++*2u;uint32_t v;
        assert(i<d->sample_count);m->reads++;
        v=(uint16_t)m->bank[m->selected].pcm[i];
        if(i+1u<d->sample_count) v|=(uint32_t)(uint16_t)m->bank[m->selected].pcm[i+1u]<<16;
        return v;
    }
    default:assert(0);return 0;
    }
}
static void write_reg(void *ctx,uint32_t reg,uint32_t value)
{
    mock_pl *m=ctx;
    switch(reg) {
    case DAS_R_SELECT:assert(value<2u);m->selected=value;break;
    case DAS_R_INDEX:m->index=value;break;
    case DAS_R_ACK_SEQ:m->ack=value;break;
    case DAS_R_RELEASE:
        assert(value==1u);assert(m->ack==m->bank[m->selected].desc.block_seq);
        assert(m->reads>0);m->ready&=~(1u<<m->selected);m->releases++;break;
    default:assert(0);
    }
}
static void fill(das_audio_block *b,uint32_t seq,uint64_t first)
{
    unsigned i;memset(b,0,sizeof *b);
    b->desc.block_seq=seq;b->desc.first_sample=first;b->desc.sample_count=512;
    b->desc.grid_w=16;b->desc.target_grid=53;b->desc.steer_seq=7;
    for(i=0;i<512;i++) b->pcm[i]=(int16_t)((first+i)%65536u-32768u);
}
static void test_bus(void)
{
    mock_pl m;das_audio_block out;das_bus bus={&m,read_reg,write_reg};
    memset(&m,0,sizeof m);
    assert(das_read_block(&bus,&out)==DAS_UNSUPPORTED && m.reads==0 && m.releases==0);
    m.magic=DAS_AUDIO_MAGIC;assert(das_read_block(&bus,&out)==DAS_EMPTY);
    fill(&m.bank[0],0,512);fill(&m.bank[1],UINT32_MAX,0);m.ready=3;
    assert(das_read_block(&bus,&out)==DAS_OK && out.desc.block_seq==UINT32_MAX);
    assert(out.pcm[0]==-32768 && out.pcm[511]==-32257 && m.ready==1 && m.reads==256);
    assert(das_read_block(&bus,&out)==DAS_OK && out.desc.block_seq==0 && m.ready==0);
    fill(&m.bank[0],1,UINT64_C(0x100000001));m.bank[0].desc.sample_count=3;m.ready=1;m.reads=0;
    assert(das_read_block(&bus,&out)==DAS_OK && out.desc.first_sample==UINT64_C(0x100000001));
    assert(m.reads==2);
    m.ready=1;m.bank[0].desc.sample_count=513;m.reads=0;
    assert(das_read_block(&bus,&out)==DAS_BAD_BLOCK && m.ready==1 && m.reads==0);
    m.bank[0].desc.sample_count=512;m.corrupt_seq=1;
    assert(das_read_block(&bus,&out)==DAS_BAD_BLOCK && m.ready==1);
    puts("PASS: window probe, bank ordering/wrap, signed PCM, odd length, metadata and no release on invalid read");
}
static das_segment_queue q;
static void test_queue(void)
{
    das_audio_block b;das_segment *s;uint32_t seq,i;
    das_queue_init(&q);
    for(seq=0;seq<79;seq++){fill(&b,seq,(uint64_t)seq*512);assert(das_queue_push(&q,&b)==DAS_OK);}
    s=das_queue_take(&q);assert(s && s->count==40000 && s->desc.first_sample==0);
    for(i=0;i<40000;i++) assert(s->samples[i]==(double)(int16_t)(i-32768u)/32768.0);
    assert(q.slots[1].count==448); /* trailing samples retained, not silently discarded */
    for(seq=79;seq<156;seq++){fill(&b,seq,(uint64_t)seq*512);assert(das_queue_push(&q,&b)==DAS_OK);}
    fill(&b,156,156u*512u);assert(das_queue_push(&q,&b)==DAS_QUEUE_FULL);
    assert(q.dropped_samples==384);
    assert(s->samples[0]==-1.0 && s->state==3); /* consumer-owned data never overwritten */
    assert(q.slots[1].state==2);
    fill(&b,157,157u*512u);assert(das_queue_push(&q,&b)==DAS_QUEUE_FULL);
    assert(q.dropped_samples==896);das_queue_release(s);
    fill(&b,158,158u*512u);assert(das_queue_push(&q,&b)==DAS_OK);
    s=das_queue_take(&q);assert(s && s->desc.first_sample==40000);das_queue_release(s);
    das_queue_init(&q);fill(&b,0,0);assert(das_queue_push(&q,&b)==DAS_OK);
    fill(&b,2,1024);assert(das_queue_push(&q,&b)==DAS_OK);assert(q.slots[0].count==512 && q.discontinuities==1);
    fill(&b,3,1536);b.desc.steer_seq=8;assert(das_queue_push(&q,&b)==DAS_OK);assert(q.slots[0].count==512 && q.discontinuities==2);
    fill(&b,4,2048);b.desc.steer_seq=8;b.desc.flags=DAS_FLAG_SYNTHETIC;
    assert(das_queue_push(&q,&b)==DAS_OK && q.discontinuities==3);
    fill(&b,5,2560);b.desc.flags=DAS_FLAG_INVALID;
    assert(das_queue_push(&q,&b)==DAS_BAD_BLOCK && q.have_previous==0);
    puts("PASS: 40000-sample assembly, carry, PCM scaling, two-slot ownership, overflow, gaps, steering and source changes");
}
int main(void){test_bus();test_queue();puts("DAS_AUDIO_RECEIVER_PASS");return 0;}
