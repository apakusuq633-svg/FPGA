#include "pdm_stream.h"
#include <limits.h>
static uint32_t get32(const uint8_t *p){return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
static void put16(uint8_t *p,uint16_t v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void put32(uint8_t *p,uint32_t v){for(unsigned i=0;i<4;i++)p[i]=(uint8_t)(v>>(8*i));}
static void increment(pdm_stream_ring *r,unsigned i,uint64_t n){if(UINT64_MAX-r->stats[i]<n)r->stats[i]=UINT64_MAX;else r->stats[i]+=n;}
uint32_t pdm_crc32(const uint8_t *p,size_t n){
 static const uint32_t table[16]={0x00000000,0x1db71064,0x3b6e20c8,0x26d930ac,
  0x76dc4190,0x6b6b51f4,0x4db26158,0x5005713c,0xedb88320,0xf00f9344,0xd6d6a3e8,
  0xcb61b38c,0x9b64c2b0,0x86d3d2d4,0xa00ae278,0xbdbdf21c};
 uint32_t c=~0u;
 for(size_t i=0;i<n;i++){c^=p[i];c=(c>>4)^table[c&15];c=(c>>4)^table[c&15];}
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
 if(!p||get32(p)!=0x47534301u||get32(p+72)!=owner||get32(p+124)!=~owner||
    get32(p+80)!=0x394d4450u||get32(p+84)!=128||get32(p+92)!=0x0010000cu)return -1;
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
 for(unsigned i=0;i<128;i++)slot[i]=memory[i];
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
  if(pdm_slot_validate(p,get32(p+72))||get32(p+88)!=m->calibration_version||reasons[f]>9||
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
