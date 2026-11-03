#ifndef FW_LOCATION_QUALITY_H
#define FW_LOCATION_QUALITY_H
#include <stdint.h>
#include "fw_cycle_profile.h"

#define LOCATION_QUALITY_MAGIC 0x4c515431u
#define LOCATION_META4_WORD 1080u /* Reserved gap 0x38e0, outside FFT/GCC workspaces. */
#define LOCATION_META16_WORD 96u
#define LOCATION_SILENT 1u
#define LOCATION_BAD_INPUT 2u
#define LOCATION_WEAK 4u
#define LOCATION_AMBIGUOUS 8u
#define LOCATION_CONFIRMING 16u
#define LOCATION_DEADLINE 64u
#define LOCATION_MIN_PAIR_SCORE 64u
#define LOCATION_MIN_CONTRAST 20u
#define LOCATION_REFINED_MAGIC 0x4c524631u
#define LOCATION_REFINED_WORD 116u

/* Non-peak, flat or boundary axes stay on the grid center. */
static inline int32_t location_axis_offset(int32_t l,int32_t c,int32_t r,unsigned *valid)
{
    *valid=0;
    if(c<=0||c<=l||c<=r||l>4000000||l<-4000000||c>4000000||r>4000000||r<-4000000)return 0;
    int32_t difference=l-r,curve=l-2*c+r;
    while(difference>32767||difference<-32767||curve<-32767) {
        l>>=1;c>>=1;r>>=1;difference=l-r;curve=l-2*c+r;
    }
    if(curve>=0)return 0;
    int32_t offset=(difference*32768)/curve;
    if(offset>32768)offset=32768;
    if(offset<-32768)offset=-32768;
    *valid=1;return offset;
}
static inline unsigned location_refine(const int32_t *p,unsigned w,unsigned grid,
                                      uint32_t *x_q16,uint32_t *y_q16)
{
    unsigned x=grid%w,y=grid/w,vx=0,vy=0;
    int32_t dx=0,dy=0;
    if(x>0&&x+1<w)dx=location_axis_offset(p[grid-1],p[grid],p[grid+1],&vx);
    if(y>0&&y+1<w)dy=location_axis_offset(p[grid-w],p[grid],p[grid+w],&vy);
    *x_q16=x*65536u+dx;*y_q16=y*65536u+dy;
    return vx|(vy<<1);
}

typedef struct {
    uint32_t known,grid,pending,count,misses,accepted,rejected;
} location_tracker;

/* Remove frame DC before allocating FFT headroom; preserve int16 endpoints. */
static inline uint32_t location_prepare(int16_t *x,unsigned count)
{
    int32_t sum=0;uint32_t peak=0;unsigned left=0,right=0;
#if FW_DETAIL_PROFILE
    uint32_t t0=read_cycles();
#endif
    for(unsigned n=0;n<count;n++)sum+=x[n];
    int32_t mean=sum/(int32_t)count;
#if FW_DETAIL_PROFILE
    uint32_t t1=read_cycles_after2((uint32_t)sum,(uint32_t)mean);
#endif
    for(unsigned n=0;n<count;n++) {
        int32_t v=(int32_t)x[n]-mean;uint32_t a=v<0?(uint32_t)-v:(uint32_t)v;
        if(a>peak)peak=a;
    }
    uint32_t bound=peak;
#if FW_DETAIL_PROFILE
    uint32_t t2=read_cycles_after2(peak,bound);
#endif
    if(bound)while(bound<8192u&&left<14u){bound*=2;left++;}
    while(bound>32767u){bound=(bound+1u)/2u;right++;}
#if FW_DETAIL_PROFILE
    uint32_t t3=read_cycles_after2(left,right);
#endif
    for(unsigned n=0;n<count;n++) {
        int32_t v=((int32_t)x[n]-mean)*(int32_t)(1u<<left);
        x[n]=(int16_t)(v>>right);
    }
#if FW_DETAIL_PROFILE
    uint32_t t4=read_cycles();
    fw_prepare_detail[0]+=t1-t0;fw_prepare_detail[1]+=t2-t1;
    fw_prepare_detail[2]+=t3-t2;fw_prepare_detail[3]+=t4-t3;
#endif
    return peak;
}

