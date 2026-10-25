/* Real CPU0 control header and audio/GSC, with a named native MMIO model.
 * Synthetic calibration and history metadata exercise gates only. This is
 * neither a physical calibration nor a Cortex-A9/RTL timing measurement. */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "acoustic_circular9_image.h"
#include "circular9_candidates.h"
#include "circular9_direction.h"
#include "circular9_audio.h"

static unsigned checks,alignment_samples,interpolation_vectors,negative_routes;
#define CHECK(c,m) do{checks++;if(!(c)){fprintf(stderr,"CONTROL_FAIL line%d: %s\n",__LINE__,m);exit(1);}}while(0)
static unsigned fixture_geometry_confirmed=1;
static uint32_t fixture_calibration_version=0x54455354u;
static uint32_t fixture_lut[9*1024];
#undef ACOUSTIC_GEOMETRY_CONFIRMED
#undef ACOUSTIC_CALIBRATION_VERSION
#define ACOUSTIC_GEOMETRY_CONFIRMED fixture_geometry_confirmed
#define ACOUSTIC_CALIBRATION_VERSION fixture_calibration_version
#define RV32_BASE 0u

/* Preserve the generated table as an independent starting point, then apply
 * a synthetic outer-channel permutation and sensor delays (center stays8). */
static int signed_q4(uint32_t word){int q=(int)(word&16383u);return q&8192?q-16384:q;}
static void fixture_init(void){
 const unsigned mic[9]={3,0,6,1,7,4,2,5,8};
 const int delay_q4[9]={0,3,-5,7,-9,1,11,-3,2};
 for(unsigned ch=0;ch<9;ch++)for(unsigned grid=0;grid<1024;grid++)
  fixture_lut[ch*1024+grid]=(uint32_t)(signed_q4(acoustic_steer_lut[mic[ch]*1024+grid])+delay_q4[ch])&16383u;
}

typedef struct {
 uint32_t index,clock,epoch,shadow[17],active[17],written;
 uint32_t begin_count,commit_count,off_count,rejected,commands,last_command;
 uint32_t tacho[12],readback_fault,drop_index,sequence_race,seq_reads,armed;
} native_mmio_model;
static native_mmio_model device;
static uint32_t model_read(void *ctx,uint32_t offset){
 native_mmio_model *d=ctx;
 if(offset==0x3e0)return d->clock;
 if(offset!=0x3f8)return 0;
 unsigned index=d->index;uint32_t value=0;
 if(index==20)value=d->active[1];
 else if(index==21)value=0x80000000u|d->active[2];
 else if(index==22)value=d->active[3];
 else if(index==23)value=d->active[4];
 else if(index==24)value=d->rejected;
 else if(index==25)value=d->armed|(d->armed&&d->active[3]==d->epoch&&(uint32_t)(d->clock-d->active[4])<8000000u?2u:0u);
 else if(index>=32&&index<=40)value=d->active[index-24];
 else if(index>=64&&index<=75){
  value=d->tacho[index-64];
  if(index==68&&d->sequence_race&&++d->seq_reads==2)value++;
 }
 if(d->readback_fault==index)value^=1;
 return value;
}
static void model_write(void *ctx,uint32_t offset,uint32_t value){
 native_mmio_model *d=ctx;
 if(offset==0x3c){d->last_command=value;d->commands++;return;}
 if(offset==0x3f4){d->index=value&255u;return;}
 if(offset==0x3f8){
  unsigned index=d->index;
  if(d->drop_index==index)return;
  if(index>=1&&index<=4){d->shadow[index]=value;d->written|=1u<<(index-1);}
  else if(index>=8&&index<=16){d->shadow[index]=value;d->written|=1u<<(index-4);}
  else if(index>=64&&index<=67){d->tacho[index-64]=value;d->tacho[4]++;d->tacho[9]=0;}
  return;
 }
 if(offset!=0x3f0)return;
 if(value==0x42454731u){d->written=0;d->begin_count++;return;}
 if(value==0x4f464631u){d->written=0;d->armed=0;d->off_count++;return;}
 if(value!=0x434f4d31u){d->rejected++;return;}
 d->commit_count++;
 int valid=d->written==8191u&&d->shadow[1]<1024u&&d->shadow[2]>0&&d->shadow[2]<0x80000000u&&
  d->shadow[3]==d->epoch&&(uint32_t)(d->clock-d->shadow[4])<8000000u;
 int same=1,zero=0;
 for(unsigned i=8;i<=16;i++){
  if(d->shadow[i]>=(61u<<16)||(d->shadow[i]&4095u))valid=0;
  if(!d->shadow[i])zero=1;
  if(d->shadow[i]!=d->active[i])same=0;
 }
 valid=valid&&zero&&(!d->active[2]||d->shadow[2]>d->active[2]||
  (d->shadow[2]==d->active[2]&&same&&d->shadow[1]==d->active[1]&&d->shadow[3]==d->active[3]));
 if(valid){memcpy(d->active,d->shadow,sizeof(d->active));d->armed=1;}
 else d->rejected++;
 d->written=0;
}
static das_bus das_axi_bus(uintptr_t base){(void)base;return(das_bus){&device,model_read,model_write};}
static circular9_audio c9_audio;
static unsigned c9_shaft_confirmed,c9_shaft_waiting;
static uint32_t c9_shaft_generation,c9_shaft_millihz,c9_shaft_epoch,c9_shaft_session,c9_shaft_first_sample;
static struct {unsigned have;} c9_schedule;
typedef struct {uint32_t end,count,epoch,session;unsigned available;} native_history_metadata;
static struct {native_history_metadata history;} c9_history_shared;
static int native_history_info(const native_history_metadata *s,uint32_t *end,uint32_t *count,uint32_t *epoch,uint32_t *session){
 if(!s->available)return 0;
 *end=s->end;*count=s->count;*epoch=s->epoch;*session=s->session;return 1;
}
struct ui_reply {int code;const char *reason,*type;int len;};
#define c9_history_info native_history_info
#define acoustic_steer_lut fixture_lut
#include "ps_circular9_control.h"
#undef acoustic_steer_lut
#undef c9_history_info

