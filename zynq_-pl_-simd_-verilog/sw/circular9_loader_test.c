/* Native MMIO model: checks boot ordering and fail-closed write acceptance.
 * This is not execution on a Cortex-A9 or a proof of physical table RAM. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define UI_DAS_ACTIVE_CHANNELS 9
#include "ps_pl_live.h"
typedef struct {
 uint32_t itcm[8192],dtcm[8192],fir[32],gains[5],ptr,fp,sp,rp;
 unsigned stopped,pdm_disabled,halted,started,steer_words,srp_words;
 unsigned bad_rate,bad_gain,bad_fir,bad_steer,bad_srp,short_steer,short_srp,halt_timeout,bad_extension;
} device;
static uint32_t rd(void *ctx,uint32_t off){
 device *m=ctx;
 switch(off){
 case 0x39c:return 0x44415301u;
 case 0x3c0:return 9;
 case 0x3f0:return m->bad_extension?0:0x43395831u;
 case 0x3e4:return m->bad_rate?32:16;
 case 0x3e8:return 512;
 case 0x3ec:return 64;
 case 0x3c4:return 0x41435303u;
 case 0x41c:return 0x00120000u;
 case 4:return m->halt_timeout?0:4;
 case 0x88:{uint32_t i=m->ptr++&0x7fffffffu;assert(i<8192);return (m->ptr&0x80000000u)?m->dtcm[i]:m->itcm[i];}
 case 0xc8:assert(m->fp<32);return m->fir[m->fp++]^m->bad_fir;
 case 0x604:return 4u|(m->bad_steer?8u:0u);
 case 0x608:return m->sp;
 case 0x404:return 4u|(m->bad_srp?8u:0u);
 case 0x408:return m->rp;
 default:assert(off>=0x340&&off<=0x350&&!(off&3u));return m->gains[(off-0x340)/4]^m->bad_gain;
 }
}
static void wr(void *ctx,uint32_t off,uint32_t value){
 device *m=ctx;
 if(off>=0x340&&off<=0x350){assert(m->halted&&m->pdm_disabled&&!m->started);m->gains[(off-0x340)/4]=value;return;}
 switch(off){
 case 0x380:if(value==4)m->stopped=1;else{assert(value==61&&m->halted);m->started++;}break;
 case 0x3f0:assert(value==0x4f464631u);break;
 case 0x3f4:assert(value==64u);break;
 case 0x3f8:assert(value==0u);break;
 case 0x300:assert(!value&&m->stopped);m->pdm_disabled=1;break;
 case 0:if(value==18){assert(m->stopped&&m->pdm_disabled);m->halted=1;}break;
 case 0x8c:assert(value==2&&m->halted);break;
 case 0x80:m->ptr=value;break;
 case 0x84:{uint32_t i=m->ptr&0x7fffffffu;assert(i<8192);if(m->ptr&0x80000000u)m->dtcm[i]=value;else m->itcm[i]=value;m->ptr++;break;}
 case 0xc0:assert(value==0x400);m->fp=0;break;
 case 0xc4:assert(m->fp<32);m->fir[m->fp++]=value;break;
 case 0x600:case 0x400:assert(value==14&&m->halted&&!m->started);break;
 case 0x608:m->sp=value;m->steer_words=0;break;
 case 0x408:m->rp=value;m->srp_words=0;break;
 case 0x60c:assert(value==acoustic_steer_lut[m->steer_words++]);if(!m->short_steer||m->steer_words!=17)m->sp=(m->sp+1)%9216;break;
 case 0x40c:assert(value==acoustic_srp_lut[m->srp_words++]);if(!m->short_srp||m->srp_words!=17)m->rp=(m->rp+1)%36864;break;
 default:assert(0);
 }
}
static device m;
int main(void){
 das_bus b={&m,rd,wr};
 /* Registers deliberately begin dirty, including the inactive capture slot. */
 memset(m.gains,0xa5,sizeof(m.gains));
 assert(pl_live_prepare(&b)==0&&!m.started);
 for(unsigned i=0;i<4;i++)assert(m.gains[i]==(acoustic_gain_q14[2*i]|acoustic_gain_q14[2*i+1]<<16));
 assert(m.gains[4]==acoustic_gain_q14[8]&&m.steer_words==9216&&m.srp_words==36864);
 pl_live_start(&b);assert(m.started==1);
 #define NEGATIVE(field,expected) do {memset(&m,0,sizeof(m));m.field=1;assert(pl_live_prepare(&b)==(expected));assert(!m.started);}while(0)
 NEGATIVE(bad_rate,-10);NEGATIVE(halt_timeout,-2);NEGATIVE(bad_gain,-11);
 NEGATIVE(bad_fir,-4);NEGATIVE(bad_steer,-12);NEGATIVE(short_steer,-12);
 NEGATIVE(bad_srp,-8);NEGATIVE(short_srp,-13);
 NEGATIVE(bad_extension,-14);
 puts("CIRCULAR9_LOADER_PASS dirty-gains reset/readback, stopped capture, ABI/timeout/FIR/LUT rejection; native MMIO model only");
 return 0;
}
