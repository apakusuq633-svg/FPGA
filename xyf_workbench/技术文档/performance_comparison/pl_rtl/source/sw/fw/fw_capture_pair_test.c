#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "fw_location_quality.h"
static uint32_t capture[2][4096],registers[16],reads;
static uint32_t *cap(unsigned i)
{
    if(i==8){reads++;return &capture[registers[3]][registers[7]];}
    return &registers[i];
}
#define CAP(i) (*cap(i))
#include "fw_capture_pair.h"
static uint32_t stats[16][5];static int16_t low[1024],high[1024];
int main(void)
{
    for(unsigned channels=8;channels<=16;channels+=4)for(unsigned mode=0;mode<4;mode++) {
        uint32_t expected[16][5]={0};
        for(unsigned ch=0;ch<channels;ch++) {
            int32_t sum=0;uint64_t energy=0;uint32_t peak=0,clipped=0;
            for(unsigned n=0;n<1024;n++) {
                int32_t v=mode==0?0:mode==1?-32768:mode==2?32767:(int16_t)(n*97+ch*311);
                unsigned at=(n%512)*(channels/2)+ch/2,shift=16*(ch&1);
                if(!(ch&1))capture[n/512][at]=0;
                capture[n/512][at]|=(uint32_t)(uint16_t)v<<shift;
                sum+=v;energy+=(uint32_t)(v*v);uint32_t a=v<0?(uint32_t)-v:(uint32_t)v;
                if(a>peak)peak=a;
                if(v==32767||v==-32768)clipped++;
            }
            expected[ch][0]=(uint32_t)sum;expected[ch][1]=(uint32_t)energy;
            expected[ch][2]=(uint32_t)(energy>>32);expected[ch][3]=peak;expected[ch][4]=clipped;
        }
        reads=0;
        for(unsigned ch=0;ch<channels;ch+=2) {
            capture_pair(ch,channels,stats,low,high);
            for(unsigned n=0;n<1024;n++) {
                uint32_t w=capture[n/512][(n%512)*(channels/2)+ch/2];
                assert(low[n]==(int16_t)w&&high[n]==(int16_t)(w>>16));
            }
        }
        assert(reads==channels*512);
        for(unsigned ch=0;ch<channels;ch++)for(unsigned k=0;k<5;k++)assert(stats[ch][k]==expected[ch][k]);
        capture_pair(0,channels,stats,0,0);
    }
    unsigned valid;
    assert(location_axis_offset(8,10,6,&valid)==-10922&&valid);
    assert(location_axis_offset(10,10,10,&valid)==0&&!valid);
    assert(location_axis_offset(12,10,6,&valid)==0&&!valid);
    assert(location_axis_offset(INT32_MIN,10,6,&valid)==0&&!valid);
    assert(location_axis_offset(3000000,3500000,3250000,&valid)>0&&valid);
    puts("CAPTURE_PAIR_PASS channels=8,12,16 modes=zero,negative_full,positive_full,random statistics=all5 read_transactions=half subgrid_guards=1");
    return 0;
}
