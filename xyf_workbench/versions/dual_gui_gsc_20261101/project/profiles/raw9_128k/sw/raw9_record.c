#include "raw9_record.h"
#include "pdm_stream.h"
#include <string.h>
static uint32_t u32(const uint8_t*p){return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;}
void raw9_init(raw9_record*r,raw9_sink s,void*c){memset(r,0,sizeof(*r));r->sink=s;r->context=c;}
int raw9_flush(raw9_record*r){
 if(r->failed)return -1;
 if(r->used){int rc=r->sink(r->context,r->block,r->used);
 if(rc<0){r->write_errors++;r->failed=1;return -1;}
 if(!rc)return 0;
 r->used=0;}
 if(r->frames==RAW9_FRAMES)r->complete=1;
 return 1;
}
int raw9_feed(raw9_record*r,const uint8_t p[128]){
 if(r->failed||r->complete||r->frames==RAW9_FRAMES)return -1;
 if(pdm_slot_validate(p,u32(p+72))||u32(p)!=0x47534302u){r->failed=1;return -1;}
 uint32_t sample=u32(p+4),drops=u32(p+76),tap=u32(p+60);
 uint64_t clock=u32(p+64)|(uint64_t)u32(p+68)<<32;
 if(!r->started){r->started=1;r->start_sample=sample;r->next_sample=sample;
 r->first_clock=clock;r->drops_base=drops;r->tap_base=tap;}
 if(sample!=r->next_sample||(r->frames&&(clock-r->last_clock<312||clock-r->last_clock>313))){r->gap_count++;r->failed=1;return -1;}
 if(drops!=r->drops_base||tap!=r->tap_base){r->overflow_count++;r->failed=1;return -1;}
 if(r->used==sizeof(r->block)&&raw9_flush(r)<=0){if(!r->failed)r->overflow_count++;r->failed=1;return -1;}
 memcpy(r->block+r->used,p+32,18);r->used+=18;r->frames++;r->next_sample=sample+1;r->last_clock=clock;
 return 1;
}
