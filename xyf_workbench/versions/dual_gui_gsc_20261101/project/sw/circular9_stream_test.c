#include <assert.h>
#include <stdio.h>
#include "circular9_audio.h"
#include "circular9_stream.h"
static void put(uint8_t *p,uint32_t v){for(unsigned k=0;k<4;k++)p[k]=(uint8_t)(v>>(8*k));}
static uint32_t lut[9*1024],fir[32]={32767};
int main(int argc,char **argv)
{
 circular9_audio s;circular9_audio_init(&s);int16_t out=0;
 uint32_t w[16]={0x47534302,0,1,0,1,65536,1,0};w[13]=0x000a0009;
 for(unsigned ch=0;ch<9;ch++)w[8+ch/2]|=123u<<(16*(ch&1));
 w[7]=123u|(122u<<16);
 for(unsigned n=0;n<4096;n++) {
  w[1]=n;int rc=circular9_audio_push(&s,w,lut,fir,1,0,0,&out);
  assert(rc==(n%2048==2047));assert(out==122);
  if(rc){assert(s.block.desc.first_sample==n/4-511);assert(s.block.desc.sample_count==512);}
 }
 assert(s.reason==GSC9_OK && s.adaptive.stats[GSC9_ACTIVE]==3584);
 /* A gap discards only partial assembly; output falls back immediately. */
 w[1]=4103;assert(circular9_audio_push(&s,w,lut,fir,1,0,6,&out)==0);
 assert(out==122 && s.reason==GSC9_BYPASS_SEQUENCE && s.count==1 && s.discontinuities==1);
 assert(s.block.desc.flags&DAS_FLAG_GAP);
 w[1]++;w[2]++;assert(circular9_audio_push(&s,w,lut,fir,1,0,6,&out)==0);
 assert(s.adaptive.config.version==2 && s.count==0);
 w[1]++;w[6]=0;assert(circular9_audio_push(&s,w,lut,fir,1,0,6,&out)==0);
 assert(s.pending_flags&DAS_FLAG_INVALID);
 uint8_t slots[256]={0},packet[C9_MAX_PACKET];int16_t output[2]={122,122};uint16_t reason[2]={1,1};
 for(unsigned i=0;i<2;i++) {
  uint8_t *p=slots+128*i;w[1]=i;w[6]=1;
  for(unsigned k=0;k<16;k++)put(p+4*k,w[k]);
  put(p+64,1000+i*1024);put(p+72,i);put(p+80,0x394d4450);put(p+84,128);put(p+92,0x00100009);
  put(p+120,pdm_crc32(p,120));put(p+124,~i);
  assert(pdm_slot_validate(p,i)==0);
 }
 circular9_metadata meta={1,0,123,0,0,0,3};
 size_t n=circular9_encode(&meta,slots,output,reason,2,packet,sizeof(packet));assert(n==332);
 if(argc==2){FILE *f=fopen(argv[1],"wb");assert(f);assert(fwrite(packet,1,n,f)==n);fclose(f);}
 for(unsigned i=0;i<128;i++){slots[i]^=1;assert(!circular9_encode(&meta,slots,output,reason,2,packet,sizeof(packet)));slots[i]^=1;}
 output[0]=121;assert(!circular9_encode(&meta,slots,output,reason,2,packet,sizeof(packet)));output[0]=122;
 pdm_udp_metadata old={1,0,0,0,6};assert(!pdm_udp_encode(&old,slots,output,reason,2,packet,sizeof(packet)));
 puts("CIRCULAR9_STREAM_PASS blocks=2 corruption_checks=128");return 0;
}
