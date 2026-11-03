#include <stdint.h>
#include "fw_fft.h"
#include "fw_gcc.h"
#include "fw_srp.h"
#include "fw_mem.h"
#include "fw_scene.h"
#include "fw_location_quality.h"

#define CAP(i) (*(volatile uint32_t *)(0xC000u + 4u*(i)))
#define SRP(i) (*(volatile uint32_t *)(0x8000u + 4u*(i)))
#define STEER_REG(i) (*(volatile uint32_t *)(0xA000u + 4u*(i)))
#define RESULT(i) (*(volatile uint32_t *)(FW_RES_BASE + 4u*(i)))
#define MAILBOX (*(volatile uint32_t *)0x4000u)
#define FRAME ((int16_t *)FW_OUT2_BASE)
#ifdef FW_DEBUG4
static const unsigned pair_a[4]={0,0,0,1};
static const unsigned pair_b[4]={1,2,3,3};
static uint32_t mic_stats[4][5],mic_seq;
static int32_t location_scores[256];
static location_tracker tracker;
#else
static const unsigned pair_a[4]={0,0,0,0};
static const unsigned pair_b[4]={1,2,3,4};
#endif

static int wait_idle(volatile uint32_t *status)
{
    for (uint32_t n=0;n<100000u;++n) if (!(*status & 1u)) return 0;
    return 1;
}

static void load_channel(unsigned channel)
{
#ifdef FW_DEBUG4
    int32_t sum=0;uint64_t energy=0;uint32_t peak=0,clipped=0;
#endif
    for (unsigned bank=0;bank<2;++bank) {
        CAP(3)=bank;
        for (unsigned n=0;n<512;++n) {
            CAP(7)=4u*n+(channel>>1);
            /* INDEX is registered; let the synchronous capture RAM settle. */
            (void)CAP(1);
            uint32_t packed=CAP(8);
            FRAME[bank*512+n]=(int16_t)(packed >> (16u*(channel&1u)));
#ifdef FW_DEBUG4
            int32_t v=FRAME[bank*512+n];uint32_t a=v<0?(uint32_t)-v:(uint32_t)v;
            sum+=v;energy+=(uint32_t)(v*v);
            if(a>peak)peak=a;
            if(v==32767 || v==-32768)clipped++;
#endif
        }
    }
#ifdef FW_DEBUG4
    mic_stats[channel][0]=(uint32_t)sum;mic_stats[channel][1]=(uint32_t)energy;
    mic_stats[channel][2]=(uint32_t)(energy>>32);
    mic_stats[channel][3]=peak;mic_stats[channel][4]=clipped;
    location_prepare(FRAME,1024);
#endif
}