static void reset_control(void){
 memset(&device,0,sizeof(device));device.clock=10000000u;device.epoch=7;
 circular9_audio_init(&c9_audio);c9_audio.target_guard_requested=1;
 c9_fine_sequence=c9_fine_last_clock=c9_fine_last_epoch=0;c9_fine_last_grid=UINT32_MAX;
 c9_target_withheld=0;
 memset(c9_fine_delay,0,sizeof(c9_fine_delay));c9_fine_commits=c9_fine_errors=0;
 c9_tacho_mode=c9_tacho_ppr=0;c9_tacho_last_poll=c9_tacho_sequence=c9_tacho_period=c9_tacho_age=c9_tacho_valid=0;
 c9_tacho_rpm_milli=c9_tacho_rejections=c9_tacho_updates=0;
 c9_shaft_confirmed=c9_shaft_waiting=0;c9_shaft_generation=c9_shaft_millihz=c9_shaft_epoch=c9_shaft_session=c9_shaft_first_sample=0;
 c9_schedule.have=1;c9_history_shared.history=(native_history_metadata){200000,160000,7,3,1};
 fixture_geometry_confirmed=1;fixture_calibration_version=0x54455354u;
}
static c9_candidate candidate(unsigned grid,int az_offset,int el_offset){
 return(c9_candidate){.grid=grid,.score=1000,.azimuth_mdeg=c9_direction_azimuth_mdeg[grid%32]+az_offset,
  .elevation_mdeg=c9_direction_elevation_mdeg[grid/32]+el_offset,
  .flags=(az_offset||el_offset)?C9_CANDIDATE_REFINED:0,.uncertainty_mdeg=1000};
}
/* Independently locate the interpolation rectangle and evaluate its four
 * corners in long double. No production interpolation helper is reused. */
