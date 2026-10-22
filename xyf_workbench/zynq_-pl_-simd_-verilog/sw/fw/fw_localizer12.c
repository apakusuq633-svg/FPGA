#include <stdint.h>
#define REG(b,i) (*(volatile uint32_t *)((b)+4u*(i)))
#define LOC(i) REG(0xd000u,i)
#define CAP(i) REG(0xc000u,i)
#define SRP(i) REG(0x8000u,i)
#define RESULT(i) REG(0x2800u,i)
#ifndef FW_LOCALIZER_WINDOWS
#define FW_LOCALIZER_WINDOWS 4u
#endif

/* TEST_GEOMETRY_ONLY. Transfers never issue a compute operation. */
/* Keep the five-way dispatch in ITCM. A jump table would add a DTCM load to
 * every compute command; this function is built with the project GNU toolchain. */
__attribute__((optimize("no-jump-tables")))
int main(void) {
    uint32_t ticket=0,completed=0,epoch=LOC(13);
    RESULT(0)=0x4c4f4301u;RESULT(1)=0;RESULT(3)=0;
    LOC(0)=0;SRP(0)=2;CAP(0)=1;
    LOC(0)=0x80000001u;
#if FW_LOCALIZER_WINDOWS == 0
    while(1) {
#else
    while(completed<FW_LOCALIZER_WINDOWS) {
#endif
        uint32_t id=LOC(2),kind=0;
        /* The RTL increments the request ticket on each RUN entry and keeps
         * it across recovery. Read kind/coherence only for a new ticket. */
        if(id!=ticket) {
            kind=(LOC(1)>>1)&7u;
            if(id!=LOC(2))continue;
        }
        if(kind&&id!=ticket) {
            ticket=id;
            switch(kind) {
            case 1:__asm__ volatile(".insn r 0x0b,7,0x50,x0,x0,x0":::"memory");break;
            case 2:__asm__ volatile(".insn r 0x0b,7,0x70,x0,x0,x0":::"memory");break;
            case 3:__asm__ volatile(".insn r 0x0b,6,0,x0,x0,x0":::"memory");break;
            case 4:__asm__ volatile(".insn r 0x0b,5,0,x0,x0,x0":::"memory");break;
            case 5:__asm__ volatile(".insn r 0x2b,0,0,x0,x0,x0":::"memory");break;
            default:RESULT(3)=1;break;
            }
        }
        if(LOC(6)||LOC(7)){
            RESULT(3)=2;
            // Recovery is explicitly requested through D030 or the PS test control.
            // Do not clear sticky faults or erase the first-fault history here.
            while(LOC(13)==epoch){}
            while(LOC(6)||LOC(7)){}
            epoch=LOC(13);completed=0;RESULT(3)=0;
        }
        uint32_t window=LOC(3);
        if(window!=completed) {
            if(window!=completed+1u){RESULT(3)=3;break;}
            RESULT(4)=LOC(4);RESULT(5)=LOC(5);RESULT(6)=LOC(8);RESULT(7)=LOC(9);
            completed=window;RESULT(1)=completed;
        }
    }
    LOC(0)=0;CAP(0)=0;
    REG(0x4000u,0)=RESULT(3)?0x4c4f43ffu:0x4c4f4302u;
    for(;;){}
}
