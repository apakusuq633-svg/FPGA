#include "gsc12.h"
#include <limits.h>
static void zero(void *memory,size_t n) {
 uint8_t *p=(uint8_t *)memory;
 for(size_t i=0;i<n;i++)p[i]=0;
}
static void count(gsc12_state *s,unsigned i,uint64_t n) {
 if(UINT64_MAX-s->stats[i]<n)s->stats[i]=UINT64_MAX;else s->stats[i]+=n;
}
static int16_t clip16(int64_t x) {return x>32767?32767:x< -32768?-32768:(int16_t)x;}
static int64_t floor_power(int64_t x,unsigned p) {
 return x>=0?x/((int64_t)1<<p):-((-x+(((int64_t)1<<p)-1))/((int64_t)1<<p));
}
static void clear_weights(gsc12_state *s) {
 zero(s->weight,sizeof(s->weight));zero(s->reference_history,sizeof(s->reference_history));
}
static void clear_signal(gsc12_state *s) {
 zero(s->raw,sizeof(s->raw));zero(s->blocking_fir,sizeof(s->blocking_fir));
 zero(s->beam_fir,sizeof(s->beam_fir));zero(s->integrator,sizeof(s->integrator));
 clear_weights(s);s->head=s->fhead=s->length=s->stable=0;s->model_das=s->model_fir=0;
}
size_t gsc12_state_size(void) {return sizeof(gsc12_state);}
void gsc12_reset(gsc12_state *s) {if(s)zero(s,sizeof(*s));}
int gsc12_configure(gsc12_state *s,const gsc12_config *c) {
 if(!s||!c||c->direction_id>=1024||!c->mu_q15||c->mu_q15>16384||!c->epsilon||c->epsilon>(1u<<30))return -1;
 int nonzero=0;
 for(unsigned ch=0;ch<12;ch++)if(c->delay_q16[ch]>=(61u<<16))return -2;
 for(unsigned i=0;i<32;i++)if(c->fir_q15[i])nonzero=1;
 if(!nonzero)return -3;
 s->config=*c;s->configured=1;s->have_packet=0;s->enabled_prev=0;clear_signal(s);
 count(s,GSC12_RESTARTS,1);return 0;
}
static int16_t cubic(const gsc12_state *s,unsigned ch) {
 unsigned d=s->config.delay_q16[ch],age=d>>16;int f=(d>>12)&15;
 int coeff[4]={-2*f*(16-f)*(32-f)/3,2*(16+f)*(16-f)*(32-f),
               2*(16+f)*f*(32-f),-2*(16+f)*f*(16-f)/3};
 int64_t sum=0;
 for(unsigned j=0;j<4;j++)if(age+j<s->length)
   sum+=(int32_t)s->raw[ch][(s->head-age-j)&63u]*coeff[j];
 int64_t rounded=sum>=0?(sum+8192)/16384:-((-sum+8192)/16384);
 return clip16(rounded);
}
static int16_t fir(const int16_t *history,unsigned head,const int16_t *coeff,int *clipped) {
 int64_t sum=0;
 for(unsigned j=0;j<32;j++)sum+=(int32_t)history[(head-j)&31u]*coeff[j];
 int64_t y=floor_power(sum,15);
 if(y>32767||y< -32768)*clipped=1;
 return clip16(y);
}
static int16_t bypass(gsc12_state *s,int16_t beam,unsigned reason,unsigned stat) {
 s->last_reason=reason;count(s,stat,1);return beam;
}
static int weight_guard(const gsc12_state *s) {
 int64_t energy=0;
 for(unsigned ch=0;ch<11;ch++)for(unsigned t=0;t<4;t++) {
   int64_t w=s->weight[ch][t];
   if(w< -32768||w>32767)return 1;
   energy+=w*w;
 }
 return energy>16ll*32768*32768;
}
int16_t gsc12_process(gsc12_state *s,const uint32_t w[16],int enabled,int freeze_updates) {
 if(!s||!w)return 0;
 int16_t original=(int16_t)(uint16_t)(w[7]>>16);
 count(s,GSC12_PACKETS,1);
 if(w[0]!=0x47534301u||(w[6]&~0x0003ff03u)) {
   clear_signal(s);s->have_packet=0;
   return bypass(s,original,GSC12_BYPASS_FORMAT,GSC12_BAD_FORMAT);
 }
 if(!s->configured)return bypass(s,original,GSC12_BYPASS_UNCONFIGURED,GSC12_META_MISMATCH);
 int broken=0;
 if(s->have_packet) {
   if(w[1]!=s->last_seq+1u) {
     uint32_t missing=w[1]-(s->last_seq+1u);
     if(missing<0x80000000u)count(s,GSC12_LOST_PACKETS,missing);
     count(s,GSC12_SEQ_ERRORS,1);broken=1;
   }
   if(w[15]!=s->last_overflow) {count(s,GSC12_OVERFLOW_EVENTS,1);broken=1;}
 }
 s->have_packet=1;s->last_seq=w[1];s->last_overflow=w[15];
 if(broken) {clear_signal(s);s->last_reason=GSC12_BYPASS_SEQUENCE;return original;}
 uint32_t max_delay=0;
 for(unsigned ch=0;ch<12;ch++)if(s->config.delay_q16[ch]>max_delay)max_delay=s->config.delay_q16[ch];
 if(w[2]!=s->config.version||w[14]!=s->config.epoch||((w[6]>>8)&1023u)!=s->config.direction_id||
    !(w[6]&1u)||w[5]!=max_delay+65536u||(uint32_t)(w[1]-w[3])>=0x80000000u) {
   clear_signal(s);return bypass(s,original,GSC12_BYPASS_METADATA,GSC12_META_MISMATCH);
 }
 if(w[6]&2u) {clear_signal(s);return bypass(s,original,GSC12_BYPASS_TRANSITION,GSC12_TRANSITIONS);}
 if(enabled&&!s->enabled_prev)clear_weights(s);
 s->enabled_prev=enabled!=0;
 for(unsigned ch=0;ch<12;ch++)s->raw[ch][s->head]=(int16_t)(uint16_t)(w[8+ch/2]>>(16*(ch&1)));
 if(s->length<64)s->length++;
 if(s->stable<129)s->stable++;
 int16_t aligned[12];int32_t sum=0;
 for(unsigned ch=0;ch<12;ch++){aligned[ch]=cubic(s,ch);sum+=aligned[ch];}
 int32_t rounded=sum+6;
 int16_t model_das=(int16_t)(rounded>=0?rounded/12:-((-rounded+11)/12));
 s->beam_fir[s->fhead]=model_das;
 int ignored=0,ref_clipped=0;
 s->model_das=model_das;s->model_fir=fir(s->beam_fir,s->fhead,s->config.fir_q15,&ignored);
 int16_t refs[11];
 for(unsigned ch=0;ch<11;ch++) {
   int32_t bm=((int32_t)aligned[ch]-aligned[11])/2;
   int64_t v=s->integrator[ch];
   int64_t decay=v>=0?(v+63)/64:-((-v+63)/64);
   v=v-decay+bm;s->integrator[ch]=(int32_t)v;
   int64_t conditioned=v/4;
   if(conditioned>32767||conditioned< -32768)ref_clipped=1;
   s->blocking_fir[ch][s->fhead]=clip16(conditioned);
   refs[ch]=fir(s->blocking_fir[ch],s->fhead,s->config.fir_q15,&ref_clipped);
   for(unsigned t=3;t>0;t--)s->reference_history[ch][t]=s->reference_history[ch][t-1];
   s->reference_history[ch][0]=refs[ch];
 }
 s->head=(s->head+1)&63u;s->fhead=(s->fhead+1)&31u;
 if(ref_clipped)count(s,GSC12_REF_CLIPS,1);
 if(!enabled)return bypass(s,original,GSC12_BYPASS_DISABLED,GSC12_DISABLED);
 if(s->stable<=128)return bypass(s,original,GSC12_BYPASS_WARMUP,GSC12_WARMUP);
 if(model_das!=(int16_t)(uint16_t)w[7]||s->model_fir!=original) {
   clear_signal(s);return bypass(s,original,GSC12_BYPASS_ALIGNMENT,GSC12_ALIGN_ERRORS);
 }
 if(weight_guard(s)) {
   clear_weights(s);return bypass(s,original,GSC12_BYPASS_DIVERGENCE,GSC12_DIVERGENCE);
 }
 int64_t prediction=0,energy=s->config.epsilon;
 for(unsigned ch=0;ch<11;ch++)for(unsigned t=0;t<4;t++) {
   int32_t x=s->reference_history[ch][t];
   prediction+=(int64_t)s->weight[ch][t]*x;energy+=(int64_t)x*x;
 }
 int64_t error=(int32_t)original-floor_power(prediction,15);
 int clipped=error>32767||error< -32768;
 if(clipped)count(s,GSC12_SATURATIONS,1);
 int input_clipped=original==32767||original== -32768;
 if(input_clipped)count(s,GSC12_INPUT_CLIPS,1);
 if(freeze_updates||clipped||ref_clipped||input_clipped)count(s,GSC12_UPDATE_FROZEN,1);
 else {
   for(unsigned ch=0;ch<11;ch++)for(unsigned t=0;t<4;t++) {
     int64_t delta=(int64_t)s->config.mu_q15*error*s->reference_history[ch][t]/energy;
     int64_t next=s->weight[ch][t]+delta;
     if(next>32767||next< -32768)count(s,GSC12_COEFF_CLIPS,1);
     s->weight[ch][t]=clip16(next);
   }
   if(weight_guard(s)) {
     clear_weights(s);return bypass(s,original,GSC12_BYPASS_DIVERGENCE,GSC12_DIVERGENCE);
   }
 }
 s->last_reason=GSC12_OK;count(s,GSC12_ACTIVE,1);return clip16(error);
}
uint64_t gsc12_stat(const gsc12_state *s,unsigned i){return s&&i<GSC12_STATS?s->stats[i]:0;}
uint32_t gsc12_reason(const gsc12_state *s){return s?s->last_reason:GSC12_BYPASS_UNCONFIGURED;}
uint32_t gsc12_model_beam(const gsc12_state *s){return s?(uint16_t)s->model_das|(uint32_t)(uint16_t)s->model_fir<<16:0;}
void gsc12_get_weights(const gsc12_state *s,int32_t w[44]){
 if(s&&w)for(unsigned ch=0;ch<11;ch++)for(unsigned t=0;t<4;t++)w[ch*4+t]=s->weight[ch][t];
}
#ifdef GSC12_TEST
void gsc12_test_corrupt_weights(gsc12_state *s){
 if(s)for(unsigned ch=0;ch<11;ch++)for(unsigned t=0;t<4;t++)s->weight[ch][t]=32767;
}
void gsc12_test_weight(gsc12_state *s,unsigned i,int32_t v){if(s&&i<44)s->weight[i/4][i%4]=v;}
#endif