static void expected_delays(const c9_candidate *c,const uint32_t *lut,uint32_t out[9]){
 int az=c->flags?c->azimuth_mdeg:c9_direction_azimuth_mdeg[c->grid%32];
 int el=c->flags?c->elevation_mdeg:c9_direction_elevation_mdeg[c->grid/32];
 unsigned x=30,y=30;
 for(unsigned i=0;i<31;i++)if(az<=c9_direction_azimuth_mdeg[i+1]){x=i;break;}
 for(unsigned i=0;i<31;i++)if(el<=c9_direction_elevation_mdeg[i+1]){y=i;break;}
 long double dx=c9_direction_azimuth_mdeg[x+1]-c9_direction_azimuth_mdeg[x];
 long double dy=c9_direction_elevation_mdeg[y+1]-c9_direction_elevation_mdeg[y];
 long double ax=az-c9_direction_azimuth_mdeg[x],ay=el-c9_direction_elevation_mdeg[y];
 int q[9],minimum=0;
 for(unsigned ch=0;ch<9;ch++){
  const uint32_t *p=lut+ch*1024+y*32+x;
  long double numerator=signed_q4(p[0])*(dx-ax)*(dy-ay)+signed_q4(p[1])*ax*(dy-ay)+
   signed_q4(p[32])*(dx-ax)*ay+signed_q4(p[33])*ax*ay;
  q[ch]=(int)floorl(numerator/(dx*dy));if(!ch||q[ch]<minimum)minimum=q[ch];
 }
 for(unsigned ch=0;ch<9;ch++)out[ch]=(uint32_t)(q[ch]-minimum)*4096u;
}
static uint32_t rng_state=20261025u;
static uint32_t random32(void){rng_state^=rng_state<<13;rng_state^=rng_state>>17;rng_state^=rng_state<<5;return rng_state;}
static void test_interpolation(void){
 uint32_t actual[9],expected[9];
 for(unsigned grid=0;grid<1024;grid++){
  c9_candidate c=candidate(grid,0,0);
  CHECK(c9_candidate_delays_q16(&c,fixture_lut,actual),"coarse calibrated LUT accepted");
  expected_delays(&c,fixture_lut,expected);CHECK(!memcmp(actual,expected,sizeof(actual)),"coarse signed floor and sensor delay/permutation exact");interpolation_vectors++;
 }
 for(unsigned i=0;i<2048;i++){
  unsigned grid=random32()%1024;
  int da=(int)(random32()%5401)-2700,de=(int)(random32()%5401)-2700;
  c9_candidate c=candidate(grid,da,de);
  CHECK(c9_candidate_delays_q16(&c,fixture_lut,actual),"continuous-angle calibrated LUT accepted");
  expected_delays(&c,fixture_lut,expected);
  if(memcmp(actual,expected,sizeof(actual))){
   fprintf(stderr,"INTERPOLATION grid=%u da=%d de=%d az=%d el=%d\n",grid,da,de,c.azimuth_mdeg,c.elevation_mdeg);
   for(unsigned ch=0;ch<9;ch++)fprintf(stderr,"ch%u actual=%u expected=%u\n",ch,actual[ch],expected[ch]);
  }
  CHECK(!memcmp(actual,expected,sizeof(actual)),"off-grid floor/normalization matches independent long double oracle");interpolation_vectors++;
 }
 c9_candidate c=candidate(16*32+20,1500,-1700);
 CHECK(!c9_candidate_delays_q16(NULL,fixture_lut,actual),"NULL candidate rejected");
 CHECK(!c9_candidate_delays_q16(&c,NULL,actual),"NULL LUT rejected");
 CHECK(!c9_candidate_delays_q16(&c,fixture_lut,NULL),"NULL output rejected");
 c.flags=2;CHECK(!c9_candidate_delays_q16(&c,fixture_lut,actual),"unknown refined flag rejected");
 c=candidate(16*32+20,2815,0);CHECK(!c9_candidate_delays_q16(&c,fixture_lut,actual),"refinement beyond half cell rejected instead of coarse fallback");
 c=candidate(16*32+20,1500,0);c.azimuth_mdeg=INT32_MAX;
 CHECK(!c9_candidate_delays_q16(&c,fixture_lut,actual),"overflow angle rejected");
 c=candidate(16*32+20,1500,0);c.grid=1024;
 CHECK(!c9_candidate_delays_q16(&c,fixture_lut,actual),"out of range grid rejected");
 uint32_t saved=fixture_lut[8*1024+16*32+20];fixture_lut[8*1024+16*32+20]=1000;
 c=candidate(16*32+20,0,0);CHECK(!c9_candidate_delays_q16(&c,fixture_lut,actual),"unrepresentable delay span rejected");fixture_lut[8*1024+16*32+20]=saved;
}
static void model_transaction(const das_bus *b,uint32_t sequence,uint32_t epoch,uint32_t grid,const uint32_t delay[9],int incomplete){
 b->write(b->ctx,0x3f0,0x42454731u);
 c9_hw_write(b,1,grid);c9_hw_write(b,2,sequence);c9_hw_write(b,3,epoch);c9_hw_write(b,4,device.clock);
 for(unsigned i=0;i<9-(unsigned)incomplete;i++)c9_hw_write(b,8+i,delay[i]);
 b->write(b->ctx,0x3f0,0x434f4d31u);
}
static void test_commit(void){
 reset_control();das_bus b=das_axi_bus(0);c9_candidate c=candidate(16*32+20,1500,-1700);uint32_t delays[9];
 CHECK(c9_candidate_delays_q16(&c,fixture_lut,delays),"fine commit input");
 CHECK(c9_apply_target(&b,&c,7),"real control commits complete shadow and readback");
 CHECK(device.begin_count==1&&device.commit_count==1&&device.armed&&device.written==0,"atomic shadow protocol");
 CHECK(device.active[2]==1&&device.active[3]==7&&device.last_command==(0xd1000000u|c.grid),"version epoch grid enable after complete readback");
 CHECK(!memcmp(device.active+8,delays,sizeof(delays)),"PL fine vector equals software candidate delays");
 CHECK(c9_audio.fine_cache[0].version==0x80000001u&&!memcmp(c9_audio.fine_cache[0].delay_q16,delays,sizeof(delays)),"cache precedes fine vector activation");
 CHECK(c9_apply_target(&b,&c,7)&&device.commit_count==1,"unchanged direction skips redundant MMIO within20ms");
 device.clock+=800000u;CHECK(c9_apply_target(&b,&c,7)&&device.active[2]==1&&device.commit_count==2,"refresh retains token and cached vector");
 c.azimuth_mdeg+=700;CHECK(c9_apply_target(&b,&c,7)&&device.active[2]==2,"same coarse cell new fine vector creates new token");
 uint32_t good[9];memcpy(good,device.active+8,sizeof(good));
 CHECK(circular9_audio_store_direction(&c9_audio,0x80000002u,7,c.grid,good),"identical cached token accepted");
 good[1]+=4096;CHECK(!circular9_audio_store_direction(&c9_audio,0x80000002u,7,c.grid,good),"same token different vector rejected by PS cache");
 uint32_t rejects=device.rejected;model_transaction(&b,2,7,c.grid,good,0);
 CHECK(device.rejected==rejects+1&&device.active[2]==2,"MMIO model rejects same token vector alias");
 memcpy(good,device.active+8,sizeof(good));rejects=device.rejected;model_transaction(&b,3,7,c.grid,good,1);
 CHECK(device.rejected==rejects+1&&device.active[2]==2,"incomplete transaction cannot alter active bank");
 rejects=device.rejected;model_transaction(&b,1,7,c.grid,good,0);
 CHECK(device.rejected==rejects+1&&device.active[2]==2,"old sequence cannot roll back identical vector");
 device.clock+=800000;device.readback_fault=36;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed&&device.last_command==0xd3000000u,"readback vector mismatch releases target");
 device.readback_fault=0;device.epoch=8;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed,"wrong capture epoch cannot arm fine target");
 device.epoch=7;fixture_geometry_confirmed=0;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed,"unconfirmed physical geometry protects target routing");
 fixture_geometry_confirmed=1;fixture_calibration_version=0;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed,"unmeasured calibration protects target routing");
 fixture_calibration_version=0x54455354u;c9_fine_sequence=0x7fffffffu;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed,"token exhaustion releases instead of wrapping");
 reset_control();device.clock=0xfffffff0u;b=das_axi_bus(0);
 CHECK(c9_apply_target(&b,&c,7),"fine timestamp near wrap");device.clock=0x00001000u;
 CHECK(c9_apply_target(&b,&c,7)&&device.commit_count==1,"unsigned wrap preserves short refresh age");
 device.clock+=800000;CHECK(c9_apply_target(&b,&c,7)&&device.commit_count==2,"refresh across clock wrap");
 reset_control();b=das_axi_bus(0);device.drop_index=16;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed,"dropped last shadow word rejects complete-control request");
 reset_control();b=das_axi_bus(0);device.active[2]=100;
 CHECK(c9_apply_target(&b,&c,7)&&device.active[2]==101,"CPU restart seeds sequence from active hardware token");
 reset_control();b=das_axi_bus(0);c9_release_target(&b);device.readback_fault=36;
 CHECK(!c9_apply_target(&b,&c,7)&&!device.armed&&device.off_count==2,"readback failure after a withheld target still forcibly disarms newly committed bank");
}
static int16_t saturated(int64_t value){return value>32767?32767:value< -32768?-32768:(int16_t)value;}
static int16_t raw_pcm[4096][9],reference_das[4096],reference_fir[4096];
/* Direct finite sums over the owned raw capture, without production ring
 * buffers, GSC helpers or their coefficient cache. */
