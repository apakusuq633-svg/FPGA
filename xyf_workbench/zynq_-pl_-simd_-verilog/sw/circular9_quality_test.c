#include <assert.h>
#include <stdio.h>
#include "fw/fw_location_quality.h"

int main(void)
{
    int32_t p[1024];uint32_t seed=20261022;
    /* All exclusion-square positions, edges, ties and signed score patterns. */
    for(unsigned scene=0;scene<12;scene++) {
        for(unsigned g=0;g<1024;g++) {
            seed=1664525u*seed+1013904223u;
            p[g]=scene==0?0:scene==1?-100:scene==2?100:
                 (int32_t)(seed%2000001u)-1000000;
        }
        for(unsigned grid=0;grid<1024;grid++) {
            uint32_t c0,c1;int32_t f0,f1;
            uint32_t r0=location_map_reason(p,32,36,grid,&c0,&f0);
            uint32_t r1=location_map_reason32(p,36,grid,&c1,&f1);
            assert(r0==r1 && c0==c1 && f0==f1);
        }
    }
    puts("CIRCULAR9_QUALITY_EQUIVALENT cases=12288");return 0;
}
