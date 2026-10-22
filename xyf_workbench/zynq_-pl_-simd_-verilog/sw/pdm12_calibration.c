#include "pdm12_calibration.h"
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static int32_t s32(const uint8_t *p) {
    uint32_t u=u32(p);
    return u<=INT32_MAX ? (int32_t)u : (int32_t)(-1-(int64_t)(UINT32_MAX-u));
}
static uint32_t crc32(const uint8_t *p, size_t n) {
    uint32_t c=~0u;
    for(size_t i=0;i<n;i++) {
        c^=p[i];
        for(unsigned b=0;b<8;b++) c=(c>>1)^(0xedb88320u & (0u-(c&1u)));
    }
    return ~c;
}
static int64_t determinant(const int32_t a[3],const int32_t b[3],const int32_t c[3]) {
    return (int64_t)a[0]*((int64_t)b[1]*c[2]-(int64_t)b[2]*c[1])
         - (int64_t)a[1]*((int64_t)b[0]*c[2]-(int64_t)b[2]*c[0])
         + (int64_t)a[2]*((int64_t)b[0]*c[1]-(int64_t)b[1]*c[0]);
}
int pdm12_calibration_load(const uint8_t *p,size_t n,int allow_test,pdm12_calibration *out) {
    if(!p || !out || n!=PDM12_CAL_BYTES) return -1;
    const uint8_t magic[8]={'P','D','M','1','2','C','1',0};
    for(unsigned i=0;i<8;i++) if(p[i]!=magic[i]) return -2;
    if(crc32(p,n-4)!=u32(p+n-4)) return -3;
    if(u32(p+8)!=1 || !u32(p+12) || u32(p+20)!=390625u || u32(p+24)!=0x58595a52u) return -4;
    uint32_t flags=u32(p+16);
    if(flags&~3u || ((flags&1u) && !allow_test) || (!(flags&1u) && !(flags&2u))) return -5;
    pdm12_calibration tmp;
    tmp.version=u32(p+12);tmp.flags=flags;
    uint32_t seen=0;
    for(unsigned i=0;i<12;i++) {
        const uint8_t *r=p+28+32*i;
        pdm12_channel_cal *v=&tmp.channel[i];
        v->mic_id=u32(r);
        if(v->mic_id>=12 || (seen&(1u<<v->mic_id))) return -6;
        seen|=1u<<v->mic_id;
        for(unsigned k=0;k<3;k++) {
            v->xyz_um[k]=s32(r+4+4*k);
            if(v->xyz_um[k]<-1000000 || v->xyz_um[k]>1000000) return -7;
        }
        v->delay_q16=s32(r+16);v->gain_q14=s32(r+20);
        v->dc_offset=s32(r+24);v->polarity=s32(r+28);
        if(v->delay_q16 < -2097152 || v->delay_q16 > 2097152 ||
           v->gain_q14<1 || v->gain_q14>32767 ||
           v->dc_offset < -8388608 || v->dc_offset>8388607 ||
           (v->polarity!=1 && v->polarity!=-1)) return -8;
    }
    if(tmp.channel[0].delay_q16!=0) return -8;
    for(unsigned i=0;i<12;i++) for(unsigned j=i+1;j<12;j++) {
        int64_t d2=0;
        for(unsigned k=0;k<3;k++) {
            int64_t d=(int64_t)tmp.channel[i].xyz_um[k]-tmp.channel[j].xyz_um[k];d2+=d*d;
        }
        if(!d2) return -9;
        unsigned lag=0;
        /* 343m/s / 39062.5Hz = 219520/25 micrometres per sample.
         * Integer comparison avoids libm and platform-dependent rounding. */
        while(lag<=14 && d2*625 > (int64_t)(219520*lag)*(219520*lag)) lag++;
        int64_t dq=(int64_t)tmp.channel[i].delay_q16-tmp.channel[j].delay_q16;
        if(dq<0) dq=-dq;
        unsigned extra=(unsigned)((dq+65535)/65536);
        if(lag+extra>14) return -10;
    }
    /* Exact rank test after pair bounds have limited all difference vectors. */
    int32_t delta[11][3];
    for(unsigned i=1;i<12;i++) for(unsigned k=0;k<3;k++)
        delta[i-1][k]=tmp.channel[i].xyz_um[k]-tmp.channel[0].xyz_um[k];
    int spatial=0;
    for(unsigned i=0;i<11;i++) for(unsigned j=i+1;j<11;j++) for(unsigned k=j+1;k<11;k++)
        if(determinant(delta[i],delta[j],delta[k])!=0) spatial=1;
    if(!spatial) return -11; /* planar mirror ambiguity is unsafe for a 3D release */
    *out=tmp;
    return 0;
}
int32_t pdm12_calibration_correct(const pdm12_calibration *cal,unsigned ch,int32_t x) {
    if(!cal || ch>=12) return 0;
    const pdm12_channel_cal *c=&cal->channel[ch];
    /* int64 before subtraction also keeps malformed external int32 input safe. */
    int64_t y=((int64_t)x-c->dc_offset)*c->gain_q14*c->polarity;
    y/=16384;
    if(y>8388607) y=8388607;
    if(y< -8388608) y=-8388608;
    return (int32_t)y;
}
int pdm12_calibration_gain_words(const pdm12_calibration *cal,uint32_t words[6]) {
    if(!cal || !words) return -1;
    for(unsigned i=0;i<6;i++) {
        int32_t a=cal->channel[2*i].gain_q14*cal->channel[2*i].polarity;
        int32_t b=cal->channel[2*i+1].gain_q14*cal->channel[2*i+1].polarity;
        words[i]=(uint16_t)a | (uint32_t)(uint16_t)b<<16;
    }
    return 0;
}