int main(void)
{
    fft_init(); srp_init();
    SRP(0)=2u;
    for (unsigned pair=0;pair<4;++pair) {
        srp_dump_tau((int)pair_a[pair],(int)pair_b[pair],(int16_t *)FW_OUT_BASE);
        SRP(2)=pair*256u;
        for (unsigned g=0;g<256;++g) SRP(3)=(uint16_t)((int16_t *)FW_OUT_BASE)[g];
    }
    STEER_REG(0)=2u;
    // Require consecutive located frames; ramp one quarter of the gap per update.
    STEER_REG(6)=0x00030340u;
    CAP(0)=1u; CAP(2)=512u;
    RESULT(0)=0x44415301u; RESULT(1)=0; RESULT(2)=0; RESULT(3)=0;
#ifdef FW_DEBUG4
    RESULT(28)=0;RESULT(29)=0;RESULT(30)=0;RESULT(31)=0;
    RESULT(LOCATION_META4_WORD)=0;
#endif
    MAILBOX=0xDA500001u;
    for (;;) {
        CAP(0)=7u;
        uint32_t start=rdcycle(), polls;
        for (polls=0;polls<1000000u;++polls) if ((CAP(1)&3u)==3u) break;
        if (polls==1000000u) { RESULT(3)=1; MAILBOX=0xDA5F0001u; break; }
        CAP(3)=0; uint32_t first0=CAP(5), seq0=CAP(4);
        CAP(3)=1; uint32_t first1=CAP(5), seq1=CAP(4);
        if (first1-first0!=512u || seq1-seq0!=1u) {
            RESULT(3)=2; MAILBOX=0xDA5F0002u; break;
        }
        uint32_t compute_start=rdcycle();
        for (unsigned pair=0;pair<4;++pair) {
            int32_t lag;
            load_channel(pair_a[pair]); gcc_load_a(FRAME);
            load_channel(pair_b[pair]); gcc_load_b(FRAME);
            gcc_finish((volatile int16_t *)FW_OUT2_BASE,&lag);
            SRP(2)=0x8000u+pair*1024u;
            for (unsigned n=0;n<1024;++n) SRP(3)=(uint16_t)FRAME[n];
        }
#ifdef FW_DEBUG4
        RESULT(28)=++mic_seq;
        for(unsigned ch=0;ch<4;ch++)for(unsigned k=0;k<5;k++)RESULT(8+5*ch+k)=mic_stats[ch][k];
        RESULT(28)=++mic_seq;RESULT(29)=0x4d494335u;
#endif
        SRP(0)=3u;
        if (wait_idle((volatile uint32_t *)0x8004u) || (SRP(1)&8u)) {
            RESULT(3)=3; MAILBOX=0xDA5F0003u; break;
        }
        SRP(2)=0x10000u;
        (void)SRP(1);
        int32_t best=(int32_t)SRP(4), second=INT32_MIN;
#ifdef FW_DEBUG4
        location_scores[0]=best;
#endif
        uint32_t grid=0;
        for (unsigned g=1;g<256;++g) {
            int32_t p=(int32_t)SRP(4);
#ifdef FW_DEBUG4
            location_scores[g]=p;
#endif
            if(p>best) { second=best; best=p; grid=g; }
            else if(p>second) second=p;
        }
        RESULT(30)=RESULT(30)+1;
        RESULT(31)=0;
        RESULT(2)=grid;RESULT(6)=(uint32_t)best;RESULT(7)=(uint32_t)second;
        uint32_t reason=best>0 && best>second?0u:LOCATION_AMBIGUOUS;
#ifdef FW_DEBUG4
        uint32_t contrast;int32_t nonlocal;
        reason=location_map_reason(location_scores,16,4,grid,&contrast,&nonlocal);
        for(unsigned ch=0;ch<4;ch++)reason|=location_input_reason((int32_t)mic_stats[ch][0],
            (uint64_t)mic_stats[ch][1]+((uint64_t)mic_stats[ch][2]<<32),mic_stats[ch][4]);
        unsigned raw_grid=grid;
        reason=location_track(&tracker,raw_grid,16,reason);grid=tracker.grid;
        RESULT(2)=grid;
        RESULT(LOCATION_META4_WORD)=LOCATION_QUALITY_MAGIC;
        RESULT(LOCATION_META4_WORD+1)=reason;RESULT(LOCATION_META4_WORD+2)=contrast;
        RESULT(LOCATION_META4_WORD+3)=raw_grid;RESULT(LOCATION_META4_WORD+4)=(uint32_t)nonlocal;
        RESULT(LOCATION_META4_WORD+5)=tracker.accepted;RESULT(LOCATION_META4_WORD+6)=tracker.rejected;
        RESULT(LOCATION_META4_WORD+7)=best>0?(uint32_t)best/4u:0;
#endif
        // Suppress steering updates for a flat or non-positive spatial spectrum.
        if (!reason) {
            STEER_REG(5)=grid;
            if(wait_idle((volatile uint32_t *)0xA004u) || (STEER_REG(1)&8u)) {
                RESULT(3)=4; MAILBOX=0xDA5F0004u; break;
            }
            RESULT(31)=1;
            RESULT(2)=grid; RESULT(6)=(uint32_t)best;
            RESULT(7)=(uint32_t)second;
        }
        RESULT(4)=rdcycle()-compute_start;
        RESULT(5)=rdcycle()-start;
        RESULT(1)=RESULT(1)+1;
        RESULT(30)=RESULT(30)+1;
        // Capture is a periodic localization snapshot; audio continues independently.
    }
    for (;;) {}
}
