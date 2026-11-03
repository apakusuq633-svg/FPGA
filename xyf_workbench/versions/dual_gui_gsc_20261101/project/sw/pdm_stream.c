#include "pdm_stream.h"
#include <limits.h>
#include <string.h>
static uint32_t get32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put16(uint8_t *p,uint16_t v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void put32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static void increment(pdm_stream_ring *r,unsigned i,uint64_t n){if(UINT64_MAX-r->stats[i]<n)r->stats[i]=UINT64_MAX;else r->stats[i]+=n;}
uint32_t pdm_crc32(const uint8_t *p,size_t n){
 /* CRC-32/ISO-HDLC, reflected polynomial 0xedb88320, init/xorout ~0.
  * One byte per lookup. Constant 1 KiB table: no lazy initialization or
  * mutable state, so slot validation and UDP CRC retain identical semantics. */
 static const uint32_t table[256]={
  0x00000000u,0x77073096u,0xee0e612cu,0x990951bau,0x076dc419u,0x706af48fu,0xe963a535u,0x9e6495a3u,
  0x0edb8832u,0x79dcb8a4u,0xe0d5e91eu,0x97d2d988u,0x09b64c2bu,0x7eb17cbdu,0xe7b82d07u,0x90bf1d91u,
  0x1db71064u,0x6ab020f2u,0xf3b97148u,0x84be41deu,0x1adad47du,0x6ddde4ebu,0xf4d4b551u,0x83d385c7u,
  0x136c9856u,0x646ba8c0u,0xfd62f97au,0x8a65c9ecu,0x14015c4fu,0x63066cd9u,0xfa0f3d63u,0x8d080df5u,
  0x3b6e20c8u,0x4c69105eu,0xd56041e4u,0xa2677172u,0x3c03e4d1u,0x4b04d447u,0xd20d85fdu,0xa50ab56bu,
  0x35b5a8fau,0x42b2986cu,0xdbbbc9d6u,0xacbcf940u,0x32d86ce3u,0x45df5c75u,0xdcd60dcfu,0xabd13d59u,
  0x26d930acu,0x51de003au,0xc8d75180u,0xbfd06116u,0x21b4f4b5u,0x56b3c423u,0xcfba9599u,0xb8bda50fu,
  0x2802b89eu,0x5f058808u,0xc60cd9b2u,0xb10be924u,0x2f6f7c87u,0x58684c11u,0xc1611dabu,0xb6662d3du,
  0x76dc4190u,0x01db7106u,0x98d220bcu,0xefd5102au,0x71b18589u,0x06b6b51fu,0x9fbfe4a5u,0xe8b8d433u,
  0x7807c9a2u,0x0f00f934u,0x9609a88eu,0xe10e9818u,0x7f6a0dbbu,0x086d3d2du,0x91646c97u,0xe6635c01u,
  0x6b6b51f4u,0x1c6c6162u,0x856530d8u,0xf262004eu,0x6c0695edu,0x1b01a57bu,0x8208f4c1u,0xf50fc457u,
  0x65b0d9c6u,0x12b7e950u,0x8bbeb8eau,0xfcb9887cu,0x62dd1ddfu,0x15da2d49u,0x8cd37cf3u,0xfbd44c65u,
  0x4db26158u,0x3ab551ceu,0xa3bc0074u,0xd4bb30e2u,0x4adfa541u,0x3dd895d7u,0xa4d1c46du,0xd3d6f4fbu,
  0x4369e96au,0x346ed9fcu,0xad678846u,0xda60b8d0u,0x44042d73u,0x33031de5u,0xaa0a4c5fu,0xdd0d7cc9u,
  0x5005713cu,0x270241aau,0xbe0b1010u,0xc90c2086u,0x5768b525u,0x206f85b3u,0xb966d409u,0xce61e49fu,
  0x5edef90eu,0x29d9c998u,0xb0d09822u,0xc7d7a8b4u,0x59b33d17u,0x2eb40d81u,0xb7bd5c3bu,0xc0ba6cadu,
  0xedb88320u,0x9abfb3b6u,0x03b6e20cu,0x74b1d29au,0xead54739u,0x9dd277afu,0x04db2615u,0x73dc1683u,
  0xe3630b12u,0x94643b84u,0x0d6d6a3eu,0x7a6a5aa8u,0xe40ecf0bu,0x9309ff9du,0x0a00ae27u,0x7d079eb1u,
  0xf00f9344u,0x8708a3d2u,0x1e01f268u,0x6906c2feu,0xf762575du,0x806567cbu,0x196c3671u,0x6e6b06e7u,
  0xfed41b76u,0x89d32be0u,0x10da7a5au,0x67dd4accu,0xf9b9df6fu,0x8ebeeff9u,0x17b7be43u,0x60b08ed5u,
  0xd6d6a3e8u,0xa1d1937eu,0x38d8c2c4u,0x4fdff252u,0xd1bb67f1u,0xa6bc5767u,0x3fb506ddu,0x48b2364bu,
  0xd80d2bdau,0xaf0a1b4cu,0x36034af6u,0x41047a60u,0xdf60efc3u,0xa867df55u,0x316e8eefu,0x4669be79u,
  0xcb61b38cu,0xbc66831au,0x256fd2a0u,0x5268e236u,0xcc0c7795u,0xbb0b4703u,0x220216b9u,0x5505262fu,
  0xc5ba3bbeu,0xb2bd0b28u,0x2bb45a92u,0x5cb36a04u,0xc2d7ffa7u,0xb5d0cf31u,0x2cd99e8bu,0x5bdeae1du,
  0x9b64c2b0u,0xec63f226u,0x756aa39cu,0x026d930au,0x9c0906a9u,0xeb0e363fu,0x72076785u,0x05005713u,
  0x95bf4a82u,0xe2b87a14u,0x7bb12baeu,0x0cb61b38u,0x92d28e9bu,0xe5d5be0du,0x7cdcefb7u,0x0bdbdf21u,
  0x86d3d2d4u,0xf1d4e242u,0x68ddb3f8u,0x1fda836eu,0x81be16cdu,0xf6b9265bu,0x6fb077e1u,0x18b74777u,
  0x88085ae6u,0xff0f6a70u,0x66063bcau,0x11010b5cu,0x8f659effu,0xf862ae69u,0x616bffd3u,0x166ccf45u,
  0xa00ae278u,0xd70dd2eeu,0x4e048354u,0x3903b3c2u,0xa7672661u,0xd06016f7u,0x4969474du,0x3e6e77dbu,
  0xaed16a4au,0xd9d65adcu,0x40df0b66u,0x37d83bf0u,0xa9bcae53u,0xdebb9ec5u,0x47b2cf7fu,0x30b5ffe9u,
  0xbdbdf21cu,0xcabac28au,0x53b39330u,0x24b4a3a6u,0xbad03605u,0xcdd70693u,0x54de5729u,0x23d967bfu,
  0xb3667a2eu,0xc4614ab8u,0x5d681b02u,0x2a6f2b94u,0xb40bbe37u,0xc30c8ea1u,0x5a05df1bu,0x2d02ef8du
 };
 uint32_t c=~0u;
 for(size_t i=0;i<n;i++)c=(c>>8)^table[(c^p[i])&255u];
 return ~c;
}
size_t pdm_stream_ring_size(void){return sizeof(pdm_stream_ring);}
static int write(pdm_stream_ring *r,uint32_t offset,uint32_t value){
 r->io.barrier(r->io.context);
 if(r->io.write_reg(r->io.context,offset,value)){increment(r,PDM_IO_ERRORS,1);return -4;}
 return 0;
}
static int idle(pdm_stream_ring *r,unsigned limit){
 for(unsigned i=0;i<limit;i++)if((r->io.read_reg(r->io.context,0x24)&7u)==0)return 0;
 increment(r,PDM_POLL_TIMEOUTS,1);return -5;
}
int pdm_ring_open(pdm_stream_ring *r,const pdm_stream_io *io,uint32_t base,unsigned log2,
                  uint32_t timeout,uint32_t calibration,uint32_t seed,uint32_t stream,unsigned polls){
 if(!r||!io||!io->read_reg||!io->write_reg||!io->invalidate||!io->flush||!io->barrier||!io->map||
    log2<4||log2>12||timeout<16||!polls||(base&127u)||base<0x01000000u||
    (uint64_t)base+((uint64_t)128<<log2)>0x10000000ull)return -1;
 pdm_stream_ring initial={0};*r=initial;r->io=*io;r->base=base;r->slots_log2=log2;
 r->calibration_version=calibration;r->consumer=seed;r->stream_id=stream;
 if(io->read_reg(io->context,0)!=0x394d4450u)return -2;
 int result=write(r,4,0);if(result)return result;result=idle(r,polls);if(result)return result;
 if(io->read_reg(io->context,0x14)!=io->read_reg(io->context,0x10))return -2;
 if(write(r,4,6)||write(r,8,base)||write(r,12,log2)||write(r,0x28,timeout)||
    write(r,0x40,seed)||write(r,0x44,calibration))return -4;
 io->flush(io->context,base,(size_t)128<<log2);io->barrier(io->context);
 if(write(r,4,1))return -4;
 if(io->read_reg(io->context,8)!=base||io->read_reg(io->context,12)!=log2||
    io->read_reg(io->context,0x10)!=seed||io->read_reg(io->context,0x44)!=calibration){increment(r,PDM_IO_ERRORS,1);return -4;}
 r->opened=1;return 0;
}
int pdm_slot_validate(const uint8_t p[128],uint32_t owner){
 if(!p)return -1;
 int v2=get32(p)==0x47534302u;
 if((!v2&&get32(p)!=0x47534301u)||get32(p+72)!=owner||get32(p+124)!=~owner||
    get32(p+80)!=0x394d4450u||get32(p+84)!=128||get32(p+92)!=(v2?0x00100009u:0x0010000cu))return -1;
 if(v2&&(get32(p+52)!=0x000a0009u||(get32(p+48)>>16)))return -1;
 if(get32(p+120)!=pdm_crc32(p,120))return -1;
 for(unsigned i=96;i<120;i++)if(p[i])return -1;
 return 0;
}
int pdm_ring_next(pdm_stream_ring *r,uint8_t slot[PDM_SLOT_BYTES]){
 if(!r||!r->opened||!slot)return -1;
 uint32_t producer=r->io.read_reg(r->io.context,0x14),available=producer-r->consumer;
 if(available>(1u<<r->slots_log2)){increment(r,PDM_OWNER_ERRORS,1);return -2;}
 if(!available)return 0;
 uint32_t address=r->base+((r->consumer&((1u<<r->slots_log2)-1))<<7);
 r->io.barrier(r->io.context);r->io.invalidate(r->io.context,address,128);r->io.barrier(r->io.context);
 const uint8_t *memory=r->io.map(r->io.context,address,128);
 if(!memory){increment(r,PDM_IO_ERRORS,1);return -4;}
 /* Copy uncached DMA payload in compiler/libc word bursts, retaining CRC and ownership checks. */
 memcpy(slot,memory,128);
 int valid=pdm_slot_validate(slot,r->consumer)==0&&get32(slot+88)==r->calibration_version;
 uint32_t next=r->consumer+1u;
 if(write(r,0x10,next))return -4;
 r->consumer=next;
 if(!valid){increment(r,PDM_CORRUPT,1);return -3;}
 uint32_t sample=get32(slot+4);uint64_t timestamp=get32(slot+64)|(uint64_t)get32(slot+68)<<32;
 if(r->have_sample){
  if(sample==r->last_sample&&timestamp==r->last_timestamp){increment(r,PDM_DUPLICATES,1);return -3;}
  if(timestamp<=r->last_timestamp){
   increment(r,PDM_TIMESTAMP_ROLLBACKS,1);increment(r,PDM_SOURCE_RESTARTS,1);r->stream_id++;
  }else{
   uint32_t delta=sample-r->last_sample;
   if(delta==0){increment(r,PDM_DUPLICATES,1);return -3;}
   if(delta>=0x80000000u){increment(r,PDM_OUT_OF_ORDER,1);return -3;}
   increment(r,PDM_SAMPLE_GAPS,delta-1u);
  }
 }
 r->last_sample=sample;r->last_timestamp=timestamp;r->have_sample=1;
 increment(r,PDM_FRAME_OK,1);return 1;
}
int pdm_ring_recover(pdm_stream_ring *r,unsigned polls){
 if(!r||!r->opened||!polls)return -1;
 int result=write(r,4,0);if(result)return result;result=idle(r,polls);if(result)return result;
 if(write(r,4,6)||write(r,4,1))return -4;
 increment(r,PDM_RECOVERIES,1);return 0;
}
uint64_t pdm_ring_stat(const pdm_stream_ring *r,unsigned i){return r&&i<PDM_STREAM_STATS?r->stats[i]:0;}
uint32_t pdm_ring_stream_id(const pdm_stream_ring *r){return r?r->stream_id:0;}
size_t pdm_udp_encode(const pdm_udp_metadata *m,const uint8_t *slots,const int16_t *gsc,const uint16_t *reasons,
                     unsigned frames,uint8_t *out,size_t capacity){
 size_t length=48u+132u*frames+4u;
 if(!m||!slots||!gsc||!reasons||!out||frames<1||frames>8||capacity<length||
    !(m->flags&2u)||(m->flags&~31u)||(!m->calibration_version&&!(m->flags&4u)))return 0;
 for(unsigned f=0;f<frames;f++){
  const uint8_t *p=slots+128*f;
  if(get32(p)!=0x47534301u||pdm_slot_validate(p,get32(p+72))||get32(p+88)!=m->calibration_version||reasons[f]>9||
     (!(m->flags&1u)&&reasons[f]==0)||
     (reasons[f]!=0&&(uint16_t)gsc[f]!=(uint16_t)(get32(p+28)>>16)))return 0;
  if(f){
   uint32_t delta=get32(p+4)-get32(p-128+4);
   uint64_t now=get32(p+64)|(uint64_t)get32(p+68)<<32;
   uint64_t prior=get32(p-128+64)|(uint64_t)get32(p-128+68)<<32;
   if(!delta||delta>=0x80000000u||now<=prior)return 0;
  }
 }
 put32(out,0x394d4450);put16(out+4,1);put16(out+6,48);put32(out+8,m->stream_id);
 put32(out+12,m->packet_sequence);put32(out+16,get32(slots+4));put16(out+20,(uint16_t)frames);put16(out+22,12);
 put32(out+24,390625);put16(out+28,16);put16(out+30,m->flags);put32(out+32,m->calibration_version);
 put32(out+36,132u*frames);put32(out+40,m->dma_drops);put32(out+44,40000000);
 for(unsigned f=0;f<frames;f++){
  uint8_t *p=out+48+132*f;for(unsigned i=0;i<128;i++)p[i]=slots[128*f+i];
  put16(p+128,(uint16_t)gsc[f]);put16(p+130,reasons[f]);
 }
 put32(out+length-4,pdm_crc32(out,length-4));return length;
}
