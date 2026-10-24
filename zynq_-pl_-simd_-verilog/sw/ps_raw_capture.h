#ifndef PS_RAW_CAPTURE_H
#define PS_RAW_CAPTURE_H
#include <string.h>
#include "ps_das_audio.h"
#include "raw_capture_protocol.h"

typedef struct {
    uint32_t state,request,id,first,bank_sequence,channels,word,started_ms,error,length;
    uint8_t file[RAW_FILE_MAX];
} raw_capture_receiver;
/* Receiver states: 0 idle, 1 requested, 2 copying, 3 complete, 4 error. */
static inline uint32_t raw_result_read(const das_bus *b,unsigned word)
{
    b->write(b->ctx,0x80,0x80000a00u+word);
    return b->read(b->ctx,0x88);
}
static inline void raw_put32(uint8_t *p,uint32_t value)
{for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(value>>(8*i));}
static inline int raw_capture_start(raw_capture_receiver *r,const das_bus *b,uint32_t now_ms)
{
    if(r->state==1||r->state==2)return -1;
    if(raw_result_read(b,RAW_RESULT_MAGIC)!=RAW_CAPTURE_MAGIC)return -2;
    r->id=(r->id+1)&RAW_ID_MASK;if(!r->id)r->id=1;
    r->request=RAW_REQUEST|r->id;r->state=1;r->started_ms=now_ms;
    r->error=0;r->word=0;r->length=0;
    b->write(b->ctx,0x3c,r->request);
    return 0;
}
static inline void raw_capture_fail(raw_capture_receiver *r,const das_bus *b,uint32_t reason)
{b->write(b->ctx,0x3c,RAW_CANCEL|r->id);r->state=4;r->error=reason;r->length=0;}
static inline void raw_capture_poll(raw_capture_receiver *r,const das_bus *b,uint32_t now_ms)
{
    if(r->state!=1&&r->state!=2)return;
    if(now_ms-r->started_ms>=2000u){raw_capture_fail(r,b,1);return;}
    uint32_t request=raw_result_read(b,RAW_RESULT_REQUEST),state=raw_result_read(b,RAW_RESULT_STATE);
    if(request!=r->request)return;
    if(state==RAW_ABORTED){raw_capture_fail(r,b,2);return;}
    if(state!=RAW_READY)return;
    if(r->state==1) {
        r->channels=raw_result_read(b,RAW_RESULT_CHANNELS);
        r->first=raw_result_read(b,RAW_RESULT_FIRST);
        r->bank_sequence=raw_result_read(b,RAW_RESULT_BANK_SEQ);
        if((r->channels!=8&&r->channels!=10&&r->channels!=12&&r->channels!=16)||
           raw_result_read(b,RAW_RESULT_FRAMES)!=1024||
           raw_result_read(b,RAW_RESULT_END_SEQ)-r->bank_sequence!=1||
           raw_result_read(b,RAW_RESULT_FS_NUM)!=78125||raw_result_read(b,RAW_RESULT_FS_DEN)!=2) {
            raw_capture_fail(r,b,3);return;
        }
        memset(r->file,0,RAW_FILE_HEADER);
        raw_put32(r->file,RAW_CAPTURE_MAGIC);raw_put32(r->file+4,RAW_FILE_HEADER);
        raw_put32(r->file+8,r->id);raw_put32(r->file+12,r->channels);
        raw_put32(r->file+16,1024);raw_put32(r->file+20,78125);raw_put32(r->file+24,2);
        raw_put32(r->file+28,r->first);raw_put32(r->file+32,r->bank_sequence);
        raw_put32(r->file+36,16); /* signed little-endian int16, frame-major */
        r->state=2;
    }
    unsigned pairs=r->channels/2u,bank_words=512u*pairs,total=2u*bank_words;
    /* Bounded work keeps audio reception and lwIP polling active. */
    for(unsigned count=0;count<32&&r->word<total;count++,r->word++) {
        unsigned bank=r->word/bank_words,index=r->word%bank_words;
        b->write(b->ctx,0x30c,bank);b->write(b->ctx,0x31c,index);
        (void)b->read(b->ctx,0x304);
        uint32_t data=b->read(b->ctx,0x320);
        raw_put32(r->file+RAW_FILE_HEADER+4u*r->word,data);
    }
    /* Producer can time out during a copy; never publish a mixed snapshot. */
    if(raw_result_read(b,RAW_RESULT_REQUEST)!=r->request||raw_result_read(b,RAW_RESULT_STATE)!=RAW_READY) {
        raw_capture_fail(r,b,4);return;
    }
    if(r->word==total) {
        r->length=RAW_FILE_HEADER+4u*total;
        b->write(b->ctx,0x3c,RAW_RELEASE|r->id);r->state=3;
    }
}
#endif
