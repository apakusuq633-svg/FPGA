#include "circular9_audio.h"
#include "circular9_decimator.h"
void circular9_audio_init(circular9_audio *s){memset(s,0,sizeof(*s));}
int circular9_audio_store_direction(circular9_audio *s,uint32_t version,uint32_t epoch,
 unsigned grid,const uint32_t delay_q16[9]){
 if(!s||!delay_q16||!(version&0x80000000u)||version==0x80000000u||grid>=1024)return 0;
 int zero=0;for(unsigned ch=0;ch<9;ch++){
  if(delay_q16[ch]>=(61u<<16)||(delay_q16[ch]&4095u))return 0;
  if(!delay_q16[ch])zero=1;
 }
 if(!zero)return 0;
 for(unsigned i=0;i<C9_FINE_CACHE;i++){
  c9_audio_direction *d=&s->fine_cache[i];
  if(d->version==version&&d->epoch==epoch)
   return d->grid==grid&&!memcmp(d->delay_q16,delay_q16,sizeof(d->delay_q16));
 }
 c9_audio_direction *d=&s->fine_cache[s->fine_cache_head++%C9_FINE_CACHE];
 d->version=version;d->epoch=epoch;d->grid=grid;memcpy(d->delay_q16,delay_q16,sizeof(d->delay_q16));return 1;
}
int circular9_audio_push(circular9_audio *s,const uint32_t w[16],
 const uint32_t *lut,const uint32_t *fir,int enabled,int freeze,uint32_t drops,int16_t *output)
{
 if(!s||!w||!lut||!fir||!output||w[0]!=0x47534302u||w[13]!=0x000a0009u||(w[12]>>16))return -1;
 unsigned grid=(w[6]>>8)&1023u;
 int changed=s->have_sample&&(w[1]!=s->last_sample+1u||w[2]!=s->last_version||w[14]!=s->last_epoch);
 if(changed){s->count=0;s->filter_count=0;s->pending_flags=DAS_FLAG_GAP;s->discontinuities++;memset(s->filter_history,0,sizeof(s->filter_history));}
 s->have_sample=1;s->last_sample=w[1];s->last_version=w[2];s->last_epoch=w[14];
 if(!s->nominal_ps&&(w[6]&3u)==1u&&(!s->adaptive.configured||s->adaptive.config.version!=w[2]||
    s->adaptive.config.epoch!=w[14]||s->adaptive.config.direction_id!=grid)) {
  gsc9_config c={0};int32_t tau[9],minimum=0;
  c.version=w[2];c.epoch=w[14];c.direction_id=(uint16_t)grid;c.mu_q15=8192;c.epsilon=1u<<20;
  if(w[2]&0x80000000u){
   const c9_audio_direction *selected=NULL;
   for(unsigned i=0;i<C9_FINE_CACHE;i++){
    const c9_audio_direction *d=&s->fine_cache[i];
    if(d->version==w[2]&&d->epoch==w[14]&&d->grid==grid){selected=d;break;}
   }
   if(selected)memcpy(c.delay_q16,selected->delay_q16,sizeof(c.delay_q16));
   else goto no_direction_config;
  }else{
  for(unsigned ch=0;ch<9;ch++) {
   int32_t q=(int32_t)(lut[ch*1024+grid]&16383u);if(q&8192)q-=16384;
   tau[ch]=q*4096;if(tau[ch]<minimum)minimum=tau[ch];
  }
  for(unsigned ch=0;ch<9;ch++)c.delay_q16[ch]=(uint32_t)(tau[ch]-minimum);
  }
  for(unsigned i=0;i<32;i++)c.fir_q15[i]=(int16_t)(uint16_t)fir[i];
  if(gsc9_configure(&s->adaptive,&c))return -1;
  gsc9_set_target_guard(&s->adaptive,s->target_guard_requested!=0);
 }
no_direction_config:
 *output=s->nominal_ps?gsc9_process_nominal(&s->adaptive,w,enabled,freeze):gsc9_process(&s->adaptive,w,enabled,freeze);s->reason=gsc9_reason(&s->adaptive);
 if(s->nominal_ps)return 0; /* output-only; candidate diagnosis has its own raw history */
 uint32_t flags=0;
 if((w[6]&3u)!=1u||s->reason==GSC9_BYPASS_ALIGNMENT||s->reason==GSC9_BYPASS_METADATA||
    s->reason==GSC9_BYPASS_FORMAT||s->reason==GSC9_BYPASS_SEQUENCE||s->reason==GSC9_BYPASS_DIVERGENCE||s->reason==GSC9_BYPASS_UNCONFIGURED)
  flags|=DAS_FLAG_INVALID;
 if(*output==32767||*output==-32768)flags|=DAS_FLAG_CLIPPED;
 s->pending_flags|=flags;
 s->filter_history[s->filter_head]=*output;
 if(s->filter_count<127)s->filter_count++;
 int16_t diagnostic=0;
 if((w[1]&3u)==3u) {
  int64_t sum=0;for(unsigned j=0;j<127;j++)sum+=(int32_t)s->filter_history[(s->filter_head-j)&127u]*c9_decim_coeff[j];
  sum=sum>=0?(sum+16384)/32768:-((-sum+16384)/32768);
  diagnostic=sum>32767?32767:sum< -32768?-32768:(int16_t)sum;
 }
 s->filter_head=(s->filter_head+1)&127u;
 if((w[1]&3u)!=3u)return 0;
 if(s->filter_count<127)s->pending_flags|=DAS_FLAG_INVALID;
 flags=s->pending_flags;s->pending_flags=0;
 if(!s->count) {
  s->block.desc=(das_block_desc){w[1]/4u,s->block_sequence++,512,grid,32,w[2],flags,drops};
  if(changed)s->block.desc.flags|=DAS_FLAG_GAP;
 }
 s->block.desc.flags|=flags;s->block.desc.dropped_samples=drops;
 s->block.pcm[s->count++]=diagnostic;
 if(s->count==512){s->count=0;return 1;}
 return 0;
}