static void reference_frontend(const uint32_t delays[9]){
 for(unsigned n=0;n<4096;n++)for(unsigned ch=0;ch<9;ch++)raw_pcm[n][ch]=(int16_t)((int)(random32()%3001)-1500);
 for(unsigned n=0;n<4096;n++){
  int total=0;
  for(unsigned ch=0;ch<9;ch++){
   unsigned age=delays[ch]>>16;int f=(delays[ch]>>12)&15;
   const int coeff[4]={-2*f*(16-f)*(32-f)/3,2*(16+f)*(16-f)*(32-f),2*(16+f)*f*(32-f),-2*(16+f)*f*(16-f)/3};
   int64_t sum=0;
   for(unsigned tap=0;tap<4;tap++)if(n>=age+tap)sum+=(int32_t)raw_pcm[n-age-tap][ch]*coeff[tap];
   total+=saturated(sum>=0?(sum+8192)/16384:-((-sum+8192)/16384));
  }
  reference_das[n]=(int16_t)(total>=0?(total+4)/9:-((-total+4)/9));
  int64_t convolution=0;
  for(unsigned tap=0;tap<32;tap++)if(n>=tap)convolution+=(int32_t)reference_das[n-tap]*(int16_t)(uint16_t)acoustic_fir_coeff[tap];
  reference_fir[n]=saturated(convolution>=0?convolution/32768:-((-convolution+32767)/32768));
 }
}
static void packet(uint32_t out[16],unsigned n,uint32_t version,uint32_t epoch,unsigned grid,const uint32_t delays[9]){
 memset(out,0,64);uint32_t maximum=0;for(unsigned i=0;i<9;i++)if(delays[i]>maximum)maximum=delays[i];
 out[0]=0x47534302u;out[1]=n;out[2]=version;out[3]=0;out[5]=maximum+65536;
 out[6]=1u|(grid<<8);out[7]=(uint16_t)reference_das[n]|((uint32_t)(uint16_t)reference_fir[n]<<16);
 for(unsigned ch=0;ch<9;ch++)out[8+ch/2]|=(uint32_t)(uint16_t)raw_pcm[n][ch]<<(16*(ch%2));
 out[13]=0x000a0009u;out[14]=epoch;
}
static void test_audio(void){
 reset_control();das_bus b=das_axi_bus(0);c9_candidate c=candidate(16*32+20,1500,-1700);
 CHECK(c9_apply_target(&b,&c,7),"fine direction committed before raw packets");
 uint32_t delays[9];memcpy(delays,device.active+8,sizeof(delays));reference_frontend(delays);
 unsigned blocks=0;uint32_t w[16];int16_t output;
 for(unsigned n=0;n<4096;n++){
  packet(w,n,0x80000001u,7,c.grid,delays);
  int complete=circular9_audio_push(&c9_audio,w,fixture_lut,acoustic_fir_coeff,1,1,0,&output);
  CHECK(complete>=0&&output==reference_fir[n],"fine cached delay real GSC frozen output matches independent FIR");
  CHECK(c9_audio.reason!=GSC9_BYPASS_ALIGNMENT,"continuous fine steering aligns every real GSC packet");
  if(n>512)CHECK(gsc9_model_beam(&c9_audio.adaptive)==w[7],"fine DAS and FIR raw reconstruction agree sample by sample");
  alignment_samples++;blocks+=(unsigned)complete;
 }
 CHECK(blocks==2&&gsc9_stat(&c9_audio.adaptive,GSC9_ALIGN_ERRORS)==0,"fine stream produces complete512-sample diagnostic blocks without alignment errors");
 CHECK((gsc9_target_guard_status(&c9_audio.adaptive)&1u)!=0,"production audio requests target leakage guard after fine configure");
 uint32_t replacement[9];memcpy(replacement,delays,sizeof(replacement));replacement[1]+=4096;
 CHECK(!circular9_audio_store_direction(&c9_audio,0,7,c.grid,delays),"coarse version cannot pollute fine cache");
 CHECK(!circular9_audio_store_direction(&c9_audio,0x80000000u,7,c.grid,delays),"zero fine token rejected");
 CHECK(!circular9_audio_store_direction(&c9_audio,0x80000001u,7,c.grid,replacement),"live cache refuses aliasing vector");
 uint32_t invalid[9];memcpy(invalid,delays,sizeof(invalid));invalid[0]=61u<<16;
 CHECK(!circular9_audio_store_direction(&c9_audio,0x80000100u,7,c.grid,invalid),"cache rejects delay outside hardware history");
 memcpy(invalid,delays,sizeof(invalid));invalid[0]|=1;
 CHECK(!circular9_audio_store_direction(&c9_audio,0x80000100u,7,c.grid,invalid),"cache rejects delay below shared Q4 resolution");
 for(unsigned ch=0;ch<9;ch++)invalid[ch]=4096;
 CHECK(!circular9_audio_store_direction(&c9_audio,0x80000100u,7,c.grid,invalid),"cache rejects vector without a normalized zero reference");
 CHECK(!circular9_audio_store_direction(&c9_audio,0x80000100u,7,1024,delays),"cache rejects invalid grid");
 CHECK(circular9_audio_store_direction(&c9_audio,0x80000002u,7,c.grid,delays),"later fine version can coexist with queued old version");
 c9_audio.adaptive.configured=0;packet(w,0,0x80000001u,7,c.grid,delays);
 CHECK(circular9_audio_push(&c9_audio,w,fixture_lut,acoustic_fir_coeff,1,1,0,&output)>=0&&c9_audio.adaptive.config.version==0x80000001u&&
  !memcmp(c9_audio.adaptive.config.delay_q16,delays,sizeof(delays)),"queued older token selects its retained vector rather than latest active direction");
 for(unsigned version=2;version<=C9_FINE_CACHE+1;version++)CHECK(circular9_audio_store_direction(&c9_audio,0x80000000u|version,7,c.grid,delays),"cache bounded ring replacement");
 c9_audio.adaptive.configured=0;packet(w,0,0x80000001u,7,c.grid,delays);
 CHECK(circular9_audio_push(&c9_audio,w,fixture_lut,acoustic_fir_coeff,1,0,0,&output)>=0&&output==reference_fir[0]&&c9_audio.reason==GSC9_BYPASS_UNCONFIGURED,"evicted old fine token falls back to original without coarse reinterpretation");
 CHECK((c9_audio.pending_flags&DAS_FLAG_INVALID)!=0,"missing fine cache marks diagnostic evidence invalid");
 packet(w,1,0x80000041u,8,c.grid,delays);
 CHECK(circular9_audio_push(&c9_audio,w,fixture_lut,acoustic_fir_coeff,1,0,0,&output)>=0&&output==reference_fir[1]&&c9_audio.reason==GSC9_BYPASS_UNCONFIGURED,"cache epoch mismatch cannot configure GSC");
 CHECK(c9_audio.discontinuities>=2,"fine version and epoch transitions break diagnostic block");
 packet(w,2,0x80000041u,7,c.grid,delays);
 CHECK(circular9_audio_push(&c9_audio,w,fixture_lut,acoustic_fir_coeff,1,1,0,&output)>=0&&c9_audio.adaptive.configured,"current cached token reconfigures after epoch-safe fallback");
 packet(w,3,0x80000041u,7,c.grid+1,delays);
 CHECK(circular9_audio_push(&c9_audio,w,fixture_lut,acoustic_fir_coeff,1,0,0,&output)>=0&&output==reference_fir[3]&&c9_audio.reason==GSC9_BYPASS_METADATA,"same token wrong grid remains metadata bypass");
}
static struct ui_reply route(const char *request,int expected_handled){
 char body[1024];struct ui_reply reply={0};int handled=c9_control_route(request,&reply,body,sizeof(body));
 CHECK(handled==expected_handled,"HTTP route dispatch");
 if(handled)CHECK(reply.len>0&&reply.len<(int)sizeof(body)&&body[0]=='{',"HTTP state is bounded JSON");
 return reply;
}
static void tach_sample(uint32_t period,uint32_t age,unsigned valid){
 device.clock+=800000u;device.tacho[4]++;device.tacho[5]=period;device.tacho[6]=age;device.tacho[9]=valid;
 c9_rpm_poll(&(das_bus){&device,model_read,model_write});
}
static void test_routes(void){
 reset_control();
 das_bus b=das_axi_bus(0);c9_candidate c=candidate(16*32+20,1500,-1700);
 CHECK(c9_apply_target(&b,&c,7),"fine direction before operator override");
 route("GET /api/target?grid=4294967896 HTTP/1.1",0);
 CHECK(device.armed,"overflow operator grid cannot revoke or replace fine target");negative_routes++;
 route("GET /api/target?grid=600x HTTP/1.1",0);
 CHECK(device.armed,"bad operator grid suffix cannot revoke fine target");negative_routes++;
 route("GET /api/target?grid=600 HTTP/1.1",0);
 CHECK(!device.armed&&c9_fine_last_grid==UINT32_MAX&&!c9_target_withheld,"valid manual target first disables stale fine vector then yields to task API");
 CHECK(c9_apply_target(&b,&c,7),"fine target can re-arm after operator override");
 route("GET /api/target/auto HTTP/1.1",0);
 CHECK(!device.armed&&c9_fine_last_grid==UINT32_MAX,"auto target route withdraws previous fine vector before selection");
 reset_control();
 CHECK(route("GET /api/rpm/source?mode=tacho&ppr=1 HTTP/1.1\r\n",1).code==200,"valid tacho route");
 CHECK(c9_tacho_mode&&c9_tacho_ppr==1&&device.tacho[0]==1&&device.tacho[1]==64&&device.tacho[2]==128&&device.tacho[3]==12000000,"explicit PPR programs tacho filter/range/timeout");
 const char *bad[]={
  "GET /api/rpm/source?mode=tacho&ppr=0 HTTP/1.1", "GET /api/rpm/source?mode=tacho&ppr=129 HTTP/1.1",
  "GET /api/rpm/source?mode=tacho&ppr=4294967297 HTTP/1.1", "GET /api/rpm/source?mode=tacho&ppr=-4294967295 HTTP/1.1",
  "GET /api/rpm/source?mode=tacho&ppr=1x HTTP/1.1", "GET /api/rpm/source?mode=tacho&ppr=1&other=2 HTTP/1.1",
  "GET /api/rpm/source?mode=tacho&ppr= HTTP/1.1", "GET /api/rpm/source?mode=tacho&ppr=1",
  "GET /api/rpm/source?mode=tacho&ppr=+1 HTTP/1.1", "GET /api/rpm/source?mode=tacho&ppr= 1 HTTP/1.1"};
 for(unsigned i=0;i<sizeof(bad)/sizeof(*bad);i++){
  unsigned mode=c9_tacho_mode,ppr=c9_tacho_ppr;uint32_t generation=c9_shaft_generation,commands=device.commands;
  CHECK(route(bad[i],1).code==400,"malformed explicit PPR is rejected");
  CHECK(c9_tacho_mode==mode&&c9_tacho_ppr==ppr&&generation==c9_shaft_generation&&commands==device.commands,"invalid PPR is side-effect free");negative_routes++;
 }
 CHECK(route("GET /api/rpm/source?mode=tacho&ppr=128 HTTP/1.1",1).code==200&&c9_tacho_ppr==128,"PPR upper boundary accepted");
 route("GET /api/rpm/source?mode=tacho&pprX=1 HTTP/1.1",0);negative_routes++;
 route("GET /api/rpm/stateX HTTP/1.1",0);negative_routes++;
 route("GET /api/rpm/source?mode=manualX HTTP/1.1",0);negative_routes++;
 CHECK(route("GET /api/rpm/state HTTP/1.1",1).code==200&&c9_tacho_mode,"state poll retains tacho mode");
 c9_shaft_confirmed=1;c9_shaft_generation=9;c9_schedule.have=1;
 CHECK(route("GET /api/rpm/source?mode=manual HTTP/1.1",1).code==200&&!c9_tacho_mode&&!c9_shaft_confirmed&&!c9_schedule.have&&c9_shaft_generation==10,"switch to manual invalidates old confirmed RPM and observations");
 route("GET /api/rpm/source?mode=tacho&ppr=1 HTTP/1.1",1);
 route("GET /api/rpm?value=599 HTTP/1.1",0);CHECK(c9_tacho_mode,"invalid manual RPM cannot disable tacho");
 route("GET /api/rpm?value=4294967896 HTTP/1.1",0);CHECK(c9_tacho_mode,"overflow manual RPM cannot disable tacho");negative_routes++;
 route("GET /api/rpm?value=600x HTTP/1.1",0);CHECK(c9_tacho_mode,"bad manual RPM suffix cannot disable tacho");negative_routes++;
 route("GET /api/rpm?valueX=600 HTTP/1.1",0);CHECK(c9_tacho_mode,"lookalike manual RPM route cannot disable tacho");negative_routes++;
 route("GET /api/rpm?value=600 HTTP/1.1",0);CHECK(!c9_tacho_mode&&device.tacho[0]==0,"valid manual RPM yields to real task API after disabling tacho");
}
static void test_tachometer(void){
 reset_control();route("GET /api/rpm/source?mode=tacho&ppr=1 HTTP/1.1",1);
 tach_sample(4000000u,20,1);
 CHECK(c9_shaft_confirmed&&c9_shaft_millihz==10000&&c9_tacho_rpm_milli==600000,"600rpm physical period converts exactly");
 CHECK(c9_shaft_generation==1&&c9_shaft_epoch==7&&c9_shaft_session==3&&c9_shaft_first_sample==200000&&c9_shaft_waiting&&!c9_schedule.have,"new RPM generation resets capture-start barrier");
 uint32_t generation=c9_shaft_generation,updates=c9_tacho_updates;c9_schedule.have=1;
 tach_sample(3999000u,20,1);CHECK(c9_shaft_generation==generation&&c9_tacho_updates==updates&&c9_schedule.have,"sub0.5percent jitter retains original observation generation");
 c9_history_shared.history.end=240000;tach_sample(1333333u,20,1);
 CHECK(c9_shaft_confirmed&&c9_shaft_millihz==30000&&c9_tacho_rpm_milli==1800000,"1800rpm physical period converts within integer quantization");
 CHECK(c9_shaft_generation==generation+1&&c9_shaft_first_sample==240000&&c9_shaft_waiting&&!c9_schedule.have,"speed step discards old diagnosis scheduling window");
 generation=c9_shaft_generation;c9_schedule.have=1;
 c9_history_shared.history.epoch=8;c9_history_shared.history.end=250000;tach_sample(1333333u,20,1);
 CHECK(c9_shaft_generation==generation+1&&c9_shaft_epoch==8&&c9_shaft_first_sample==250000&&!c9_schedule.have,"epoch change cannot reuse old observation barrier");
 generation=c9_shaft_generation;c9_history_shared.history.session=4;c9_history_shared.history.end=260000;tach_sample(1333333u,20,1);
 CHECK(c9_shaft_generation==generation+1&&c9_shaft_session==4&&c9_shaft_first_sample==260000,"session change starts fresh observation generation");
 generation=c9_shaft_generation;c9_schedule.have=1;device.sequence_race=1;device.seq_reads=0;
 tach_sample(2000000u,20,1);CHECK(c9_shaft_generation==generation&&c9_shaft_millihz==30000&&c9_schedule.have,"torn tacho period snapshot cannot update confirmed speed");device.sequence_race=0;
 tach_sample(1333333u,11999999u,1);CHECK(c9_shaft_confirmed,"just before no-pulse timeout remains confirmed");
 generation=c9_shaft_generation;c9_schedule.have=1;tach_sample(1333333u,12000000u,1);
 CHECK(!c9_shaft_confirmed&&c9_shaft_generation==generation+1&&!c9_shaft_waiting&&!c9_schedule.have&&device.last_command==0xd3000000u,"no pulses at timeout clear confirmation and target routing");
 generation=c9_shaft_generation;tach_sample(0,12000000u,0);CHECK(c9_shaft_generation==generation&&!c9_shaft_confirmed,"repeated timeout cannot manufacture generations");
 tach_sample(2000000u,20,1);CHECK(c9_shaft_confirmed&&c9_shaft_millihz==20000,"new valid pulse train re-establishes speed behind fresh barrier");
 tach_sample(4000401u,20,1);CHECK(!c9_shaft_confirmed,"below600rpm period rejected");
 tach_sample(1333000u,20,1);CHECK(!c9_shaft_confirmed,"above1800rpm period rejected");
 c9_history_shared.history.available=0;tach_sample(4000000u,20,1);CHECK(!c9_shaft_confirmed,"missing capture metadata cannot confirm tacho");
 c9_history_shared.history.available=1;c9_history_shared.history.count=0;tach_sample(4000000u,20,1);CHECK(!c9_shaft_confirmed,"empty capture cannot confirm tacho");
 c9_history_shared.history.count=160000;route("GET /api/rpm/source?mode=tacho&ppr=128 HTTP/1.1",1);tach_sample(31250u,20,1);
 CHECK(c9_shaft_confirmed&&c9_shaft_millihz==10000&&c9_tacho_ppr==128,"explicit128 pulses per revolution scales physical period");
 generation=c9_shaft_generation;device.clock+=10;device.tacho[5]=100000;c9_rpm_poll(&(das_bus){&device,model_read,model_write});
 CHECK(c9_shaft_generation==generation&&c9_shaft_confirmed,"polling faster than20ms cannot perturb RPM generation");
 c9_tacho_last_poll=0xfffffff0u;device.clock=0x00001000u;c9_rpm_poll(&(das_bus){&device,model_read,model_write});
 CHECK(c9_shaft_generation==generation,"unsigned polling age survives timestamp wrap");
}
int main(void){
 fixture_init();test_interpolation();test_commit();test_audio();test_routes();test_tachometer();
 printf("CIRCULAR9_PS_CONTROL_PASS checks=%u interpolation_vectors=%u alignment_samples=%u negative_routes=%u\n",checks,interpolation_vectors,alignment_samples,negative_routes);return 0;
}
