#ifndef PS_MIC_LEVELS_H
#define PS_MIC_LEVELS_H
#include "ps_das_audio.h"
#include "ps_features.h"
typedef struct {
    uint32_t valid,seq,frozen,channels;
    uint32_t loc_seq,loc_valid,loc_grid,loc_frame,loc_age_ms,loc_enabled,loc_grid_w;
    uint32_t loc_compute_cycles,loc_total_cycles,loc_first_sample,loc_steer_status,loc_error;
    int32_t loc_best,loc_second;
    uint32_t loc_quality_supported,loc_reason,loc_quality_permille,loc_raw_grid;
    uint32_t loc_accepted,loc_rejected,loc_score_per_pair;
    int32_t loc_nonlocal;
    int32_t mean_ppm[16];
    uint32_t rms_ppm[16],peak_ppm[16],clipped[16];
} mic_levels;
static inline uint32_t mic_read_word(const das_bus *b,unsigned word)
{
    b->write(b->ctx,0x80,0x80000a00u+word);
    return b->read(b->ctx,0x88);
}
static inline void mic_location_poll(const das_bus *b,mic_levels *out)
{
    uint32_t profile=mic_read_word(b,0);
    unsigned sequence_word=(profile==0xda508002u || profile==0xda516002u || profile==0xda512002u)?90u:30u;
    out->loc_enabled=profile!=0xda508001u && profile!=0xda516001u && profile!=0xda512001u;
    out->loc_grid_w=(profile==0xda508002u || profile==0xda516002u || profile==0xda512002u || profile==0xda512001u)?32u:16u;
    if(!out->loc_enabled){out->loc_valid=0;out->loc_quality_supported=0;return;}
    uint32_t seq=mic_read_word(b,sequence_word),grid,frame,valid;
    int32_t best,second;
    if(!seq || (seq&1u))return;
    grid=mic_read_word(b,2);frame=mic_read_word(b,1);
    best=(int32_t)mic_read_word(b,6);second=(int32_t)mic_read_word(b,7);
    valid=mic_read_word(b,sequence_word+1);
    uint32_t compute=mic_read_word(b,4),total=mic_read_word(b,5),error=mic_read_word(b,3);
    uint32_t first=(profile==0xda508002u || profile==0xda516002u || profile==0xda512002u)?mic_read_word(b,93):0;
    uint32_t steer=(profile==0xda508002u || profile==0xda516002u || profile==0xda512002u)?mic_read_word(b,94):0;
    unsigned meta=(profile==0xda508002u || profile==0xda516002u || profile==0xda512002u)?96u:1080u;
    uint32_t quality[8]={0};
    quality[0]=mic_read_word(b,meta);
    if(quality[0]==0x4c515431u)for(unsigned k=1;k<8;k++)quality[k]=mic_read_word(b,meta+k);
    if(seq!=mic_read_word(b,sequence_word))return;
    out->loc_seq=seq;out->loc_frame=frame;out->loc_grid=grid;
    out->loc_best=best;out->loc_second=second;
    out->loc_compute_cycles=compute;out->loc_total_cycles=total;out->loc_error=error;
    out->loc_first_sample=first;out->loc_steer_status=steer;
    out->loc_quality_supported=quality[0]==0x4c515431u;
    out->loc_reason=quality[1];out->loc_quality_permille=quality[2];
    out->loc_raw_grid=out->loc_quality_supported?quality[3]:grid;out->loc_nonlocal=(int32_t)quality[4];
    out->loc_accepted=quality[5];out->loc_rejected=quality[6];out->loc_score_per_pair=quality[7];
    out->loc_valid=valid && grid<out->loc_grid_w*out->loc_grid_w && best>0;
    if(out->loc_quality_supported)out->loc_valid=out->loc_valid&&!out->loc_reason;
    else out->loc_valid=out->loc_valid&&best>second;
}
static inline void mic_levels_poll(const das_bus *b,mic_levels *out)
{
    uint32_t data[80],seq,end;unsigned i;
    uint32_t profile=mic_read_word(b,0);
    unsigned channels=(profile==0xda508001u || profile==0xda508002u)?8u:
        (profile==0xda512001u || profile==0xda512002u)?12u:
        (profile==0xDA516001u || profile==0xDA516002u)?16u:4u;
    unsigned sequence_word=channels>=8?88:28,magic_word=sequence_word+1;
    out->frozen=b->read(b->ctx,0x330);
    if(mic_read_word(b,magic_word)!=(channels==8?0x4d493038u:channels==12?0x4d493132u:channels==16?0x4d493136u:0x4d494335u))return;
    seq=mic_read_word(b,sequence_word);if(!seq || (seq&1u))return;
    b->write(b->ctx,0x80,0x80000a08u);
    for(i=0;i<channels*5;i++)data[i]=b->read(b->ctx,0x88);
    end=mic_read_word(b,sequence_word);if(seq!=end)return;
    for(i=0;i<channels;i++) {
        out->mean_ppm[i]=(int32_t)((double)(int32_t)data[5*i]*1000000.0/(1024.0*32768.0));
        out->rms_ppm[i]=(uint32_t)(d_sqrt(((double)data[5*i+1]+4294967296.0*data[5*i+2])/1024.0)*1000000.0/32768.0);
        out->peak_ppm[i]=(uint32_t)((double)data[5*i+3]*1000000.0/32768.0);
        out->clipped[i]=data[5*i+4];
    }
    out->seq=seq;out->valid=1;out->channels=channels;
}
#endif
