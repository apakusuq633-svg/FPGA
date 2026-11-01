#ifndef FW_PREPARE_FUSED_H
#define FW_PREPARE_FUSED_H
#include <stdint.h>
#include "fw_tables.h"
/* Preserve the old int16 scaling boundary before applying the Q14 Hann. */
static inline uint32_t prepare_fused(int16_t *x,int32_t sum)
{
    int32_t mean=sum/1024;uint32_t peak=0;unsigned left=0,right=0;
    for(unsigned n=0;n<1024;n++) {
        int32_t v=(int32_t)x[n]-mean;uint32_t a=v<0?(uint32_t)-v:(uint32_t)v;
        if(a>peak)peak=a;
    }
    uint32_t bound=peak;
    if(bound)while(bound<8192u&&left<14u){bound*=2;left++;}
    while(bound>32767u){bound=(bound+1u)/2u;right++;}
    for(unsigned n=0;n<1024;n++) {
        int16_t scaled=(int16_t)((((int32_t)x[n]-mean)*(int32_t)(1u<<left))>>right);
        unsigned k=n<=512?n:1024-n;
        x[n]=(int16_t)(((int32_t)scaled*(8192-(g_tw_re[k]>>1)))>>14);
    }
    return peak;
}
#endif
