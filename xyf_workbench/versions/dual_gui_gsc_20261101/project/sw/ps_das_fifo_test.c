#include <assert.h>
#include <stdio.h>
#include "ps_das_fifo.h"
#include "ps_pl_live.h"
typedef struct {unsigned left,popped,error,overflow_at;uint32_t version;} fifo_mock;
static uint32_t fifo_read(void *ctx,uint32_t offset)
{
    fifo_mock *m=ctx;
    if(offset==0x39c)return m->version;
    if(offset==0x384)return ((m->left>256?256:m->left)<<3)|(m->error?4:0);
    if(offset==0x390)return m->overflow_at && m->popped>=m->overflow_at?1:0;
    assert(offset==0x38c && m->left);
    m->left--;return ((uint32_t)(uint16_t)(int16_t)((int)m->popped++-300)<<16)|123u;
}
static void no_write(void *ctx,uint32_t offset,uint32_t v) {(void)ctx;(void)offset;(void)v;assert(0);}
typedef struct {
    uint32_t itcm[8192],dtcm[8192],coeff[1024],pointer,coef_pointer;
    unsigned control,audio_enables,steer_writes,srp_writes,corrupt,profile_bad,audio_control,isa_bad;
} boot_mock;
static uint32_t boot_read(void *ctx,uint32_t offset)
{
    boot_mock *m=ctx;
    if(offset==0x39c)return DAS_FIFO_VERSION;
    if(offset==0x3c0)return UI_DAS_ACTIVE_CHANNELS;
#if UI_LIVE16_LOCALIZATION
    if(offset==0x3c4)return m->isa_bad?0:0x41435303u;
    if(offset==0x41c)return m->profile_bad?0:0x00120000u;
    if(offset==0x404)return 4;
#endif
    if(offset==4)return 4;
    if(offset==0x88) {
        unsigned index=m->pointer++&0x7fffffffu;assert(index<8192);
        return (m->pointer&0x80000000u ? m->dtcm[index]:m->itcm[index])^m->corrupt;
    }
    assert(offset==0xc8 && m->coef_pointer<1024);
    return m->coeff[m->coef_pointer++];
}
static void boot_write(void *ctx,uint32_t offset,uint32_t v)
{
    boot_mock *m=ctx;
    switch(offset) {
    case 0: m->control=v;break;
    case 0x80:m->pointer=v;break;
    case 0x84: {
        unsigned index=m->pointer&0x7fffffffu;assert(index<8192);
        if(m->pointer&0x80000000u)m->dtcm[index]=v;else m->itcm[index]=v;
        m->pointer++;break;
    }
    case 0xc0:m->coef_pointer=v&511u;break;
    case 0xc4:assert(m->coef_pointer<1024);m->coeff[m->coef_pointer++]=v;break;
    case 0x60c:m->steer_writes++;break;
    case 0x380:m->audio_control=v;if(v&1)m->audio_enables++;break;
    case 0x40c:
#if UI_LIVE16_LOCALIZATION
        assert(v==acoustic_srp_lut[m->srp_writes]);m->srp_writes++;break;
#else
        assert(0);break;
#endif
    case 0x8c:case 0x600:case 0x608:case 0x400:case 0x408:break;
    default:assert(0);
    }
}
static boot_mock boot;
static das_segment_queue queue;
int main(void)
{
    fifo_mock m={768,0,0,0,DAS_FIFO_VERSION};
    das_bus b={&m,fifo_read,no_write};das_fifo_receiver r;das_audio_block out;uint32_t drops;
    unsigned i;das_fifo_init(&r);
    assert(das_fifo_poll(&b,&r,&out,&drops)==DAS_EMPTY);
    assert(das_fifo_poll(&b,&r,&out,&drops)==DAS_OK);
    for(i=0;i<512;i++)assert(out.pcm[i]==(int)i-300);
    assert(out.desc.flags==DAS_FLAG_POSITION_UNKNOWN && out.desc.first_sample==0);
    assert(das_fifo_poll(&b,&r,&out,&drops)==DAS_EMPTY && r.count==256);
    m.left=256;
    assert(das_fifo_poll(&b,&r,&out,&drops)==DAS_OK);
    assert(out.desc.first_sample==512 && out.desc.block_seq==1);
    m.left=256;m.overflow_at=m.popped+10;
    assert(das_fifo_poll(&b,&r,&out,&drops)==DAS_BAD_BLOCK && drops==1);
    m.version=0;assert(das_fifo_poll(&b,&r,&out,&drops)==DAS_UNSUPPORTED);
    m=(fifo_mock){40448,0,0,0,DAS_FIFO_VERSION};
    das_fifo_init(&r);das_queue_init(&queue);
    while(m.left) {
        int result=das_fifo_poll(&b,&r,&out,&drops);
        assert(result==DAS_EMPTY || result==DAS_OK);
        if(result==DAS_OK)assert(das_queue_push(&queue,&out)==DAS_OK);
    }
    {
        das_segment *segment=das_queue_take(&queue);assert(segment);
        assert(segment->desc.flags&DAS_FLAG_POSITION_UNKNOWN);
        assert(segment->desc.first_sample==0 && segment->count==40000);
        assert(segment->samples[0]==-300.0/32768.0);
        assert(segment->samples[39999]==(double)(int16_t)(39999-300)/32768.0);
        das_queue_release(segment);
    }
    b.ctx=&boot;b.read=boot_read;b.write=boot_write;
    assert(pl_live_prepare(&b)==0);
    assert(!boot.audio_enables && boot.steer_writes==ACOUSTIC_STEER_LUT_WORDS);
    pl_live_start(&b);assert(boot.audio_enables==1 && boot.control==0);
#if UI_LIVE16_LOCALIZATION
    assert(boot.srp_writes==UI_DAS_ACTIVE_CHANNELS*(UI_DAS_ACTIVE_CHANNELS-1u)/2u*1024u && boot.audio_control==5);
    boot.profile_bad=1;assert(pl_live_prepare(&b)==-7);boot.profile_bad=0;
#endif
    pl_live_stop(&b);assert(boot.control==2);
    boot.corrupt=1;assert(pl_live_prepare(&b)==-3);
    puts("DAS_FIFO_PASS: signed FIR lane, partial blocks, session count, overflow rejection and PL boot/readback");
    return 0;
}
