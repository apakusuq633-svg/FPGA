#include <assert.h>
#include <stdio.h>
#include "fw/fw_location_quality.h"
int main(void)
{
    int16_t x[1024];
    for(unsigned n=0;n<1024;n++)x[n]=10000+(n&1?30:-30);
    assert(location_prepare(x,1024)==30);
    for(unsigned n=0;n<1024;n++)assert(x[n]==(n&1?15360:-15360));
    for(unsigned n=0;n<1024;n++)x[n]=-32768;
    assert(!location_prepare(x,1024));
    for(unsigned n=0;n<1024;n++)assert(!x[n]);
    int16_t endpoints[2]={-32768,32767};location_prepare(endpoints,2);
    assert(endpoints[0]==-16384&&endpoints[1]==16383);
    assert(location_input_reason(10240000,102400000000ull,0)==LOCATION_SILENT);
    assert(location_input_reason(0,1024*900u,16)==LOCATION_BAD_INPUT);
    assert(!location_input_reason(0,1024*900u,0));
    assert(location_input_reason(33553408,1024ull*32767*32767,1024)==(LOCATION_SILENT|LOCATION_BAD_INPUT));

    int32_t p[1024];uint32_t contrast;int32_t far;
    for(unsigned n=0;n<1024;n++)p[n]=100;
    p[773]=320;p[774]=319;
    assert(!location_map_reason(p,32,4,773,&contrast,&far)&&contrast==687&&far==100);
    p[250]=319;
    assert(location_map_reason(p,32,4,773,&contrast,&far)==LOCATION_AMBIGUOUS);
    p[773]=200;p[774]=200;
    assert(location_map_reason(p,32,4,250,&contrast,&far)==0);
    for(unsigned n=0;n<1024;n++)p[n]=0;
    p[773]=120*32767;
    assert(!location_map_reason(p,32,120,773,&contrast,&far)&&contrast==1000);
    p[773]=120*63;
    assert(location_map_reason(p,32,120,773,&contrast,&far)==LOCATION_WEAK);

    location_tracker s={0};
    assert(location_track(&s,773,32,0)==LOCATION_CONFIRMING);
    assert(!location_track(&s,773,32,0)&&s.known&&s.grid==773);
    unsigned distinct[5]={0};
    for(unsigned n=0;n<120;n++) {
        unsigned raw=773+n%5-2;distinct[n%5]++;
        assert(!location_track(&s,raw,32,0)&&s.grid==773);
    }
    for(unsigned n=0;n<5;n++)assert(distinct[n]);
    assert(location_track(&s,250,32,0)==LOCATION_CONFIRMING&&s.grid==773);
    assert(!location_track(&s,773,32,0)&&s.grid==773);
    assert(location_track(&s,250,32,0)==LOCATION_CONFIRMING&&s.grid==773);
    assert(location_track(&s,250,32,0)==LOCATION_CONFIRMING&&s.grid==773);
    assert(!location_track(&s,250,32,0)&&s.grid==250);
    for(unsigned n=0;n<3;n++)assert(location_track(&s,0,32,LOCATION_WEAK)==LOCATION_WEAK&&s.grid==250);
    assert(!s.known&&location_track(&s,773,32,0)==LOCATION_CONFIRMING);
    assert(!location_track(&s,773,32,0)&&s.grid==773);
    assert(0x2800u+4u*LOCATION_META4_WORD==0x38e0u);
    assert(LOCATION_META16_WORD+8u<=128u);
    puts("LOCATION_QUALITY_PASS: DC/full-scale, weak/ambiguous/input rejection, 5 raw cells -> 1 stable cell, isolated jump rejected, sustained jump accepted at frame 3");
}
