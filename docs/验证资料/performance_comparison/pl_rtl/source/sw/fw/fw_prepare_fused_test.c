#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "fw_location_quality.h"
#include "fw_prepare_fused.h"
int main(void) {
    int16_t old[1024],fresh[1024];uint32_t seed=20261014;
    for(unsigned scene=0;scene<260;scene++) {
        int32_t sum=0;
        for(unsigned n=0;n<1024;n++) {
            seed=seed*1664525u+1013904223u;int16_t v=(int16_t)(seed>>16);
            if(scene==0)v=0;
            if(scene==1)v=1234;
            if(scene==2)v=n&1?-32768:32767;
            if(scene==3)v=(int16_t)(20000+(int32_t)(n%3)-1);
            old[n]=fresh[n]=v;sum+=v;
        }
        uint32_t a=location_prepare(old,1024),b=prepare_fused(fresh,sum);
        for(unsigned n=0;n<1024;n++) {
            unsigned k=n<=512?n:1024-n;
            old[n]=(int16_t)(((int32_t)old[n]*(8192-(g_tw_re[k]>>1)))>>14);
        }
        if(a!=b||memcmp(old,fresh,sizeof old))return 1;
    }
    puts("PREPARE_FUSED_PASS scenes=260 fft_input_error=0 endpoints_dc_weak_silence=1");return 0;
}
