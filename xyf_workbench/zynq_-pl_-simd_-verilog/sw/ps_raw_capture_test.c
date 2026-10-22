#include <assert.h>
#include <stdio.h>
#include "ps_raw_capture.h"
static uint32_t regs[128],address,bank,index,command,reads;
static int expire;
static uint32_t sample(unsigned frame,unsigned channel)
{return (uint16_t)(int16_t)((frame*97+channel*311)%65536-32768);}
static uint32_t read_bus(void *ctx,uint32_t off)
{
    (void)ctx;
    if(off==0x88)return regs[(address++-0x80000a00u)&127];
    if(off==0x320) {
        unsigned pairs=regs[RAW_RESULT_CHANNELS]/2,frame=bank*512+index/pairs,ch=2*(index%pairs);
        reads++;
        if(expire&&reads==17)regs[RAW_RESULT_STATE]=RAW_ABORTED;
        return sample(frame,ch)|(sample(frame,ch+1)<<16);
    }
    return 0;
}
static void write_bus(void *ctx,uint32_t off,uint32_t value)
{
    (void)ctx;
    if(off==0x80)address=value;
    else if(off==0x3c)command=value;
    else if(off==0x30c)bank=value;
    else if(off==0x31c)index=value;
    else assert(0);
}
static raw_capture_receiver receiver;
static void ready(unsigned channels)
{
    regs[RAW_RESULT_REQUEST]=receiver.request;regs[RAW_RESULT_STATE]=RAW_READY;
    regs[RAW_RESULT_CHANNELS]=channels;regs[RAW_RESULT_FRAMES]=1024;
    regs[RAW_RESULT_FS_NUM]=78125;regs[RAW_RESULT_FS_DEN]=2;
    regs[RAW_RESULT_FIRST]=0xfffffc00u;regs[RAW_RESULT_BANK_SEQ]=0xffffffffu;
    regs[RAW_RESULT_END_SEQ]=0;
}
static uint32_t le32(const uint8_t *p)
{return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24);}
int main(void)
{
    das_bus bus={0,read_bus,write_bus};
    assert(raw_capture_start(&receiver,&bus,0)==-2);
    regs[RAW_RESULT_MAGIC]=RAW_CAPTURE_MAGIC;
    unsigned sizes[]={8,12,16};
    for(unsigned n=0;n<3;n++) {
        assert(raw_capture_start(&receiver,&bus,100)==0);
        assert(command==(RAW_REQUEST|receiver.id));
        assert(raw_capture_start(&receiver,&bus,100)==-1);
        raw_capture_poll(&receiver,&bus,101);assert(receiver.state==1);
        ready(sizes[n]);reads=0;
        for(unsigned calls=0;receiver.state!=3&&calls<300;calls++) {
            uint32_t before=reads;raw_capture_poll(&receiver,&bus,102+calls);
            assert(reads-before<=32);assert(command==(receiver.state==3?(RAW_RELEASE|receiver.id):receiver.request));
        }
        assert(receiver.state==3);assert(receiver.length==64+sizes[n]*2048);
        assert(le32(receiver.file)==RAW_CAPTURE_MAGIC&&le32(receiver.file+28)==0xfffffc00u);
        for(unsigned frame=0;frame<1024;frame++)for(unsigned ch=0;ch<sizes[n];ch++) {
            const uint8_t *p=receiver.file+64+2*(frame*sizes[n]+ch);
            assert(((uint32_t)p[0]|((uint32_t)p[1]<<8))==sample(frame,ch));
        }
    }
    assert(raw_capture_start(&receiver,&bus,100)==0);ready(12);expire=1;reads=0;
    raw_capture_poll(&receiver,&bus,101);assert(receiver.state==4&&receiver.length==0);
    assert(command==(RAW_CANCEL|receiver.id));expire=0;
    assert(raw_capture_start(&receiver,&bus,0xfffffff0u)==0);
    raw_capture_poll(&receiver,&bus,2010);assert(receiver.state==4&&receiver.error==1);
    assert(raw_capture_start(&receiver,&bus,0)==0);ready(7);
    raw_capture_poll(&receiver,&bus,1);assert(receiver.state==4&&receiver.error==3);
    printf("RAW_CAPTURE_PS_PASS channels=8,12,16 exact_samples=36864 timeout=1 generation_change=1 invalid_metadata=1 work_bound=32\n");
    return 0;
}
