/* CPU0-only indexed control; no bulk work or FPGA access from CPU1. */
#ifndef PS_CIRCULAR9_CONTROL_H
#define PS_CIRCULAR9_CONTROL_H
#include "circular9_http_args.h"
static uint32_t c9_hw_read(const das_bus *b,unsigned index){b->write(b->ctx,0x3f4,index);return b->read(b->ctx,0x3f8);}
static void c9_hw_write(const das_bus *b,unsigned index,uint32_t value){b->write(b->ctx,0x3f4,index);b->write(b->ctx,0x3f8,value);}
static uint32_t c9_fine_sequence,c9_fine_last_clock,c9_fine_last_epoch,c9_fine_last_grid=UINT32_MAX;
static uint32_t c9_fine_delay[9],c9_fine_commits,c9_fine_errors;
static unsigned c9_target_withheld;
static unsigned c9_tacho_mode,c9_tacho_ppr;
static uint32_t c9_tacho_last_poll,c9_tacho_sequence,c9_tacho_period,c9_tacho_age,c9_tacho_valid;
static uint32_t c9_tacho_rpm_milli,c9_tacho_rejections,c9_tacho_updates;
static void c9_release_target(const das_bus *b){
 if(c9_target_withheld)return;
 b->write(b->ctx,0x3f0,0x4f464631u);b->write(b->ctx,0x3c,0xd3000000u);
 c9_fine_last_grid=UINT32_MAX;c9_target_withheld=1;
}
static int c9_apply_target(const das_bus *b,const c9_candidate *candidate,uint32_t epoch){
 uint32_t delay[9];
 if(!candidate||!ACOUSTIC_GEOMETRY_CONFIRMED||!ACOUSTIC_CALIBRATION_VERSION||
    !c9_candidate_delays_q16(candidate,acoustic_steer_lut,delay)){
  c9_fine_errors++;c9_release_target(b);return 0;
 }
 uint32_t now=b->read(b->ctx,0x3e0);
 int changed=c9_fine_last_grid!=candidate->grid||epoch!=c9_fine_last_epoch||memcmp(delay,c9_fine_delay,sizeof(delay));
 if(!changed&&(uint32_t)(now-c9_fine_last_clock)<800000u)return 1;
 if(changed){
  uint32_t active=c9_hw_read(b,21)&0x7fffffffu;
  if(c9_fine_sequence<active)c9_fine_sequence=active;
  if(c9_fine_sequence>=0x7fffffffu){c9_fine_errors++;c9_release_target(b);return 0;}
  ++c9_fine_sequence;
 }
 uint32_t version=c9_fine_sequence|0x80000000u;
 if(!circular9_audio_store_direction(&c9_audio,version,epoch,candidate->grid,delay)){
  c9_fine_errors++;c9_release_target(b);return 0;
 }
 b->write(b->ctx,0x3f0,0x42454731u);
 c9_hw_write(b,1,candidate->grid);c9_hw_write(b,2,c9_fine_sequence);
 c9_hw_write(b,3,epoch);c9_hw_write(b,4,now);
 for(unsigned i=0;i<9;i++)c9_hw_write(b,8+i,delay[i]);
 /* COM may arm hardware even if the following readback fails. */
 c9_target_withheld=0;
 b->write(b->ctx,0x3f0,0x434f4d31u);
 if(c9_hw_read(b,21)!=version||c9_hw_read(b,20)!=candidate->grid||
    c9_hw_read(b,22)!=epoch||(c9_hw_read(b,25)&3u)!=3u){
  c9_fine_errors++;c9_release_target(b);return 0;
 }
 for(unsigned i=0;i<9;i++)if(c9_hw_read(b,32+i)!=delay[i]){
  c9_fine_errors++;c9_release_target(b);return 0;
 }
 memcpy(c9_fine_delay,delay,sizeof(delay));c9_fine_last_grid=candidate->grid;
 c9_fine_last_epoch=epoch;c9_fine_last_clock=now;c9_fine_commits++;
 b->write(b->ctx,0x3c,0xd1000000u|candidate->grid);c9_target_withheld=0;return 1;
}
static void c9_rpm_invalidate(const das_bus *b){
 if(c9_shaft_confirmed){c9_shaft_confirmed=0;++c9_shaft_generation;}
 c9_shaft_waiting=0;c9_schedule.have=0;c9_release_target(b);
}
static void c9_rpm_poll(const das_bus *b){
 if(!c9_tacho_mode||!c9_tacho_ppr)return;
 uint32_t now=b->read(b->ctx,0x3e0);
 if(c9_tacho_last_poll&&(uint32_t)(now-c9_tacho_last_poll)<800000u)return;
 c9_tacho_last_poll=now;
 uint32_t seq=c9_hw_read(b,68),period=c9_hw_read(b,69),age=c9_hw_read(b,70),valid=c9_hw_read(b,73)&1u;
 if(seq!=c9_hw_read(b,68))return;
 c9_tacho_sequence=seq;c9_tacho_period=period;c9_tacho_age=age;c9_tacho_valid=valid;
 if(!valid||!period||age>=12000000u){c9_tacho_rejections++;c9_rpm_invalidate(b);return;}
 uint64_t denom=(uint64_t)period*c9_tacho_ppr;
 uint32_t shaft=(uint32_t)((40000000000ull+denom/2u)/denom);
 if(shaft<10000u||shaft>30000u){c9_tacho_rejections++;c9_rpm_invalidate(b);return;}
 uint32_t end,count,epoch,session;
 if(!c9_history_info(&c9_history_shared.history,&end,&count,&epoch,&session)||!count){c9_rpm_invalidate(b);return;}
 c9_tacho_rpm_milli=shaft*60u;
 uint32_t delta=shaft>c9_shaft_millihz?shaft-c9_shaft_millihz:c9_shaft_millihz-shaft;
 // Keep one RPM generation only while physical speed stays within0.5%.
 // A speed step discards the old observation window before collecting a new one.
 if(!c9_shaft_confirmed||epoch!=c9_shaft_epoch||session!=c9_shaft_session||
    (uint64_t)delta*200u>c9_shaft_millihz){
  c9_shaft_millihz=shaft;c9_shaft_confirmed=1;++c9_shaft_generation;
  c9_shaft_epoch=epoch;c9_shaft_session=session;c9_shaft_first_sample=end;
  c9_shaft_waiting=1;c9_schedule.have=0;c9_tacho_updates++;c9_release_target(b);
 }
}
static int c9_control_route(const char *request,struct ui_reply *rep,char *body,size_t cap){
 das_bus b=das_axi_bus(RV32_BASE);
 uint32_t selected;
 if(strncmp(request,"GET /api/target/auto ",sizeof("GET /api/target/auto ")-1)==0||
    (strncmp(request,"GET /api/target?grid=",sizeof("GET /api/target?grid=")-1)==0&&
     c9_http_decimal(request+sizeof("GET /api/target?grid=")-1,0,1023,&selected))){
  b.write(b.ctx,0x3f0,0x4f464631u);c9_fine_last_grid=UINT32_MAX;c9_target_withheld=0;return 0;
 }
 if(strncmp(request,"GET /api/rpm/source?mode=tacho&ppr=",35)==0){
  uint32_t ppr;
  if(!c9_http_decimal(request+35,1,128,&ppr)){
   *rep=(struct ui_reply){400,"Bad Request","application/json",snprintf(body,cap,"{\"error\":\"explicit pulses_per_revolution1..128 required\"}")};return 1;
  }
  c9_hw_write(&b,64,0);c9_tacho_ppr=ppr;c9_tacho_mode=1;c9_tacho_last_poll=0;c9_tacho_valid=0;
  c9_hw_write(&b,65,64);c9_hw_write(&b,66,128);c9_hw_write(&b,67,12000000);c9_hw_write(&b,64,1);
  c9_rpm_invalidate(&b);
 }else if(strncmp(request,"GET /api/rpm/source?mode=manual ",32)==0){
  c9_tacho_mode=0;c9_tacho_valid=0;c9_hw_write(&b,64,0);c9_rpm_invalidate(&b);
 }else if(strncmp(request,"GET /api/rpm/state ",19)!=0){
  if(strncmp(request,"GET /api/rpm?value=",19)==0){
   uint32_t rpm;
   if(c9_http_decimal(request+19,600,1800,&rpm)){
    c9_tacho_mode=0;c9_tacho_valid=0;c9_hw_write(&b,64,0);
   }
  }
  return 0;
 }
 *rep=(struct ui_reply){200,"OK","application/json",snprintf(body,cap,
  "{\"source\":\"%s\",\"pulses_per_revolution\":%u,\"confirmed\":%u,\"shaft_millihz\":%u,"
  "\"rpm_milli\":%u,\"period_ticks\":%u,\"age_ticks\":%u,\"tacho_valid\":%u,\"updates\":%u,\"rejections\":%u,"
  "\"fine_commits\":%u,\"fine_errors\":%u,\"gsc_target_guard\":%u,\"gsc_target_coherence_q15\":%u}",
  c9_tacho_mode?"tacho":"operator_confirmed",c9_tacho_ppr,(unsigned)c9_shaft_confirmed,(unsigned)c9_shaft_millihz,
  (unsigned)(c9_shaft_millihz*60u),(unsigned)c9_tacho_period,(unsigned)c9_tacho_age,(unsigned)c9_tacho_valid,
  (unsigned)c9_tacho_updates,(unsigned)c9_tacho_rejections,(unsigned)c9_fine_commits,(unsigned)c9_fine_errors,
  (unsigned)gsc9_target_guard_status(&c9_audio.adaptive),(unsigned)gsc9_target_coherence_q15(&c9_audio.adaptive))};return 1;
}
#endif
