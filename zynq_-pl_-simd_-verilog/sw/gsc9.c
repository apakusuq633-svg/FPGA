#include "gsc9.h"
#include <limits.h>
static void zero(void *memory,size_t n) {
 uint8_t *p=(uint8_t *)memory;
 for(size_t i=0;i<n;i++)p[i]=0;
}
static void count(gsc9_state *s,unsigned i,uint64_t n) {
 if(UINT64_MAX-s->stats[i]<n)s->stats[i]=UINT64_MAX;else s->stats[i]+=n;
}
static int16_t clip16(int64_t x) {return x>32767?32767:x< -32768?-32768:(int16_t)x;}
static int64_t floor_power(int64_t x,unsigned p) {
 return x>=0?x/((int64_t)1<<p):-((-x+(((int64_t)1<<p)-1))/((int64_t)1<<p));
}
static void clear_weights(gsc9_state *s) {
 zero(s->weight,sizeof(s->weight));zero(s->reference_history,sizeof(s->reference_history));
}
static void clear_target_monitor(gsc9_state *s){
 s->target_guard_active=s->target_guard_samples=s->target_guard_good_blocks=0;
 s->target_guard_coherence_q15=0;s->target_guard_common_energy=s->target_guard_residual_energy=0;
}
static void clear_signal(gsc9_state *s) {
 zero(s->raw,sizeof(s->raw));zero(s->blocking_fir,sizeof(s->blocking_fir));
 zero(s->beam_fir,sizeof(s->beam_fir));zero(s->integrator,sizeof(s->integrator));
 clear_weights(s);s->head=s->fhead=s->length=s->stable=0;s->model_das=s->model_fir=0;
 clear_target_monitor(s);
}
size_t gsc9_state_size(void) {return sizeof(gsc9_state);}
void gsc9_reset(gsc9_state *s) {if(s)zero(s,sizeof(*s));}
int gsc9_configure(gsc9_state *s,const gsc9_config *c) {
 if(!s||!c||c->direction_id>=1024||!c->mu_q15||c->mu_q15>16384||!c->epsilon||c->epsilon>(1u<<30))return -1;
 int nonzero=0;
 for(unsigned ch=0;ch<9;ch++)if(c->delay_q16[ch]>=(61u<<16))return -2;
 for(unsigned i=0;i<32;i++)if(c->fir_q15[i])nonzero=1;
 if(!nonzero)return -3;
 s->config=*c;s->configured=1;s->have_packet=0;s->enabled_prev=0;clear_signal(s);
 s->fir_nonzero=0;for(unsigned i=0;i<32;i++)if(c->fir_q15[i])s->fir_index[s->fir_nonzero++]=(uint8_t)i;
 s->max_delay_q16=0;
 for(unsigned ch=0;ch<9;ch++){
  uint32_t d=c->delay_q16[ch];int f=(d>>12)&15;
  if(d>s->max_delay_q16)s->max_delay_q16=d;
  s->delay_age[ch]=d>>16;
  s->cubic_coeff[ch][0]=-2*f*(16-f)*(32-f)/3;
  s->cubic_coeff[ch][1]=2*(16+f)*(16-f)*(32-f);
  s->cubic_coeff[ch][2]=2*(16+f)*f*(32-f);
  s->cubic_coeff[ch][3]=-2*(16+f)*f*(16-f)/3;
 }
 count(s,GSC9_RESTARTS,1);return 0;
}
static int16_t cubic(const gsc9_state *s,unsigned ch) {
 unsigned age=s->delay_age[ch];const int32_t *coeff=s->cubic_coeff[ch];
 int64_t sum=0;
 for(unsigned j=0;j<4;j++)if(age+j<s->length)
   sum+=(int32_t)s->raw[ch][(s->head-age-j)&63u]*coeff[j];
 int64_t rounded=sum>=0?(sum+8192)/16384:-((-sum+8192)/16384);
 return clip16(rounded);
}
static int16_t fir(const int16_t *history,unsigned head,const gsc9_state *state,int *clipped) {
 int64_t sum=0;
 for(unsigned k=0;k<state->fir_nonzero;k++){unsigned j=state->fir_index[k];sum+=(int32_t)history[(head-j)&31u]*state->config.fir_q15[j];}
 int64_t y=floor_power(sum,15);
 if(y>32767||y< -32768)*clipped=1;
 return clip16(y);
}
static int16_t bypass(gsc9_state *s,int16_t beam,unsigned reason,unsigned stat) {
 s->last_reason=reason;count(s,stat,1);return beam;
}
/* Exact (a*b)>>63 without __int128. Four32x32 products work on Cortex-A9.
 * For0<=a<2^63,R=floor(2^63/d), floor(a*R/2^63) underestimates floor(a/d)
 * by at most1 because a*(1/d-R/2^63)<1. One remainder correction is exact.
 * GSC update |numerator|<=2^44, d<=2^35+2^30; no intermediate q*d overflow. */
