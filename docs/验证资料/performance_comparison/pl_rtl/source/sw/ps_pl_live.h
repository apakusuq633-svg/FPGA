/* Preparation shared with the live PL release ABI. Call only on matching hardware. */
#ifndef PS_PL_LIVE_H
#define PS_PL_LIVE_H
#include "ps_das_audio.h"
#ifndef UI_DAS_ACTIVE_CHANNELS
#define UI_DAS_ACTIVE_CHANNELS 8
#endif
#ifndef UI_LIVE16_LOCALIZATION
#define UI_LIVE16_LOCALIZATION (UI_DAS_ACTIVE_CHANNELS >= 8)
#endif
#if UI_DAS_ACTIVE_CHANNELS == 4
#include "acoustic_debug4_image.h"
#elif UI_DAS_ACTIVE_CHANNELS == 8
#include "acoustic_planar8_image.h"
#elif UI_DAS_ACTIVE_CHANNELS == 9
#include "acoustic_circular9_image.h"
#elif UI_DAS_ACTIVE_CHANNELS == 12
#include "acoustic_live12_image.h"
#elif UI_DAS_ACTIVE_CHANNELS == 16
#if UI_LIVE16_LOCALIZATION
#include "acoustic_live16_image.h"
#else
#include "acoustic_live16_fixed_image.h"
#endif
#else
#include "acoustic_live_image.h"
#endif
/* Nine-channel gain correction belongs before localization, raw DMA, DAS and
 * PS separation. Never inherit register state from a previous application. */
#if UI_DAS_ACTIVE_CHANNELS == 9
static inline int pl_live_c9_gains(const das_bus *b)
{
    unsigned i;
    for(i=0;i<5u;i++) {
        uint32_t value=acoustic_gain_q14[2u*i]|(acoustic_gain_q14[2u*i+1u]<<16);
        b->write(b->ctx,0x340u+4u*i,value);
    }
    for(i=0;i<5u;i++) {
        uint32_t value=acoustic_gain_q14[2u*i]|(acoustic_gain_q14[2u*i+1u]<<16);
        if(b->read(b->ctx,0x340u+4u*i)!=value)return 0;
    }
    return 1;
}
#endif
static inline int pl_live_load(const das_bus *b,const uint32_t *data,unsigned n,uint32_t base)
{
    unsigned i;
    b->write(b->ctx,0x80,base);
    for(i=0;i<n;i++)b->write(b->ctx,0x84,data[i]);
    b->write(b->ctx,0x80,base);
    for(i=0;i<n;i++)if(b->read(b->ctx,0x88)!=data[i])return 0;
    return 1;
}
/* Keep audio disabled until networking and CPU1 are ready. */
static inline int pl_live_prepare(const das_bus *b)
{
    unsigned i;
    if(b->read(b->ctx,0x39c)!=0x44415301u)return -1;
    if(b->read(b->ctx,0x3c0)!=UI_DAS_ACTIVE_CHANNELS)return -6;
#if UI_DAS_ACTIVE_CHANNELS == 9
    if(b->read(b->ctx,0x3f0)!=0x43395831u)return -14;
    if(b->read(b->ctx,0x3e4)!=ACOUSTIC_PDM_DECIM ||
       b->read(b->ctx,0x3e8)!=ACOUSTIC_LOCALIZER_HOP ||
       b->read(b->ctx,0x3ec)!=ACOUSTIC_CORRELATION_LAGS)return -10;
#endif
#if UI_LIVE16_LOCALIZATION
    if(b->read(b->ctx,0x3c4)!=0x41435303u)return -9;
    if((b->read(b->ctx,0x41c)>>16)!=0x12u)return -7;
#endif
#if UI_DAS_ACTIVE_CHANNELS == 9
    b->write(b->ctx,0x380,4u);
    b->write(b->ctx,0x300,0u);
#endif
    b->write(b->ctx,0,18u);
    for(i=0;i<100000u;i++)if(b->read(b->ctx,4)&4u)break;
    if(i==100000u)return -2;
#if UI_DAS_ACTIVE_CHANNELS == 9
    if(!pl_live_c9_gains(b))return -11;
    b->write(b->ctx,0x3f0,0x4f464631u);
    b->write(b->ctx,0x3f4,64u);b->write(b->ctx,0x3f8,0u);
#endif
    b->write(b->ctx,0x8c,2u);
    if(!pl_live_load(b,acoustic_itcm,ACOUSTIC_ITCM_WORDS,0) ||
       !pl_live_load(b,acoustic_dtcm,ACOUSTIC_DTCM_WORDS,0x80000000u))return -3;
    b->write(b->ctx,0xc0,0x400u);
    for(i=0;i<ACOUSTIC_FIR_COEFF_WORDS;i++)b->write(b->ctx,0xc4,acoustic_fir_coeff[i]);
    b->write(b->ctx,0xc0,0x400u);
    for(i=0;i<ACOUSTIC_FIR_COEFF_WORDS;i++)if(b->read(b->ctx,0xc8)!=acoustic_fir_coeff[i])return -4;
#if UI_DAS_ACTIVE_CHANNELS < 12 || UI_LIVE16_LOCALIZATION
    b->write(b->ctx,0x600,14u);b->write(b->ctx,0x608,0);
    for(i=0;i<ACOUSTIC_STEER_LUT_WORDS;i++)b->write(b->ctx,0x60c,acoustic_steer_lut[i]);
#if UI_DAS_ACTIVE_CHANNELS == 9
    if((b->read(b->ctx,0x604)&9u)||b->read(b->ctx,0x608)!=0)return -12;
#endif
#endif
#if UI_LIVE16_LOCALIZATION
    b->write(b->ctx,0x400,14u);b->write(b->ctx,0x408,0);
    for(i=0;i<ACOUSTIC_SRP_LUT_WORDS;i++)b->write(b->ctx,0x40c,acoustic_srp_lut[i]);
    if(b->read(b->ctx,0x404)&8u)return -8;
#if UI_DAS_ACTIVE_CHANNELS == 9
    if((b->read(b->ctx,0x404)&1u)||b->read(b->ctx,0x408)!=0)return -13;
#endif
#endif
    return 0;
}
static inline void pl_live_start(const das_bus *b)
{
    b->write(b->ctx,0x380,UI_DAS_ACTIVE_CHANNELS==9?61u:UI_DAS_ACTIVE_CHANNELS==16 && !UI_LIVE16_LOCALIZATION?1u:5u);b->write(b->ctx,0,3u);b->write(b->ctx,0,0);
}
static inline void pl_live_stop(const das_bus *b)
{ b->write(b->ctx,0x380,4u);b->write(b->ctx,0,2u); }
#endif
