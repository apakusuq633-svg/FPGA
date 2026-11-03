#include "circular9_stream.h"
#include "circular9_profile.h"
static uint32_t get(const uint8_t *p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put(uint8_t *p,uint32_t v){for(unsigned k=0;k<4;k++)p[k]=(uint8_t)(v>>(8*k));}
size_t circular9_encode(const circular9_metadata *m,const uint8_t *slots,
 const int16_t *output,const uint16_t *reason,unsigned n,uint8_t *p,size_t capacity)
{
 size_t bytes=C9_HEADER_BYTES+C9_FRAME_BYTES*n+4;
 if(!m||!slots||!output||!reason||!p||!n||n>C9_MAX_FRAMES||capacity<bytes||
    (m->flags&~3u)||(!m->calibration_version&&!(m->flags&2u)))return 0;
 for(unsigned i=0;i<n;i++) {
  const uint8_t *s=slots+128*i;
  if(get(s)!=0x47534302u||pdm_slot_validate(s,get(s+72))||get(s+88)!=m->calibration_version||reason[i]>9||
     (reason[i]==0&&!(m->flags&1u))||
     (reason[i]!=0&&(uint16_t)output[i]!=(uint16_t)(get(s+28)>>16)))return 0;
  if(i) {
   const uint8_t *old=s-128;uint32_t delta=get(s+4)-get(old+4);
   uint64_t t=get(s+64)|(uint64_t)get(s+68)<<32,prior=get(old+64)|(uint64_t)get(old+68)<<32;
   if(!delta||delta>=0x80000000u||t<=prior)return 0;
  }
 }
 uint32_t h[16]={0x32433943u,2u,C9_HEADER_BYTES,m->session,m->sequence,n,
  0x000a0009u,0x1ffu,ACOUSTIC_SAMPLE_RATE_NUM,ACOUSTIC_SAMPLE_RATE_DEN,40000000u,m->geometry_version,m->calibration_version,
  m->dma_drops,m->software_drops,m->flags};
 for(unsigned k=0;k<16;k++)put(p+4*k,h[k]);
 for(unsigned i=0;i<n;i++) {
  uint8_t *d=p+C9_HEADER_BYTES+C9_FRAME_BYTES*i;
  for(unsigned k=0;k<128;k++)d[k]=slots[128*i+k];
  put(d+128,(uint16_t)output[i]|(uint32_t)reason[i]<<16);
 }
 put(p+bytes-4,pdm_crc32(p,bytes-4));return bytes;
}