static uint64_t product_shift63(uint64_t a,uint64_t b){
 uint64_t a0=(uint32_t)a,a1=a>>32,b0=(uint32_t)b,b1=b>>32;
 uint64_t p0=a0*b0,p1=a1*b0+(p0>>32),p2=a0*b1+(uint32_t)p1;
 uint64_t hi=a1*b1+(p1>>32)+(p2>>32);
 uint64_t lo=(p2<<32)|(uint32_t)p0;
 return (hi<<1)|(lo>>63);
}
static int64_t divide_shared(int64_t value,uint64_t denominator,uint64_t reciprocal){
 uint64_t magnitude=value<0?(uint64_t)(-value):(uint64_t)value;
 uint64_t quotient=product_shift63(magnitude,reciprocal);
 if(magnitude-quotient*denominator>=denominator)quotient++;
 return value<0?-(int64_t)quotient:(int64_t)quotient;
}
static void target_monitor(gsc9_state *s,const int16_t aligned[9],int16_t beam){
 uint64_t common=(int64_t)beam*beam*9u,residual=0;
 for(unsigned ch=0;ch<9;ch++){int64_t d=(int32_t)aligned[ch]-beam;residual+=(uint64_t)(d*d);}
 s->target_guard_common_energy+=common;s->target_guard_residual_energy+=residual;
 if(++s->target_guard_samples<64u)return;
 common=s->target_guard_common_energy;residual=s->target_guard_residual_energy;
 uint64_t total=common+residual;
 s->target_guard_coherence_q15=total?(uint32_t)(common*32767u/total):0;
 /* 64sample spatial coherence, minimum beam RMS64PCM counts. A spatially
  * coherent source with small but real blocking leakage is unsafe to cancel.
  * Same-bearing coherent interference is not distinguishable here; fail
  * conservatively. Genuine off-axis residuals remain eligible to adapt. */
 int leak=common>=9u*64u*64u*64u&&residual>0&&residual*25u<=common;
 if(leak){
  s->target_guard_good_blocks=0;
  if(!s->target_guard_active){s->target_guard_active=1;clear_weights(s);count(s,GSC9_TARGET_LEAK_EVENTS,1);}
 }else if(s->target_guard_active&&++s->target_guard_good_blocks>=4u){
  s->target_guard_active=0;s->target_guard_good_blocks=0;count(s,GSC9_TARGET_GUARD_RELEASES,1);
 }
 s->target_guard_samples=0;s->target_guard_common_energy=s->target_guard_residual_energy=0;
}
static int16_t gsc9_process_core(gsc9_state *s,const uint32_t w[16],int enabled,int freeze_updates,int raw_nominal) {
 if(!s||!w)return 0;
 int16_t original=(int16_t)(uint16_t)(w[7]>>16);
 count(s,GSC9_PACKETS,1);
 if(w[0]!=0x47534302u||w[13]!=0x000a0009u||(w[12]>>16)!=0||(w[6]&~0x0003ff03u)) {
   clear_signal(s);s->have_packet=0;
   return bypass(s,original,GSC9_BYPASS_FORMAT,GSC9_BAD_FORMAT);
 }
 if(!s->configured)return bypass(s,original,GSC9_BYPASS_UNCONFIGURED,GSC9_META_MISMATCH);
 int broken=0;
 if(s->have_packet) {
   if(w[1]!=s->last_seq+1u) {
     uint32_t missing=w[1]-(s->last_seq+1u);
     if(missing<0x80000000u)count(s,GSC9_LOST_PACKETS,missing);
     count(s,GSC9_SEQ_ERRORS,1);broken=1;
   }
   if(w[15]!=s->last_overflow) {count(s,GSC9_OVERFLOW_EVENTS,1);broken=1;}
 }
 s->have_packet=1;s->last_seq=w[1];s->last_overflow=w[15];
 if(broken) {clear_signal(s);s->last_reason=GSC9_BYPASS_SEQUENCE;return original;}
 if(w[2]!=s->config.version||w[14]!=s->config.epoch||((w[6]>>8)&1023u)!=s->config.direction_id||
    !(w[6]&1u)||w[5]!=s->max_delay_q16+65536u||(uint32_t)(w[1]-w[3])>=0x80000000u) {
   clear_signal(s);return bypass(s,original,GSC9_BYPASS_METADATA,GSC9_META_MISMATCH);
 }
 if(w[6]&2u) {clear_signal(s);return bypass(s,original,GSC9_BYPASS_TRANSITION,GSC9_TRANSITIONS);}
 if(enabled&&!s->enabled_prev)clear_weights(s);
 s->enabled_prev=enabled!=0;
 for(unsigned ch=0;ch<9;ch++)s->raw[ch][s->head]=(int16_t)(uint16_t)(w[8+ch/2]>>(16*(ch&1)));
 if(s->length<64)s->length++;
 if(s->stable<513)s->stable++;
 int16_t aligned[9];int32_t sum=0;
 for(unsigned ch=0;ch<9;ch++){aligned[ch]=cubic(s,ch);sum+=aligned[ch];}
 int16_t model_das=(int16_t)(sum>=0?(sum+4)/9:-((-sum+4)/9));
 s->beam_fir[s->fhead]=model_das;
 int ignored=0,ref_clipped=0;
 s->model_das=model_das;s->model_fir=fir(s->beam_fir,s->fhead,s,&ignored);
 if(raw_nominal)original=s->model_fir;
 int16_t refs[8];
 for(unsigned ch=0;ch<8;ch++) {
   int32_t bm=((int32_t)aligned[ch]-aligned[8])/2;
   int64_t v=s->integrator[ch];
   int64_t decay=v>=0?(v+255)/256:-((-v+255)/256);
   v=v-decay+bm;s->integrator[ch]=(int32_t)v;
   int64_t conditioned=v/16;
   if(conditioned>32767||conditioned< -32768)ref_clipped=1;
   s->blocking_fir[ch][s->fhead]=clip16(conditioned);
   refs[ch]=fir(s->blocking_fir[ch],s->fhead,s,&ref_clipped);
   for(unsigned t=15;t>0;t--)s->reference_history[ch][t]=s->reference_history[ch][t-1];
   s->reference_history[ch][0]=refs[ch];
 }
 s->head=(s->head+1)&63u;s->fhead=(s->fhead+1)&31u;
 if(s->target_guard_enabled)target_monitor(s,aligned,model_das);
 if(ref_clipped)count(s,GSC9_REF_CLIPS,1);
 if(!enabled)return bypass(s,original,GSC9_BYPASS_DISABLED,GSC9_DISABLED);
 if(s->stable<=512)return bypass(s,original,GSC9_BYPASS_WARMUP,GSC9_WARMUP);
 if(!raw_nominal&&(model_das!=(int16_t)(uint16_t)w[7]||s->model_fir!=original)) {
   clear_signal(s);return bypass(s,original,GSC9_BYPASS_ALIGNMENT,GSC9_ALIGN_ERRORS);
 }
 if(s->target_guard_enabled&&s->target_guard_active)
  return bypass(s,original,GSC9_BYPASS_TARGET_GUARD,GSC9_TARGET_GUARD_SAMPLES);
 int64_t prediction=0,energy=s->config.epsilon;
 uint64_t weight_energy=0;int invalid_weight=0;
 for(unsigned ch=0;ch<8;ch++)for(unsigned t=0;t<4;t++) {
   int64_t weight=s->weight[ch][t];
   if(weight< -32768||weight>32767)invalid_weight=1;else weight_energy+=(uint64_t)(weight*weight);
   int32_t x=s->reference_history[ch][t*4];
   prediction+=weight*x;energy+=(int64_t)x*x;
 }
 if(invalid_weight||weight_energy>16ull*32768*32768){
  clear_weights(s);return bypass(s,original,GSC9_BYPASS_DIVERGENCE,GSC9_DIVERGENCE);
 }
 int64_t error=(int32_t)original-floor_power(prediction,15);
 int clipped=error>32767||error< -32768;
 if(clipped)count(s,GSC9_SATURATIONS,1);
 int input_clipped=original==32767||original== -32768;
 if(input_clipped)count(s,GSC9_INPUT_CLIPS,1);
 if(freeze_updates||clipped||ref_clipped||input_clipped)count(s,GSC9_UPDATE_FROZEN,1);
 else if((w[1]&3u)==3u) {
   uint64_t reciprocal=(UINT64_C(1)<<63)/(uint64_t)energy;weight_energy=0;
   int64_t scale=(int64_t)s->config.mu_q15*error;
   for(unsigned ch=0;ch<8;ch++)for(unsigned t=0;t<4;t++) {
     int64_t delta=divide_shared(scale*s->reference_history[ch][t*4],(uint64_t)energy,reciprocal);
     int64_t next=s->weight[ch][t]+delta;
     if(next>32767||next< -32768)count(s,GSC9_COEFF_CLIPS,1);
     s->weight[ch][t]=clip16(next);
     weight_energy+=(int64_t)s->weight[ch][t]*s->weight[ch][t];
   }
   if(weight_energy>16ull*32768*32768) {
     clear_weights(s);return bypass(s,original,GSC9_BYPASS_DIVERGENCE,GSC9_DIVERGENCE);
   }
 }
 s->last_reason=GSC9_OK;count(s,GSC9_ACTIVE,1);return clip16(error);
}
uint64_t gsc9_stat(const gsc9_state *s,unsigned i){return s&&i<GSC9_STATS?s->stats[i]:0;}
uint32_t gsc9_reason(const gsc9_state *s){return s?s->last_reason:GSC9_BYPASS_UNCONFIGURED;}
uint32_t gsc9_model_beam(const gsc9_state *s){return s?(uint16_t)s->model_das|(uint32_t)(uint16_t)s->model_fir<<16:0;}
void gsc9_get_weights(const gsc9_state *s,int32_t w[32]){
 if(s&&w)for(unsigned ch=0;ch<8;ch++)for(unsigned t=0;t<4;t++)w[ch*4+t]=s->weight[ch][t];
}
void gsc9_set_target_guard(gsc9_state *s,int enabled){
 if(!s||s->target_guard_enabled==(uint32_t)(enabled!=0))return;
 s->target_guard_enabled=enabled!=0;clear_target_monitor(s);clear_weights(s);
}
uint32_t gsc9_target_guard_status(const gsc9_state *s){return s?s->target_guard_enabled|(s->target_guard_active<<1):0;}
uint32_t gsc9_target_coherence_q15(const gsc9_state *s){return s?s->target_guard_coherence_q15:0;}
#ifdef GSC9_TEST
void gsc9_test_divide_batch(const int64_t n[32],uint64_t d,int64_t q[32]){
 if(!d||d>(UINT64_C(1)<<36))return;
 uint64_t reciprocal=(UINT64_C(1)<<63)/d;
 for(unsigned i=0;i<32;i++)q[i]=divide_shared(n[i],d,reciprocal);
}
void gsc9_test_corrupt_weights(gsc9_state *s){
 if(s)for(unsigned ch=0;ch<8;ch++)for(unsigned t=0;t<4;t++)s->weight[ch][t]=32767;
}
void gsc9_test_weight(gsc9_state *s,unsigned i,int32_t v){if(s&&i<32)s->weight[i/4][i%4]=v;}
#endif

int16_t gsc9_process(gsc9_state *s,const uint32_t w[16],int enabled,int freeze){return gsc9_process_core(s,w,enabled,freeze,0);}
/* Explicit PS-only nominal audio. Raw sample IDs/loss counters remain real;
 * steering metadata belongs to the PS config, not a claimed PL validation. */
int16_t gsc9_process_nominal(gsc9_state *s,const uint32_t input[16],int enabled,int freeze){
 if(!s||!input||input[0]!=0x47534302u||input[13]!=0x000a0009u||(input[12]>>16))return gsc9_process(s,input,0,freeze);
 uint32_t w[16];for(unsigned i=0;i<16;i++)w[i]=input[i];
 w[2]=s->config.version;w[3]=w[1];w[5]=s->max_delay_q16+65536u;w[6]=((uint32_t)s->config.direction_id<<8)|1u;
 return gsc9_process_core(s,w,enabled,freeze,1);
}
