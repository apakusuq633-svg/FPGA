#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "sw/circular9_candidates.c"
static int16_t raw[C9_SEARCH_RAW_FRAMES][9];
static c9_separation_workspace w;
int main(void){
 uint32_t seed=7,invalid;unsigned checks=0;
 unsigned magnitude=0;for(unsigned j=0;j<127;j++)magnitude+=c9_decim_coeff[j]<0?-c9_decim_coeff[j]:c9_decim_coeff[j];
 assert(magnitude==55056u && 32768ull*magnitude<2147483648ull);
 const unsigned lengths[]={128,132,256,8448,C9_SEARCH_RAW_FRAMES};
 for(unsigned pattern=0;pattern<5;pattern++){
  for(unsigned i=0;i<C9_SEARCH_RAW_FRAMES;i++)for(unsigned ch=0;ch<9;ch++){
   seed=seed*1664525u+1013904223u;
   raw[i][ch]=pattern==0?(int16_t)(seed>>16):pattern==1?32767:pattern==2?-32768:pattern==3?(i&1?32767:-32768):(i==127?30000:0);
  }
  for(unsigned length=0;length<5;length++){
   unsigned frames=lengths[length];prepare_samples(raw,frames,&w,&invalid,NULL);
   for(unsigned ch=0;ch<9;ch++)for(unsigned n=0;n<frames/4;n++){
    int index=(int)(4*n+3);int64_t sum=0;
    for(int j=0;j<63;j++){
     int v=index>=j?raw[index-j][ch]:0;if(index>=126-j)v+=raw[index-126+j][ch];sum+=(int64_t)v*c9_decim_coeff[j];
    }
    if(index>=63)sum+=(int64_t)raw[index-63][ch]*c9_decim_coeff[63];
    float expected=(float)(sum/(32768.0*32768.0));assert(expected==w.decimated[ch][n]);checks++;
   }
  }
 }
 printf("DECIMATOR_BIT_EXACT_PASS %u samples\n",checks);return 0;
}
