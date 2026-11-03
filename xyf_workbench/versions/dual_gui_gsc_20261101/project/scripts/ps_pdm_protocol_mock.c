/* Host protocol model: checks ordering and ownership, not AXI bus timing. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *scenario;
static unsigned reads, epoch, selected, index_word, have_index, ack_written;
static unsigned consumed, releases, total_words, rate_seen, first_seen, errors;
static uint32_t ack_value, sequence;
static int is(const char *s) { return strcmp(scenario,s)==0; }
static unsigned ready_slot(void) { return is("refill_same_slot")?0:consumed&1; }
static uint32_t length(void) { return is("max_length")?512:is("invalid_zero")?0:is("invalid_large")?513:16; }
uint32_t Xil_In32(uintptr_t address) {
    unsigned off=(unsigned)(address-0x43c00000u); ++reads;
    if(off==0x32c) {
        if(is("dead_start")) return 0;
        uint32_t base=is("frame_wrap")?UINT32_MAX:is("restart")?epoch*10000u:0;
        if(reads<80) return base;
        first_seen=1; return base+1+(reads-80)/8;
    }
    if(off==0x304) return is("dead_bank")?0:1u<<ready_slot();
    if(off==0x310) return sequence;
    if(off==0x334||off==0x308) return length();
    if(off==0x314) return 1+consumed*16;
    if(off==0x320) {
        if(!have_index||selected!=ready_slot()||index_word!=total_words%(length()*6u)) ++errors;
        have_index=0;++total_words;
        if(is("changed_seq")&&index_word==47) ++sequence;
        return index_word&1?0x7fff8000u:0x80007fffu;
    }
    if(off==0x300) return 3;
    if(off>=0x340&&off<0x358)return 0x40004000;
    if(off==0x330)return 0xfff;
    return 0;
}
void Xil_Out32(uintptr_t address,uint32_t value) {
    unsigned off=(unsigned)(address-0x43c00000u);
    if(off==0x300) {
        if(value!=3)++errors;
        ++epoch;reads=selected=have_index=ack_written=consumed=first_seen=0;
        sequence=is("seq_wrap")?UINT32_MAX:0;
    } else if(off==0x30c)selected=value;
    else if(off==0x31c){if(have_index)++errors;index_word=value;have_index=1;}
    else if(off==0x324){ack_written=1;ack_value=value;}
    else if(off==0x328){
        if(value!=1||!ack_written||ack_value!=sequence||have_index)++errors;
        ack_written=0;
        if(!is("release_refused")){++consumed;++releases;++sequence;}
    }
}
int xil_printf(const char *s,...) {
    if(strstr(s,"FRAME_CNT advanced by")){++rate_seen;if(!first_seen)++errors;}
    return 0;
}
#define main app_main
#include APP_SOURCE
#undef main
int main(int argc,char **argv) {
    if(argc!=2)return 9;
    scenario=argv[1];
    int expect_failure=is("dead_start")||is("dead_bank")||is("invalid_zero")||is("invalid_large")||is("changed_seq")||is("release_refused");
    int rc=app_main();
    if(is("restart")){if(rc)return 8;rc=app_main();}
    if(expect_failure) {
        if(rc==0){printf("PS_PROTOCOL_DEFECT case=%s unexpected_success=1 errors=%u\n",scenario,errors);return 1;}
        if((is("invalid_zero")||is("invalid_large")||is("changed_seq"))&&releases){puts("UNSAFE_RELEASE");return 2;}
    } else if(rc||errors||releases!=(is("restart")?6u:3u)||total_words!=releases*length()*6u) {
        printf("PS_PROTOCOL_BAD case=%s rc=%d errors=%u releases=%u words=%u\n",scenario,rc,errors,releases,total_words);return 3;
    }
    if(is("dead_start")&&rate_seen)return 4;
    printf("PS_PROTOCOL_PASS case=%s app_rc=%d epochs=%u releases=%u words=%u errors=%u\n",scenario,rc,epoch,releases,total_words,errors);
    return 0;
}
