#ifndef LOCALIZER12_PROFILE_H
#define LOCALIZER12_PROFILE_H
#include <array>
#include <map>
#include <fstream>
#include <cstdlib>
struct Localizer12Profile {
 std::array<uint64_t,32> phases{};
 std::array<uint64_t,8> fft_states{};
 std::array<uint64_t,4> vec_states{};
 std::array<uint64_t,4096> pc{},active_pc{};
 std::map<uint32_t,uint64_t> mmio,active_mmio;
 struct Request {uint64_t count=0,total=0,maximum=0,minimum=UINT64_MAX;};
 std::array<Request,6> requests{};
 uint32_t last_id=0;uint64_t request_cycle=0;
 uint64_t enabled=0,active=0,retired=0,active_retired=0,mem_stall=0,compute_wait=0,both_wait=0;
 uint64_t ram_requests=0,ram_wait=0,fetch_stall=0,simd_mac_slots=0,fir_outputs=0;
 uint64_t raw_dual=0,raw_collision=0,srp_busy=0;
 template<class T>void sample(const T &t,uint64_t cycle){
  if(!t.rst_n||t.halt||!t.enabled)return;
  enabled++;phases[t.transfer_state]++;fft_states[t.profile_fft_state]++;vec_states[t.profile_vec_state]++;
  bool running=t.transfer_state>0&&t.transfer_state<28;
  active+=running;mem_stall+=t.mem_stall;compute_wait+=t.compute_wait;both_wait+=t.mem_stall&&t.compute_wait;
  fetch_stall+=t.profile_fetch_stall;srp_busy+=t.srp_busy;
  if(t.retire_valid){retired++;active_retired+=running;unsigned index=(t.retire_pc>>2)&4095u;pc[index]++;active_pc[index]+=running;}
  if(t.profile_mmio_ack){mmio[t.profile_dmem_addr]++;if(running)active_mmio[t.profile_dmem_addr]++;}
  ram_requests+=t.profile_ram_req&&t.profile_dmem_ready;
  ram_wait+=t.profile_ram_req&&!t.profile_dmem_ready;
  simd_mac_slots+=t.profile_mac_valid?8:0;fir_outputs+=t.audio_push;
  raw_dual+=t.wr_active&&t.raw_use;raw_collision+=t.profile_raw_collision;
  if(t.request_kind&&t.request_id!=last_id){last_id=t.request_id;request_cycle=cycle;}
  unsigned kind=t.profile_fft_launch?t.request_kind:(t.profile_ac_launch?t.request_kind:(t.srp_start?5:0));
  if(kind&&kind<6){auto &r=requests[kind];uint64_t lag=cycle-request_cycle;r.count++;r.total+=lag;r.maximum=std::max(r.maximum,lag);r.minimum=std::min(r.minimum,lag);}
 }
 void save(){
  const char *path=std::getenv("M10_PROFILE_DIR");if(!path)return;std::string root=path;
  std::ofstream p(root+"/profile_pc.csv");p<<"pc,retired,active_retired\n";
  for(unsigned i=0;i<pc.size();i++)if(pc[i])p<<i*4<<","<<pc[i]<<","<<active_pc[i]<<"\n";
  std::ofstream m(root+"/profile_mmio.csv");m<<"address,acknowledgements,active_acknowledgements\n";
  for(auto x:mmio)m<<x.first<<","<<x.second<<","<<active_mmio[x.first]<<"\n";
  std::ofstream s(root+"/profile_states.csv");s<<"unit,state,cycles\n";
  for(unsigned i=0;i<phases.size();i++)s<<"transfer,"<<i<<","<<phases[i]<<"\n";
  for(unsigned i=0;i<fft_states.size();i++)s<<"fft,"<<i<<","<<fft_states[i]<<"\n";
  for(unsigned i=0;i<vec_states.size();i++)s<<"simd8,"<<i<<","<<vec_states[i]<<"\n";
  std::ofstream r(root+"/profile_dispatch.csv");r<<"kind,calls,total_dispatch_cycles,max_dispatch_cycles,min_dispatch_cycles\n";
  for(unsigned i=1;i<6;i++){auto x=requests[i];r<<i<<","<<x.count<<","<<x.total<<","<<x.maximum<<","<<(x.count?x.minimum:0)<<"\n";}
  std::ofstream c(root+"/profile_counters.csv");c<<"name,value\n";
#define RECORD(x) c<<#x<<","<<x<<"\n"
  RECORD(enabled);RECORD(active);RECORD(retired);RECORD(active_retired);RECORD(mem_stall);RECORD(compute_wait);RECORD(both_wait);
  RECORD(ram_requests);RECORD(ram_wait);RECORD(fetch_stall);RECORD(simd_mac_slots);RECORD(fir_outputs);
  RECORD(raw_dual);RECORD(raw_collision);RECORD(srp_busy);
#undef RECORD
 }
};
#endif
