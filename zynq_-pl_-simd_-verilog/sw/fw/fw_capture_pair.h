#ifndef FW_CAPTURE_PAIR_H
#define FW_CAPTURE_PAIR_H
#include <stdint.h>
#include "fw_cycle_profile.h"
#ifndef FW_CAPTURE_INCREMENT
#define FW_CAPTURE_INCREMENT 0
#endif

/* Both frozen banks stay owned by RV32 until the next CAP(0)=7. */
static __attribute__((noinline)) void capture_pair(unsigned ch, unsigned channels, uint32_t stats[][5],
                         int16_t *low, int16_t *high)
{
    int32_t s0=0,s1=0;
    uint64_t e0=0,e1=0;
    uint32_t p0=0,p1=0,c0=0,c1=0;
    for(unsigned bank=0;bank<2;bank++) {
        CAP(3)=bank;
        unsigned index=ch>>1;
        for(unsigned n=0;n<512;n++) {
#if FW_DETAIL_PROFILE
            uint32_t t0=read_cycles();
#endif
            if(FW_CAPTURE_INCREMENT) {CAP(7)=index;index+=channels/2u;}
            else CAP(7)=(channels/2u)*n+(ch>>1);
            (void)CAP(1); /* Registered INDEX and synchronous capture RAM. */
            uint32_t word=CAP(8);
#if FW_DETAIL_PROFILE
            uint32_t t1=read_cycles();
#endif
            int32_t a=(int16_t)word,b=(int16_t)(word>>16);
#if FW_DETAIL_PROFILE
            uint32_t t2=read_cycles_after2((uint32_t)a,(uint32_t)b);
#endif
            if(low) {low[bank*512+n]=(int16_t)a;high[bank*512+n]=(int16_t)b;}
#if FW_DETAIL_PROFILE
            uint32_t t3=read_cycles();
#endif
            s0+=a;s1+=b;e0+=(uint32_t)(a*a);e1+=(uint32_t)(b*b);
            uint32_t aa=a<0?(uint32_t)-a:(uint32_t)a;
            uint32_t bb=b<0?(uint32_t)-b:(uint32_t)b;
            if(aa>p0)p0=aa;
            if(bb>p1)p1=bb;
            if(a==32767||a==-32768)c0++;
            if(b==32767||b==-32768)c1++;
#if FW_DETAIL_PROFILE
            uint32_t t4=read_cycles_after_stats(s0,s1,e0,e1,p0,p1,c0,c1);
            fw_capture_detail[0]+=t1-t0;fw_capture_detail[1]+=t2-t1;
            fw_capture_detail[2]+=t3-t2;fw_capture_detail[3]+=t4-t3;
#endif
        }
    }
    stats[ch][0]=(uint32_t)s0;stats[ch][1]=(uint32_t)e0;
    stats[ch][2]=(uint32_t)(e0>>32);stats[ch][3]=p0;stats[ch][4]=c0;
    stats[ch+1][0]=(uint32_t)s1;stats[ch+1][1]=(uint32_t)e1;
    stats[ch+1][2]=(uint32_t)(e1>>32);stats[ch+1][3]=p1;stats[ch+1][4]=c1;
}
#endif
