#include <assert.h>
#include <stdio.h>
#include "ps_mic_levels.h"
typedef struct {uint32_t words[1100],index;unsigned sequence_reads,race,loc_reads,loc_race;} mock;
static uint32_t read_reg(void *ctx,uint32_t off) {
    mock *m=ctx;if(off==0x330)return 240;
    assert(off==0x88 && m->index<1100);
    if(m->index==28 && ++m->sequence_reads==2 && m->race)return m->words[m->index++]+2;
    if(m->index==30 && ++m->loc_reads==2 && m->loc_race)return m->words[m->index++]+2;
    return m->words[m->index++];
}
static void write_reg(void *ctx,uint32_t off,uint32_t v) {
    mock *m=ctx;assert(off==0x80);m->index=v-0x80000a00u;
}
int main(void) {
    mock m={0};mic_levels levels={0};das_bus bus={&m,read_reg,write_reg};
    int32_t samples[4]={8192,-4096,0,-32768};
    for(unsigned i=0;i<4;i++) {
        int32_t v=samples[i];uint64_t energy=(uint64_t)(v*v)*1024;
        m.words[8+5*i]=(uint32_t)(v*1024);m.words[9+5*i]=(uint32_t)energy;
        m.words[10+5*i]=(uint32_t)(energy>>32);m.words[11+5*i]=v<0?-v:v;
        m.words[12+5*i]=i==3?1024:0;
    }
    m.words[28]=2;m.words[29]=0x4d494335u;mic_levels_poll(&bus,&levels);
    assert(levels.valid && levels.frozen==240 && levels.seq==2);
    assert(levels.mean_ppm[0]==250000 && levels.rms_ppm[0]==250000);
    assert(levels.mean_ppm[1]==-125000 && levels.peak_ppm[1]==125000);
    assert(!levels.rms_ppm[2] && levels.clipped[3]==1024 && levels.rms_ppm[3]==1000000);
    levels.valid=0;m.race=1;m.sequence_reads=0;mic_levels_poll(&bus,&levels);assert(!levels.valid);
    m.words[28]=3;mic_levels_poll(&bus,&levels);assert(!levels.valid);
    m.words[30]=2;m.words[31]=1;m.words[2]=255;m.words[1]=1;m.words[6]=100;m.words[7]=99;
    mic_location_poll(&bus,&levels);
    assert(levels.loc_valid && levels.loc_seq==2 && levels.loc_grid==255 && levels.loc_frame==1);
    m.words[1080]=0x4c515431u;m.words[1081]=16;m.words[1082]=120;m.words[1083]=250;
    m.words[1085]=5;m.words[1086]=3;m.words[30]=4;
    mic_location_poll(&bus,&levels);
    assert(levels.loc_quality_supported&&!levels.loc_valid&&levels.loc_reason==16);
    assert(levels.loc_raw_grid==250&&levels.loc_quality_permille==120&&levels.loc_accepted==5);
    m.words[1081]=0;m.words[30]=6;mic_location_poll(&bus,&levels);assert(levels.loc_valid);
    m.words[7]=100;m.words[30]=8;mic_location_poll(&bus,&levels);assert(levels.loc_valid);
    m.words[7]=99;
    m.words[1080]=0;m.words[30]=2;mic_location_poll(&bus,&levels);
    m.loc_race=1;m.loc_reads=0;m.words[2]=0;m.words[30]=4;
    mic_location_poll(&bus,&levels);assert(levels.loc_seq==2 && levels.loc_grid==255);
    m.loc_race=0;m.words[30]=5;mic_location_poll(&bus,&levels);assert(levels.loc_seq==2);
    m.words[30]=6;m.words[7]=100;mic_location_poll(&bus,&levels);assert(!levels.loc_valid);
    m.words[30]=8;m.words[7]=99;m.words[2]=256;mic_location_poll(&bus,&levels);assert(!levels.loc_valid);
    m.words[0]=0xDA516001u;m.words[88]=2;m.words[89]=0x4d493136u;
    for(unsigned ch=0;ch<16;ch++) {
        int32_t v=1024*(int32_t)(ch+1);uint64_t e=(uint64_t)(v*v)*1024;
        m.words[8+ch*5]=(uint32_t)(v*1024);m.words[9+ch*5]=(uint32_t)e;
        m.words[10+ch*5]=(uint32_t)(e>>32);m.words[11+ch*5]=(uint32_t)v;m.words[12+ch*5]=0;
    }
    m.words[88]=2;m.words[89]=0x4d493136u;mic_levels_poll(&bus,&levels);
    assert(levels.valid && levels.channels==16 && levels.rms_ppm[15]==500000);
    assert(levels.mean_ppm[8]==281250 && levels.peak_ppm[15]==500000);
    m.words[0]=0xda516002u;m.words[90]=2;m.words[91]=1;
    m.words[2]=773;m.words[6]=423071;m.words[7]=423000;
    mic_location_poll(&bus,&levels);
    assert(levels.loc_enabled && levels.loc_grid_w==32 && levels.loc_valid && levels.loc_grid==773);
    m.words[96]=0x4c515431u;m.words[97]=4;m.words[98]=10;m.words[99]=778;
    m.words[90]=4;mic_location_poll(&bus,&levels);
    assert(levels.loc_quality_supported&&!levels.loc_valid&&levels.loc_reason==4&&levels.loc_raw_grid==778);
    m.words[96]=0;
    m.words[2]=1024;m.words[90]=4;mic_location_poll(&bus,&levels);assert(!levels.loc_valid);
    m.words[0]=0xda516001u;mic_location_poll(&bus,&levels);assert(!levels.loc_enabled&&!levels.loc_valid&&!levels.loc_quality_supported);
    m.words[0]=0xda512001u;m.words[89]=0x4d493132u;mic_levels_poll(&bus,&levels);
    assert(levels.valid && levels.channels==12 && levels.rms_ppm[11]==375000);
    mic_location_poll(&bus,&levels);assert(!levels.loc_enabled&&!levels.loc_valid);
    m.words[0]=0xda512002u;m.words[2]=773;m.words[90]=6;m.words[91]=1;
    m.words[96]=0x4c515431u;m.words[97]=0;m.words[98]=100;m.words[99]=773;
    mic_location_poll(&bus,&levels);
    assert(levels.loc_enabled&&levels.loc_valid&&levels.loc_grid_w==32&&levels.loc_quality_supported);
    m.words[0]=0xda508002u;m.words[88]=4;m.words[89]=0x4d493038u;
    mic_levels_poll(&bus,&levels);
    assert(levels.valid && levels.channels==8 && levels.rms_ppm[7]==250000);
    m.words[2]=773;m.words[90]=8;m.words[91]=1;
    mic_location_poll(&bus,&levels);
    assert(levels.loc_enabled&&levels.loc_valid&&levels.loc_grid_w==32);
    m.words[0]=0xda508001u;mic_location_poll(&bus,&levels);
    assert(!levels.loc_enabled&&!levels.loc_valid);
    puts("MIC_LEVELS_PASS: planar8 and legacy levels, location seqlock");
}
