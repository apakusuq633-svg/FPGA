#include "c9_scalar.h"
#include "fw_fft.h"
#ifdef C9S_PROFILE
volatile uint32_t c9s_phase_cycles[4];
static uint32_t c9s_cycles(void){uint32_t n;__asm__ volatile("rdcycle %0\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop\n\tnop":"=r"(n)::"memory");return n;}
#define STAMP() (stamp=c9s_cycles())
#define END_PHASE(i) (c9s_phase_cycles[i]+=c9s_cycles()-stamp)
#else
#define STAMP() ((void)0)
#define END_PHASE(i) ((void)0)
#endif

static int16_t low16(int32_t x){uint32_t u=(uint32_t)x&65535u;return (int16_t)(u<32768u?(int32_t)u:(int32_t)u-65536);}
static int32_t low32(int64_t x){uint32_t u=(uint32_t)(uint64_t)x;return u<0x80000000u?(int32_t)u:(int32_t)((int64_t)u-4294967296LL);}
/* Explicit floor right shifts avoid implementation-defined negative shifts. */
static int32_t asr32(int32_t x,unsigned n){return x>=0?(int32_t)((uint32_t)x>>n):~(int32_t)((uint32_t)~x>>n);}
static uint32_t pack(int16_t re,int16_t im){return (uint16_t)re|((uint32_t)(uint16_t)im<<16);}
static uint32_t phat(uint32_t x,uint32_t y){
 static const uint16_t reciprocal[16]={15888,14895,14014,13233,12537,11915,11357,10855,10402,9993,9621,9281,8969,8682,8417,8192};
 int32_t ar=low16((int32_t)x),ai=low16((int32_t)(x>>16));
 int32_t br=low16((int32_t)y),bi=-low16((int32_t)(y>>16));
 int32_t pr=low32((int64_t)ar*br-(int64_t)ai*bi);
 int32_t pi=low32((int64_t)ar*bi+(int64_t)ai*br);
 int16_t re=low16(asr32(low32((int64_t)pr+16384),15));
 int16_t im=low16(asr32(low32((int64_t)pi+16384),15));
 uint32_t a=re<0?(uint32_t)-(int32_t)re:(uint32_t)re;
 uint32_t b=im<0?(uint32_t)-(int32_t)im:(uint32_t)im;
 uint32_t big=a>b?a:b,small=a>b?b:a;
 uint32_t mag=(big+(small>>1)-(small>>3)+(small>>5)+(small>>7))&65535u;
 unsigned e=0;for(unsigned bit=0;bit<16;bit++)if(mag&(1u<<bit))e=bit;
 uint32_t mant=e>=14?mag>>(e-14):mag<<(14-e);
 uint32_t coefficient=mag?reciprocal[(mant>>10)&15u]:16384u;
 return pack(low16(asr32((int32_t)re*(int32_t)coefficient,e)),
             low16(asr32((int32_t)im*(int32_t)coefficient,e)));
}
static unsigned delay10(const uint8_t *lut,unsigned index){
 unsigned bit=index*10u,byte=bit>>3;
 return ((unsigned)lut[byte]|((unsigned)lut[byte+1]<<8))>>(bit&7u)&1023u;
}
void c9s_locate(const int16_t *raw,const uint8_t *lut,const int16_t *hann,
               c9s_workspace *w,int16_t *correlations,int32_t *scores){
#ifdef C9S_PROFILE
 uint32_t stamp;for(unsigned i=0;i<4;i++)c9s_phase_cycles[i]=0;
#endif
 for(unsigned ch=0;ch<9;ch++){
  STAMP();
  int32_t sum=0,minimum=32767,maximum=-32768;uint64_t energy=0;uint32_t peak=0,clips=0;
  for(unsigned n=0;n<1024;n++){
   int32_t x=raw[n*9+ch];uint32_t a=x<0?(uint32_t)-x:(uint32_t)x;
   sum+=x;energy+=(uint32_t)(x*x);if(x<minimum)minimum=x;if(x>maximum)maximum=x;
   if(a>peak)peak=a;
   if(x==32767||x==-32768)clips++;
  }
  w->statistics[ch*5]=(uint32_t)sum;w->statistics[ch*5+1]=(uint32_t)energy;
  w->statistics[ch*5+2]=(uint32_t)(energy>>32);w->statistics[ch*5+3]=peak;w->statistics[ch*5+4]=clips;
  int32_t mean=sum/1024,lo=minimum-mean,hi=maximum-mean;
  uint32_t alo=lo<0?(uint32_t)-lo:(uint32_t)lo,ahi=hi<0?(uint32_t)-hi:(uint32_t)hi;
  uint32_t bound=alo>ahi?alo:ahi;unsigned left=0,right=0;
  while(bound&&bound<8192&&left<14){bound<<=1;left++;}
  while(bound>32767){bound=(bound+1)>>1;right++;}
  END_PHASE(0);STAMP();
  for(unsigned n=0;n<1024;n++){
   int32_t centered=(int32_t)raw[n*9+ch]-mean;
   int16_t scaled=low16(asr32(low32((int64_t)centered*(1u<<left)),right));
   w->time[n]=low16(asr32((int32_t)scaled*hann[n],14));
  }
  fft1024(w->time,w->bins);
  for(unsigned k=0;k<64;k++)w->spectrum[ch*64+k]=pack(w->bins[2*(k+2)],w->bins[2*(k+2)+1]);
  END_PHASE(1);
 }
 STAMP();
 for(unsigned g=0;g<1024;g++)scores[g]=0;
 END_PHASE(3);
 unsigned pair=0;
 for(unsigned a=0;a<9;a++)for(unsigned b=a+1;b<9;b++,pair++){
  STAMP();
  for(unsigned k=0;k<1026;k++)w->bins[k]=0;
  for(unsigned k=0;k<=50;k++){
   uint32_t z=phat(w->spectrum[a*64+k],w->spectrum[b*64+k]);
   w->bins[2*(k+2)]=low16((int32_t)z);w->bins[2*(k+2)+1]=low16((int32_t)(z>>16));
  }
  ifft512_real(w->bins,w->time);
  for(unsigned lag=0;lag<64;lag++){
   w->ring[lag]=w->time[lag<32?lag:1024-64+lag];
   if(correlations)correlations[pair*64+lag]=w->ring[lag];
  }
  END_PHASE(2);STAMP();
  for(unsigned g=0;g<1024;g++){
   unsigned q=delay10(lut,pair*1024+g),index=(q>>4)&63u,f=q&15u;
   int32_t v0=w->ring[index],diff=(int32_t)w->ring[(index+1)&63u]-v0;
   int32_t v=v0+asr32(diff*(int32_t)f,4);
   scores[g]=low32((int64_t)scores[g]+v);
  }
  END_PHASE(3);
 }
}
