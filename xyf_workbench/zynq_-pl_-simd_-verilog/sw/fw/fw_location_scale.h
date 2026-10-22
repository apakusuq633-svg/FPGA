#ifndef FW_LOCATION_SCALE_H
#define FW_LOCATION_SCALE_H
#include <stdint.h>
/* PHAT discards amplitude. Use available headroom before fixed-point FFT. */
static inline void location_scale(int16_t *x,unsigned count,uint32_t peak)
{
    unsigned shift=0;
    if(!peak)return;
    while(peak<8192 && shift<14) {peak*=2;shift++;}
    for(unsigned n=0;n<count;n++)x[n]=(int16_t)((int32_t)x[n]*(int32_t)(1u<<shift));
}
#endif
