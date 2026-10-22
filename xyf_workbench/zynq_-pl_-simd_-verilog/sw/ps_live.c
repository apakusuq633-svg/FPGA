/* Production live PDM -> localization snapshots + continuous DAS/SIMD FIR. */
#include <stdint.h>
#include "xil_io.h"
#include "xil_printf.h"
#include "acoustic_planar8_image.h"

#ifndef RV32_BASE
#define RV32_BASE 0x43C00000u
#endif
#ifndef LIVE_SAMPLES
#define LIVE_SAMPLES 23437500u
#endif
volatile uint32_t live_audio_ring[4096];
volatile uint32_t live_audio_samples;
static void wr(uint32_t a,uint32_t v) { Xil_Out32(RV32_BASE+a,v); }
static uint32_t rd(uint32_t a) { return Xil_In32(RV32_BASE+a); }
static uint32_t result(unsigned i)
{
    wr(0x80u,0x80000000u+0xA00u+i);
    return rd(0x88u);
}
static int load(const uint32_t *data,unsigned count,uint32_t base)
{
    wr(0x80u,base);
    for(unsigned i=0;i<count;++i) wr(0x84u,data[i]);
    wr(0x80u,base);
    for(unsigned i=0;i<count;++i) if(rd(0x88u)!=data[i]) return 1;
    return 0;
}
static int fail(unsigned stage)
{
    xil_printf("LIVE_DAS_FAIL stage=%u\r\n",stage);
    wr(0x380u,4u); wr(0,2u);
    return (int)stage;
}
int main(void)
{
    xil_printf("LIVE_DAS_START samples=%u SHA256=%s\r\n",(unsigned)LIVE_SAMPLES,ACOUSTIC_ITCM_SHA256);
    if(rd(0x3c0u)!=8u) return fail(6);
    wr(0,18u);
    for(unsigned n=0;n<100000u && !(rd(4)&4u);++n) {}
    if(!(rd(4)&4u)) return fail(1);
    wr(0x8Cu,2u);
    if(load(acoustic_itcm,ACOUSTIC_ITCM_WORDS,0) ||
       load(acoustic_dtcm,ACOUSTIC_DTCM_WORDS,0x80000000u)) return fail(2);
    wr(0xC0u,0x400u);
    for(unsigned i=0;i<ACOUSTIC_FIR_COEFF_WORDS;++i) wr(0xC4u,acoustic_fir_coeff[i]);
    wr(0xC0u,0x400u);
    for(unsigned i=0;i<ACOUSTIC_FIR_COEFF_WORDS;++i)
        if(rd(0xC8u)!=acoustic_fir_coeff[i]) return fail(3);
    wr(0x600u,2u); wr(0x608u,0);
    for(unsigned i=0;i<ACOUSTIC_STEER_LUT_WORDS;++i) wr(0x60Cu,acoustic_steer_lut[i]);
    wr(0x400u,2u); wr(0x408u,0);
    for(unsigned i=0;i<ACOUSTIC_SRP_LUT_WORDS;++i) wr(0x40Cu,acoustic_srp_lut[i]);
    wr(0x380u,5u);
    wr(0,3u); wr(0,0);
    unsigned poll;
    for(poll=0;poll<1000000u;++poll) {
        if(rd(0x34u)==0xDA500001u || rd(0x30u)) break;
    }
    if(poll==1000000u || rd(0x30u)) return fail(4);
    live_audio_samples=0;
    unsigned idle=0, nonzero=0, locked_seen=0;
    while(live_audio_samples<LIVE_SAMPLES) {
        uint32_t status=rd(0x384u);
        locked_seen |= status&2u;
        if(status&4u || rd(0x30u) || (rd(0x34u)&0xffff0000u)==0xDA5F0000u) break;
        unsigned available=(status>>3)&511u;
        if(!available) {
            if(++idle>1000000u) break;
            continue;
        }
        idle=0;
        while(available-- && live_audio_samples<LIVE_SAMPLES) {
            uint32_t sample=rd(0x38Cu);
            live_audio_ring[live_audio_samples&4095u]=sample;
            nonzero += (int16_t)(sample>>16)!=0;
            ++live_audio_samples;
        }
    }
    wr(0x380u,4u);
    for(poll=0;poll<100000u && (rd(0x384u)&1u);++poll) {}
    wr(0,2u);
    uint32_t drops=rd(0x390u), max_cycles=rd(0x394u);
    uint32_t frames=result(1), error=result(3);
    uint32_t frozen=rd(0x330u)&((1u<<ACOUSTIC_ARRAY_CHANNELS)-1u);
    int bad=live_audio_samples!=LIVE_SAMPLES || drops || error || !frames ||
            !nonzero || (ACOUSTIC_GEOMETRY_CONFIRMED && !locked_seen) || frozen || max_cycles>819u ||
            (rd(0x384u)&5u) || rd(0x30u);
    xil_printf("LIVE_DAS_%s samples=%u snapshots=%u grid=%u drops=%u max_cycles=%u error=%u nonzero=%u frozen=%u locked=%u\r\n",
        bad ? "FAIL" : "PASS",(unsigned)live_audio_samples,(unsigned)frames,
        (unsigned)result(2),(unsigned)drops,(unsigned)max_cycles,(unsigned)error,
        nonzero,(unsigned)frozen,(unsigned)(locked_seen!=0));
    return bad;
}
