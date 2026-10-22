/* CPU owns custom compute dispatch and direction validation; RTL moves samples. */
#include <stdint.h>
#include "fw_location_quality.h"
#define REG(b,i) (*(volatile uint32_t *)((b)+4u*(i)))
#define LOC(i) REG(0xd000u,i)
#define CAP(i) REG(0xc000u,i)
#define SRP(i) REG(0x8000u,i)
#define STEER(i) REG(0xa000u,i)
#define RESULT(i) REG(0x2800u,i)
#define SCORES ((int32_t *)0x1a000u)
static uint32_t loc_seq,mic_seq;
static inline uint32_t cycles(void){return read_cycles();}
#include "fw_raw_capture.h"
static location_tracker tracker;
static uint32_t stats[8][5];
static int idle(uint32_t base){
    for(unsigned n=0;n<2000000;n++)if(!(REG(base,1)&1u))return 0;
    return 1;
}

/* Each RUN is still an RV32 custom instruction, not an RTL compute trigger. */
__attribute__((optimize("no-jump-tables")))
int main(void){
    uint32_t ticket=0,completed=0,frames=0,epoch=LOC(13),raw_seen=0;
    RESULT(0)=0xda508002u;RESULT(1)=0;RESULT(3)=0;
    RESULT(88)=0;RESULT(89)=0x4d493038u;RESULT(90)=0;RESULT(91)=0;
    RESULT(92)=32;RESULT(93)=0;RESULT(94)=0;RESULT(95)=1;
    RESULT(LOCATION_META16_WORD)=0;
    RESULT(RAW_RESULT_STATE)=RAW_IDLE;RESULT(RAW_RESULT_REQUEST)=0;
    RESULT(RAW_RESULT_MAGIC)=RAW_CAPTURE_MAGIC;
    if(LOC(10)!=0x4c4f4301u || LOC(24)!=0x50384f31u || CAP(31)!=0x41435303u){RESULT(3)=5;goto stop;}
    LOC(0)=0;SRP(0)=2;STEER(0)=2;STEER(6)=0x00030340;
    CAP(0)=1;CAP(2)=512;LOC(0)=0x80000001u;
    REG(0x4000u,0)=0xda500001u;
    for(;;){
        uint32_t id=LOC(2);
        if(id!=ticket){
            unsigned kind=(LOC(1)>>1)&7u;
            if(id!=LOC(2))continue;
            if(kind){
                ticket=id;
                switch(kind){
                case 1:__asm__ volatile(".insn r 0x0b,7,0x50,x0,x0,x0":::"memory");break;
                case 2:__asm__ volatile(".insn r 0x0b,7,0x70,x0,x0,x0":::"memory");break;
                case 3:__asm__ volatile(".insn r 0x0b,6,0,x0,x0,x0":::"memory");break;
                case 4:__asm__ volatile(".insn r 0x0b,5,0,x0,x0,x0":::"memory");break;
                case 5:__asm__ volatile(".insn r 0x2b,0,0,x0,x0,x0":::"memory");break;
                default:RESULT(3)=1;goto stop;
                }
            }
        }
        if(LOC(6)||LOC(7)){
            RESULT(3)=2;RESULT(91)=0;
            /* Preserve sticky faults; explicit PS recovery owns rearming. */
            while(LOC(13)==epoch){}
            while(LOC(6)||LOC(7)){}
            epoch=LOC(13);completed=0;tracker.known=0;tracker.count=0;
            RESULT(3)=0;
        }
        uint32_t window=LOC(3);
        if(window==completed)continue;
        if(window!=completed+1u || (LOC(1)&1u)){RESULT(3)=6;goto stop;}
        uint32_t post_start=cycles(),first=LOC(4),compute=LOC(11),latency=LOC(5);
        for(unsigned ch=0;ch<8;ch++)for(unsigned k=0;k<5;k++){
            LOC(19)=ch*5+k;stats[ch][k]=LOC(20);
        }
        int32_t best=INT32_MIN,second=INT32_MIN;unsigned grid=0;
        for(unsigned g=0;g<1024;g++){
            LOC(21)=g;(void)LOC(21);
            int32_t score=(int32_t)LOC(22);SCORES[g]=score;
            if(score>best){second=best;best=score;grid=g;}
            else if(score>second)second=score;
        }
        if(LOC(3)!=window || (LOC(1)&1u)){RESULT(3)=6;goto stop;}
        uint32_t contrast;int32_t nonlocal;
        uint32_t reason=location_map_reason(SCORES,32,28,grid,&contrast,&nonlocal);
        for(unsigned ch=0;ch<8;ch++)reason|=location_input_reason((int32_t)stats[ch][0],
            (uint64_t)stats[ch][1]+((uint64_t)stats[ch][2]<<32),stats[ch][4]);
        unsigned raw_grid=grid;
        reason=location_track(&tracker,raw_grid,32,reason);grid=tracker.grid;
        RESULT(88)=++mic_seq;
        for(unsigned ch=0;ch<8;ch++)for(unsigned k=0;k<5;k++)RESULT(8+ch*5+k)=stats[ch][k];
        RESULT(88)=++mic_seq;
        RESULT(90)=++loc_seq;RESULT(91)=0;
        RESULT(2)=grid;RESULT(6)=(uint32_t)best;RESULT(7)=(uint32_t)second;
        RESULT(96)=LOCATION_QUALITY_MAGIC;RESULT(97)=reason;RESULT(98)=contrast;
        RESULT(99)=raw_grid;RESULT(100)=(uint32_t)nonlocal;
        RESULT(101)=tracker.accepted;RESULT(102)=tracker.rejected;
        RESULT(103)=best>0?(uint32_t)best/28:0;
        if(!reason){
            STEER(5)=grid;
            if(idle(0xa000u)||(STEER(1)&8u)){RESULT(3)=4;goto stop;}
            RESULT(91)=1;
        }
        uint32_t post=cycles()-post_start;
        RESULT(4)=compute+post;RESULT(5)=latency+post;
        RESULT(93)=first;RESULT(94)=STEER(1);
        RESULT(232)=compute;RESULT(233)=post;RESULT(234)=window;
        RESULT(1)=++frames;RESULT(90)=++loc_seq;
        completed=window;
        /* Existing raw snapshot protocol explicitly pauses localization. */
        uint32_t request=REG(0x4000u,1);
        if((request&RAW_COMMAND_MASK)==RAW_REQUEST && request!=raw_seen){
            raw_seen=request;LOC(0)=0;CAP(0)=7;
            unsigned n;for(n=0;n<2000000;n++)if((CAP(1)&3u)==3u)break;
            if(n==2000000){RESULT(3)=7;goto stop;}
            CAP(3)=0;uint32_t raw_first=CAP(5),sequence=CAP(4);
            raw_capture_hold(request,raw_first,sequence,8);
            CAP(0)=1;LOC(23)=0x52535438u;
            while(LOC(3)!=0){}
            completed=0;tracker.known=0;tracker.count=0;
            LOC(0)=0x80000001u;
        }
    }
stop:
    LOC(0)=0;RESULT(91)=0;
    REG(0x4000u,0)=0xda5f0000u+RESULT(3);
    for(;;){}
}
