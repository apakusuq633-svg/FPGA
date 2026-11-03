#include <stdint.h>
#include "fw_fft.h"
#include "fw_cycle_profile.h"
#include "fw_gcc.h"
#include "fw_location_quality.h"
#include "fw_prepare_fused.h"
#ifndef FW_PREPARE_FUSED
#define FW_PREPARE_FUSED 0
#endif
#ifndef FW_ARRAY_CHANNELS
#define FW_ARRAY_CHANNELS 8
#endif
#ifndef FW_GEOMETRY_CONFIRMED
#define FW_GEOMETRY_CONFIRMED 0
#endif
#define ARRAY_PAIRS (FW_ARRAY_CHANNELS*(FW_ARRAY_CHANNELS-1)/2)
#define REG(base,i) (*(volatile uint32_t *)((base)+4u*(i)))
#define CAP(i) REG(0xc000u,i)
#define SRP(i) REG(0x8000u,i)
#define STEER(i) REG(0xa000u,i)
#define RESULT(i) REG(0x2800u,i)
#define CACHE ((int16_t *)0x10000u)
#define FRAME ((int16_t *)0x19000u)
#define CORR ((int16_t *)0x19800u)
#define SCORES ((int32_t *)0x1a000u)
#define MAILBOX REG(0x4000u,0)
#ifndef FW_NUMERIC66
#define FW_NUMERIC66 0
#endif
static uint32_t stats[FW_ARRAY_CHANNELS][5],mic_seq,loc_seq,frames;
#if FW_DETAIL_PROFILE
uint32_t fw_capture_detail[4],fw_prepare_detail[5];
#endif
#if FW_CYCLE_PROFILE
static uint32_t profile[FW_ARRAY_CHANNELS][5];
static uint32_t profile_seq,cycle_baseline;
static void publish_profile(void) {
    RESULT(128)=++profile_seq;
    RESULT(129)=0x43595031u; /* CYP1 */
    RESULT(130)=frames+1;RESULT(131)=FW_ARRAY_CHANNELS;
    RESULT(132)=cycle_baseline;RESULT(133)=5;
    for(unsigned ch=0;ch<FW_ARRAY_CHANNELS;ch++)
        for(unsigned k=0;k<5;k++)RESULT(134+ch*5+k)=profile[ch][k];
    RESULT(128)=++profile_seq;
}
#endif
static location_tracker tracker;
static inline uint32_t cycles(void) {uint32_t v;__asm__ volatile("rdcycle %0":"=r"(v));return v;}
static int idle(uint32_t base) {
    for(unsigned n=0;n<2000000;n++)if(!(REG(base,1)&1u))return 0;
    return 1;
}
#include "fw_capture_pair.h"
#include "fw_raw_capture.h"
static void channel_pair(unsigned ch) {
    MEM_PHASE(1);
    int16_t *second=(int16_t *)0x1b000u;
#if FW_CYCLE_PROFILE
    uint32_t t0=read_cycles();
#endif
    capture_pair(ch,FW_ARRAY_CHANNELS,stats,
                 (FW_GEOMETRY_CONFIRMED || FW_CYCLE_PROFILE)?FRAME:0,second);
#if FW_CYCLE_PROFILE
    uint32_t t1=read_cycles();
    /* Shared pair cost counted once; odd channel capture remains zero. */
    profile[ch][0]=t1-t0;profile[ch+1][0]=0;
#endif
    if(FW_GEOMETRY_CONFIRMED || FW_CYCLE_PROFILE) {
        for(unsigned k=0;k<2;k++) {
#if FW_CYCLE_PROFILE
            uint32_t p0=read_cycles();
#endif
            int16_t *input=k?second:FRAME;
            MEM_PHASE(2);
            if(FW_PREPARE_FUSED) {
                prepare_fused(input,(int32_t)stats[ch+k][0]);gcc_spectrum_windowed(input,CACHE+(ch+k)*1026);
            } else {location_prepare(input,1024);gcc_spectrum(input,CACHE+(ch+k)*1026);}
#if FW_CYCLE_PROFILE
            uint32_t p1=read_cycles();
            profile[ch+k][1]=(p1-p0)-fw_fft_profile[0]-fw_fft_profile[1]-fw_fft_profile[2];
            for(unsigned j=0;j<3;j++)profile[ch+k][j+2]=fw_fft_profile[j];
#endif
        }
    }
}
int main(void) {
    MEM_PHASE(0);
#if FW_CYCLE_PROFILE
    uint32_t b0=read_cycles(),b1=read_cycles();cycle_baseline=b1-b0;
    RESULT(128)=0;RESULT(129)=0;
    RESULT(230)=FW_DETAIL_PROFILE;
#endif
    RESULT(0)=FW_ARRAY_CHANNELS==8 ? (FW_GEOMETRY_CONFIRMED?0xda508002u:0xda508001u) : FW_ARRAY_CHANNELS==12 ? (FW_GEOMETRY_CONFIRMED?0xda512002u:0xda512001u) : 0xda516002u;
    RESULT(1)=0;RESULT(3)=0;
    RESULT(88)=0;RESULT(89)=0;RESULT(90)=0;RESULT(91)=0;
    RESULT(92)=32;RESULT(93)=0;RESULT(94)=0;RESULT(95)=FW_GEOMETRY_CONFIRMED;
    RESULT(LOCATION_META16_WORD)=0;
    RESULT(RAW_RESULT_STATE)=RAW_IDLE;RESULT(RAW_RESULT_REQUEST)=0;
    RESULT(RAW_RESULT_MAGIC)=RAW_CAPTURE_MAGIC;
    if((SRP(7)>>16)!=0x12u || CAP(31)!=0x41435303u) {RESULT(3)=5;MAILBOX=0xda5f0005u;for(;;){} }
    SRP(0)=2;STEER(0)=2;STEER(6)=0x00030340;
    CAP(0)=1;CAP(2)=512;MAILBOX=0xda500001u;
    uint32_t raw_seen=0;
    for(;;) {
        MEM_PHASE(0);
        uint32_t start=cycles();CAP(0)=7;
        unsigned n;
        for(n=0;n<1000000;n++)if((CAP(1)&3u)==3u)break;
        if(n==1000000) {RESULT(3)=1;break;}
        CAP(3)=0;uint32_t first0=CAP(5),seq0=CAP(4);
        CAP(3)=1;uint32_t first1=CAP(5),seq1=CAP(4);
        if(first1-first0!=512 || seq1-seq0!=1) {RESULT(3)=2;break;}
        uint32_t raw_request=REG(0x4000u,1);
        if((raw_request&RAW_COMMAND_MASK)==RAW_REQUEST && raw_request!=raw_seen) {
            raw_seen=raw_request;raw_capture_hold(raw_request,first0,seq0,FW_ARRAY_CHANNELS);
            tracker.known=0;tracker.count=0;continue;
        }
        uint32_t compute=cycles();
#if FW_DETAIL_PROFILE
        for(unsigned k=0;k<4;k++)fw_capture_detail[k]=0;
        for(unsigned k=0;k<5;k++)fw_prepare_detail[k]=0;
#endif
        for(unsigned ch=0;ch<FW_ARRAY_CHANNELS;ch+=2)channel_pair(ch);
#if FW_DETAIL_PROFILE
        for(unsigned k=0;k<4;k++)RESULT(226+k)=fw_capture_detail[k];
        for(unsigned k=0;k<5;k++)RESULT(220+k)=fw_prepare_detail[k];
#endif
#if FW_CYCLE_PROFILE
        publish_profile();
#endif
#if FW_NUMERIC66
        /* Geometry-free diagnostic workload; never publishes a direction. */
        RESULT(196)=0;RESULT(197)=frames+1;
        unsigned audit_pair=0;uint32_t audit_start=read_cycles();
        for(unsigned a=0;a<12;a++)for(unsigned b=a+1;b<12;b++,audit_pair++) {
            MEM_PHASE(6);
            uint32_t p0=read_cycles();
            gcc_cached_ring(CACHE+a*1026,CACHE+b*1026,CORR);
            RESULT(198)=read_cycles()-p0;
#if FW_TEST_SRP
            MEM_PHASE(9);
            p0=read_cycles();SRP(2)=0x20000u+audit_pair*32;
            for(unsigned k=0;k<32;k++)SRP(3)=(uint16_t)CORR[k<16?k:k+992];
            RESULT(202)=read_cycles()-p0;
#endif
            for(unsigned k=0;k<5;k++)RESULT(208+k)=fw_gcc_profile[k];
            for(unsigned k=0;k<3;k++)RESULT(213+k)=fw_ifft_profile[k];
            MEM_PHASE(8);
            p0=read_cycles();gcc_audit_phi((int16_t *)0x1d000u);RESULT(201)=read_cycles()-p0;
            p0=read_cycles();
            ifft512_real_hw((int16_t *)0x1d000u,FRAME);
            RESULT(199)=read_cycles()-p0;
            RESULT(196)=audit_pair+1;
        }
        RESULT(200)=read_cycles()-audit_start;
#if FW_TEST_SRP
        MEM_PHASE(9);
        uint32_t srp_start=read_cycles();SRP(0)=3;
        if(idle(0x8000u)||(SRP(1)&8u)){RESULT(3)=3;break;}
        RESULT(203)=read_cycles()-srp_start;RESULT(204)=SRP(6);
        srp_start=read_cycles();SRP(2)=0x40000u;(void)SRP(1);
        int32_t best_test=INT32_MIN;unsigned grid_test=0;
        for(unsigned g=0;g<1024;g++){
            int32_t p=(int32_t)SRP(4);SCORES[g]=p;
            if(p>best_test){best_test=p;grid_test=g;}
        }
        RESULT(205)=read_cycles()-srp_start;
        RESULT(206)=grid_test;RESULT(207)=(uint32_t)best_test;
        RESULT(231)=0x54455354u; /* TEST only; no steering update. */
#endif
#endif
        RESULT(88)=++mic_seq;
        for(unsigned ch=0;ch<FW_ARRAY_CHANNELS;ch++)for(unsigned k=0;k<5;k++)RESULT(8+5*ch+k)=stats[ch][k];
        RESULT(88)=++mic_seq;RESULT(89)=FW_ARRAY_CHANNELS==8?0x4d493038u:FW_ARRAY_CHANNELS==12?0x4d493132u:0x4d493136u;
        if(!FW_GEOMETRY_CONFIRMED) {
            RESULT(91)=0;RESULT(4)=cycles()-compute;RESULT(5)=cycles()-start;
            RESULT(93)=first0;RESULT(1)=++frames;
            continue;
        }
        unsigned pair=0;
        for(unsigned a=0;a<FW_ARRAY_CHANNELS;a++)for(unsigned b=a+1;b<FW_ARRAY_CHANNELS;b++,pair++) {
            gcc_cached_ring(CACHE+a*1026,CACHE+b*1026,CORR);
            SRP(2)=0x20000u+pair*32;
            /* Ring indices 16..31 retain original negative lags -16..-1. */
            for(unsigned k=0;k<32;k++)SRP(3)=(uint16_t)CORR[k<16?k:k+992];
        }
        SRP(0)=3;
        if(idle(0x8000u)||(SRP(1)&8u)) {RESULT(3)=3;break;}
        SRP(2)=0x40000u;(void)SRP(1);
        int32_t best=(int32_t)SRP(4),second=INT32_MIN;unsigned grid=0;
        SCORES[0]=best;
        for(unsigned g=1;g<1024;g++) {
            int32_t p=(int32_t)SRP(4);
            SCORES[g]=p;
            if(p>best){second=best;best=p;grid=g;}else if(p>second)second=p;
        }
        RESULT(90)=++loc_seq;RESULT(91)=0;
        RESULT(2)=grid;RESULT(6)=(uint32_t)best;RESULT(7)=(uint32_t)second;
        uint32_t contrast;int32_t nonlocal;
        uint32_t reason=location_map_reason(SCORES,32,ARRAY_PAIRS,grid,&contrast,&nonlocal);
        for(unsigned ch=0;ch<FW_ARRAY_CHANNELS;ch++)reason|=location_input_reason((int32_t)stats[ch][0],
            (uint64_t)stats[ch][1]+((uint64_t)stats[ch][2]<<32),stats[ch][4]);
        unsigned raw_grid=grid;
        reason=location_track(&tracker,raw_grid,32,reason);grid=tracker.grid;RESULT(2)=grid;
        RESULT(LOCATION_META16_WORD)=LOCATION_QUALITY_MAGIC;
        RESULT(LOCATION_META16_WORD+1)=reason;RESULT(LOCATION_META16_WORD+2)=contrast;
        RESULT(LOCATION_META16_WORD+3)=raw_grid;RESULT(LOCATION_META16_WORD+4)=(uint32_t)nonlocal;
        RESULT(LOCATION_META16_WORD+5)=tracker.accepted;RESULT(LOCATION_META16_WORD+6)=tracker.rejected;
        RESULT(LOCATION_META16_WORD+7)=best>0?(uint32_t)best/ARRAY_PAIRS:0;
        if(!reason) {
            STEER(5)=grid;
            if(idle(0xa000u)||(STEER(1)&8u)) {RESULT(3)=4;break;}
            RESULT(91)=1;
        }
        RESULT(4)=cycles()-compute;RESULT(5)=cycles()-start;
        RESULT(93)=first0;RESULT(94)=STEER(1);RESULT(1)=++frames;
        RESULT(90)=++loc_seq;
    }
    MAILBOX=0xda5f0000u+RESULT(3);for(;;){}
}