static inline uint32_t location_input_reason(int32_t sum,uint64_t energy,uint32_t clipped)
{
    uint64_t dc=(uint64_t)((int64_t)sum*sum);
    uint64_t ac=energy*1024u-dc;
    uint32_t reason=ac<1024u*1024u?LOCATION_SILENT:0u;
    return reason|(clipped>=16u?LOCATION_BAD_INPUT:0u);
}

/* Compare against a different spatial lobe, not the adjacent cell of one peak. */
static inline uint32_t location_map_reason(const int32_t *p,unsigned w,unsigned pairs,
                                           unsigned grid,uint32_t *contrast,int32_t *nonlocal)
{
    int32_t best=p[grid],far=INT32_MIN;
    unsigned radius=w/8u,gx=grid%w,gy=grid/w;
    for(unsigned g=0;g<w*w;g++) {
        unsigned x=g%w,y=g/w;
        unsigned dx=x>gx?x-gx:gx-x,dy=y>gy?y-gy:gy-y;
        if((dx>radius||dy>radius)&&p[g]>far)far=p[g];
    }
    *nonlocal=far;*contrast=0;
    if(best<=0)return LOCATION_WEAK;
    uint32_t competitor=far>0?(uint32_t)far:0;
    /* 120 * 32767 * 1000 fits uint32; avoid an RV32 software 64-bit divide. */
    *contrast=((uint32_t)best-competitor)*1000u/(uint32_t)best;
    if((uint32_t)best<pairs*LOCATION_MIN_PAIR_SCORE)return LOCATION_WEAK;
    return *contrast<LOCATION_MIN_CONTRAST?LOCATION_AMBIGUOUS:0u;
}

/* Exact 32x32 specialization: scan the complement of the clipped 9x9
 * exclusion square as contiguous spans, avoiding per-cell x/y distances. */
static inline int32_t location_span_max(const int32_t *p,unsigned begin,unsigned end,int32_t far)
{
    for(unsigned g=begin;g<end;g++)if(p[g]>far)far=p[g];
    return far;
}
static inline uint32_t location_map_reason32(const int32_t *p,unsigned pairs,
                                            unsigned grid,uint32_t *contrast,int32_t *nonlocal)
{
    unsigned gx=grid&31u,gy=grid>>5;
    unsigned x0=gx>4?gx-4:0,x1=gx<27?gx+5:32;
    unsigned y0=gy>4?gy-4:0,y1=gy<27?gy+5:32;
    int32_t best=p[grid],far=location_span_max(p,0,y0*32,INT32_MIN);
    for(unsigned y=y0;y<y1;y++) {
        far=location_span_max(p,y*32,y*32+x0,far);
        far=location_span_max(p,y*32+x1,(y+1)*32,far);
    }
    far=location_span_max(p,y1*32,1024,far);
    *nonlocal=far;*contrast=0;
    if(best<=0)return LOCATION_WEAK;
    uint32_t competitor=far>0?(uint32_t)far:0;
    *contrast=((uint32_t)best-competitor)*1000u/(uint32_t)best;
    if((uint32_t)best<pairs*LOCATION_MIN_PAIR_SCORE)return LOCATION_WEAK;
    return *contrast<LOCATION_MIN_CONTRAST?LOCATION_AMBIGUOUS:0u;
}

static inline unsigned location_distance(unsigned a,unsigned b,unsigned w)
{
    unsigned ax=a%w,ay=a/w,bx=b%w,by=b/w;
    unsigned dx=ax>bx?ax-bx:bx-ax,dy=ay>by?ay-by:by-ay;
    return dx>dy?dx:dy;
}

/* Confirm new directions in firmware; invalid observations never become (0,0). */
static inline uint32_t location_track(location_tracker *s,unsigned raw,unsigned w,uint32_t reason)
{
    unsigned near=w/16u;
    if(reason) {
        s->count=0;s->rejected++;
        if(++s->misses>=3)s->known=0;
        return reason;
    }
    s->misses=0;
    if(s->known&&location_distance(raw,s->grid,w)<=near) {
        s->count=0;s->accepted++;return 0;
    }
    unsigned needed=s->known&&location_distance(raw,s->grid,w)>w/4u?3u:2u;
    if(!s->count||location_distance(raw,s->pending,w)>near) {s->pending=raw;s->count=1;}
    else s->count++;
    if(!s->known)s->grid=raw;
    if(s->count<needed){s->rejected++;return LOCATION_CONFIRMING;}
    s->grid=raw;s->known=1;s->count=0;s->accepted++;return 0;
}
#endif
