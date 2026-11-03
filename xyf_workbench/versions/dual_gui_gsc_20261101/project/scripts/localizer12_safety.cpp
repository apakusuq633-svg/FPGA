#include "Vtb_localizer12_safety.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include "localizer12_safety_oracle.h"
static std::vector<uint32_t> hexfile(const std::string& path){std::ifstream f(path);if(!f)throw std::runtime_error(path);std::vector<uint32_t>a;std::string s;while(f>>s)a.push_back(std::stoul(s,nullptr,16));return a;}
static bool phase_match(const std::string& p,unsigned s,unsigned ch,unsigned n,unsigned pass){
 if(p=="before")return s==0;if(p=="raw")return s==2&&ch==0&&pass==0&&n==17;
 if(p=="rawlate")return s==2&&ch==11&&pass==2&&n==1000;
 if(p=="fft")return s==7;if(p=="fftin")return s==5;
 if(p=="gcc")return s==12;if(p=="gccin")return s==10;
 if(p=="phat")return s==14;if(p=="ifft")return s==19;if(p=="ifftin")return s==17;
 if(p=="srp")return s==25;if(p=="publish")return s==28;return false;
}
static int cubic_coefficient(unsigned f,unsigned tap){
 int t=f,c[4];c[0]=-(2*t*(16-t)*(32-t)+1)/3;
 c[1]=2*(16+t)*(16-t)*(32-t);c[2]=2*(16+t)*t*(32-t);
 c[3]=-(2*(16+t)*t*(16-t)+1)/3;
 c[1]+=16384-(c[0]+c[1]+c[2]+c[3]);return c[tap];
}
int main(int argc,char** argv){
 uint64_t cycle=0,loss=0,first_bad=0,received=0,produced=0,min_margin=UINT64_MAX,max_latency=0,max_compute=0;
 uint64_t raw_checks=0,audio_out=0,fwd=0,inv=0,cross=0,phat=0,srp=0;
 try{
 Verilated::commandArgs(argc,argv);
 unsigned windows=std::stoul(argv[1]);std::string kind=argv[2],phase=argv[3];uint64_t duration=std::stoull(argv[4]);
 safety_seed=std::stoul(argv[5]);unsigned target=std::stoul(argv[6]);unsigned offset=std::stoul(argv[7]);
 uint32_t seq_base=argc>9?std::stoul(argv[9]):0;
 std::ofstream trace;if(argc>8&&std::string(argv[8])!="-"){trace.open(argv[8]);trace<<"consume_cycle,window_first,channel,n,pass,request_cycle,response_cycle,expected_seq,returned_seq,raw_addr,overwrite_cycle,margin,cpu_halt,mem_stall,op_block\n";}
 bool started=false;uint32_t old_index=0,old_fft_data=0,old_ac_data=0;bool fft_held=false,ac_held=false;
 bool inject=false;uint64_t until=0,inject_at=0,zero_cycle=0,previous_result=0;
 uint64_t recovery_loss=0,session_base=0;bool recovery_requested=false,recovered=false;
 bool recovery_gap=kind=="recover"&&phase=="gap";
 uint64_t gsc_packets=0;
 if(const char* path=std::getenv("ACOUSTIC_PCM")) {
  std::ifstream f(path,std::ios::binary);if(!f)throw std::runtime_error("PCM_OPEN");
  int16_t x;while(f.read(reinterpret_cast<char*>(&x),2))acoustic_pcm.push_back(x);
  if(acoustic_pcm.size()%12)throw std::runtime_error("PCM_CHANNEL_PACKING");
 }
 const char* lutpath=std::getenv("ACOUSTIC_LUT");
 auto lut=hexfile(lutpath?lutpath:"build/strict_overlap/vectors/lut.hex"),hann=hexfile("rtl/rom/pdm_hann_q14.hex");
 bool link_mode=std::getenv("INTEGRATED_DIRECTION");
 std::vector<uint32_t> steer_lut;
 std::vector<uint32_t> expected_comp,published_grids(1,0);
 int target_delay[12]={},current_delay[12]={};
 if(link_mode){steer_lut=hexfile(std::getenv("ACOUSTIC_STEER"));expected_comp=hexfile(std::getenv("ACOUSTIC_COMP_EXPECTED"));}
 uint32_t applied_count=0,last_applied_version=0;
 SafetyOracle oracle;oracle.generate(0,hann,lut);uint32_t oracle_first=0;
 Vtb_localizer12_safety top;
 std::vector<uint32_t> audio;std::vector<uint64_t> ready;
 int64_t shadow[12288];std::fill(shadow,shadow+12288,-1);int64_t rsp_seq=-1;uint64_t rsp_cycle=0;
 uint64_t first_raw=0,last_raw=0,scheduled=0,prep_done=0,last_state=0,per_window_checks=0;
 uint64_t fft_checks=0,phi_checks=0,ring_checks=0,score_checks=0,mem_blocked=0,op_blocked=0,halted=0;
 const uint64_t init_end=39+lut.size()+(link_mode?steer_lut.size()+3:0);
 auto require=[&](bool ok,const std::string& msg){if(!ok)throw std::runtime_error(msg);};
 for(cycle=0;cycle<(windows+8ULL)*524288;cycle++){
  top.clk=0;top.rst_n=cycle>=4;top.halt=cycle<init_end;top.mem_block=0;top.op_block=0;
  top.gsc_ready=!std::getenv("GSC_STRESS")||cycle%20000>12000;
  if(!inject&&produced>=1024&&received==target&&phase_match(phase,top.transfer_state,top.channel,top.n,top.raw_pass)){
   inject=true;inject_at=cycle+offset;until=inject_at+duration;
   std::cout<<"INJECT kind="<<kind<<" phase="<<phase<<" start="<<inject_at<<" duration="<<duration<<" state="<<unsigned(top.transfer_state)<<"\n";
  }
  bool blocked=inject&&cycle>=inject_at&&cycle<until;
  if(blocked){top.halt=kind=="halt"||kind=="mixed"||(kind=="recover"&&!recovery_gap);top.mem_block=kind=="mem"||kind=="mixed";top.op_block=kind=="op"||kind=="mixed";}
  if(kind=="burst"&&produced>=1024){top.mem_block=cycle%997<131;top.op_block=cycle%337<43;top.halt=cycle%4093<53;inject=true;}
  top.valid=0;top.cw=0;top.cfg_wr=0;top.cfg_rd=0;top.srp_wr=0;
  top.steer_wr=0;top.steer_addr=0;top.steer_data=0;
  top.ci=0;top.cd=0;top.cfg_addr=35;top.cfg_data=0;top.srp_addr=0;top.srp_data=0;
  if(cycle>=4&&cycle<36){top.cw=1;top.ci=cycle-4;top.cd=cycle==4?32767:0;}
  if(cycle==36){top.cfg_wr=1;top.cfg_addr=32;top.cfg_data=link_mode?25:5;}
  if(cycle==37){top.srp_wr=1;top.srp_addr=0;top.srp_data=2;}
  if(cycle==38){top.srp_wr=1;top.srp_addr=2;top.srp_data=0;}
  if(cycle>=39&&cycle<39+lut.size()){top.srp_wr=1;top.srp_addr=3;top.srp_data=lut[cycle-39];}
  if(link_mode){
   uint64_t base=39+lut.size();
   if(cycle==base){top.steer_wr=1;top.steer_addr=6;top.steer_data=0x00010100;}
   if(cycle==base+1){top.steer_wr=1;top.steer_addr=2;top.steer_data=0;}
   if(cycle>=base+2&&cycle<base+2+steer_lut.size()){top.steer_wr=1;top.steer_addr=3;top.steer_data=steer_lut[cycle-base-2];}
   if(cycle==base+2+steer_lut.size()){top.cfg_wr=1;top.cfg_addr=50;top.cfg_data=0x53494d31;}
  }
  if(cycle>=init_end&&top.audio_count)top.cfg_rd=1;
  if(cycle==init_end-1&&std::getenv("AUTO_RECOVERY")){top.cfg_wr=1;top.cfg_addr=50;top.cfg_data=0x41555431;}
  if(kind=="recover"&&loss&&!std::getenv("AUTO_RECOVERY")&&!recovery_requested&&cycle>loss+2000&&cycle%1024==500){
   top.cfg_rd=0;top.cfg_wr=1;top.cfg_addr=50;top.cfg_data=0x52454152;recovery_requested=true;
   std::cout<<"RECOVERY_REQUEST cycle="<<cycle<<"\n";
  }
  if(kind=="recover"&&top.recovery_epoch&&!top.raw_drop&&!top.window_drop&&!recovered){
   recovered=true;recovery_loss=loss;loss=0;session_base=produced;received=0;
   ready.clear();previous_result=0;fwd=inv=cross=phat=srp=0;
   fft_checks=phi_checks=ring_checks=score_checks=0;
   oracle_first=UINT32_MAX;
   published_grids.assign(1,0);
   std::cout<<"RECOVERY_REARM cycle="<<cycle<<" sample="<<produced<<" epoch="<<top.recovery_epoch<<"\n";
  }
  if(top.enabled)started=true;
  if(cycle>=init_end&&started&&received<windows&&cycle%1024==0){
   top.valid=1;top.sample_id=uint32_t(produced+seq_base)+((kind=="gap"||recovery_gap)&&produced>=1100?1:0);
   if(!produced||produced==session_base)zero_cycle=cycle;
   for(int i=0;i<9;i++)top.pcm[i]=0;
   int sum=0;for(int ch=0;ch<12;ch++){
    int16_t x=safety_pcm(produced,ch);sum+=x;uint32_t bits=uint32_t(uint16_t(x))<<8;
    for(int b=0;b<24;b++)if(bits&(1u<<b))top.pcm[(ch*24+b)/32]|=1u<<((ch*24+b)%32);
   }
   int avg=sum+6;avg=avg<0?-((-avg+11)/12):avg/12;audio.push_back(packed(avg,(avg*32767)>>15));
   produced++;if(produced-session_base>=1024&&(produced-session_base-1024)%512==0)ready.push_back(cycle);
  }
  top.eval();
  if(top.rst_n){
   halted+=top.halt;mem_blocked+=top.mem_stall&&top.mem_block;op_blocked+=top.op_block&&top.transfer_state!=0;
   require(!top.retire_valid||!top.fault,"CPU_FAULT");
   require(!((top.halt||top.mem_stall)&&(top.ac_done||top.fft_done)),"DONE_WITHOUT_COMMIT");
   if(fft_held)require(top.index==old_index&&top.fft_data==old_fft_data,"FFT_BACKPRESSURE_HOLD");
   if(ac_held)require(top.index==old_index&&top.ac_data==old_ac_data,"AC_BACKPRESSURE_HOLD");
   require(top.audio_drop==0&&top.audio_max<1024,"AUDIO_LOSS");
   if(top.direction_applied){
    require(top.direction_version>last_applied_version&&top.direction_version<=top.window_id,"DIRECTION_VERSION");
    require(top.effective_sample==top.audio_seq,"DIRECTION_EFFECTIVE_SAMPLE");
    require(top.direction_version<published_grids.size()&&top.direction_grid==published_grids[top.direction_version],"DIRECTION_GRID_SOURCE");
    for(int ch=0;ch<12;ch++)target_delay[ch]=expected_comp.at(ch*1024+top.direction_grid)>>12;
    last_applied_version=top.direction_version;applied_count++;
    std::cout<<"DIRECTION_APPLIED version="<<last_applied_version<<" effective="<<top.effective_sample<<"\n";
   }
   require(top.gsc_errors==0,"GSC_ALIGNMENT_ERROR");
   if(top.gsc_valid&&top.gsc_ready){
    require(top.gsc_data[0]==0x47534301,"GSC_MAGIC");
    uint32_t seq=top.gsc_data[1]-seq_base;
    if((kind=="gap"||recovery_gap)&&seq>=1101)seq--;
    for(unsigned ch=0;ch<12;ch++)require(uint16_t(top.gsc_data[8+ch/2]>>(16*(ch%2)))==uint16_t(safety_pcm(seq,ch)),"GSC_PCM_SYNC");
    require(top.gsc_data[7]==audio.at(seq),"GSC_BEAM_SYNC");
    gsc_packets++;
   }
   if(top.raw_drop||top.window_drop){if(!loss){loss=cycle;std::cout<<"EXPLICIT_LOSS cycle="<<cycle<<" raw_drop="<<top.raw_drop<<" window_drop="<<top.window_drop<<" state="<<unsigned(top.transfer_state)<<"\n";}}
   if(top.active_first!=oracle_first&&!loss){oracle_first=top.active_first;oracle.generate(session_base+oracle_first,hann,lut);}
   if(top.transfer_state==1&&last_state==0){scheduled=cycle-1;first_raw=0;last_raw=0;prep_done=0;per_window_checks=0;}
   if(top.raw_use){
    uint32_t seq=top.active_first+top.n;uint64_t deadline=zero_cycle+(uint64_t(seq)+2048)*1024+(top.channel>>1)+1;
    int64_t margin=int64_t(deadline)-int64_t(rsp_cycle);
    if(margin>=0)min_margin=std::min(min_margin,uint64_t(margin));
    if(trace&&received==target)trace<<cycle<<","<<uint32_t(top.active_first+seq_base)<<","<<unsigned(top.channel)<<","<<top.n<<","<<unsigned(top.raw_pass)<<","<<rsp_cycle<<","<<cycle<<","<<uint32_t(seq+seq_base)<<","<<uint32_t(rsp_seq+seq_base)<<","<<top.raw_addr<<","<<deadline<<","<<margin<<","<<unsigned(top.halt)<<","<<unsigned(top.mem_stall)<<","<<unsigned(top.op_block)<<"\n";
    if(!first_raw)first_raw=cycle;last_raw=cycle;per_window_checks++;raw_checks++;
    bool correct=rsp_seq==seq&&top.raw_value==uint16_t(safety_pcm(session_base+seq,top.channel));
    if(!correct&&!first_bad){first_bad=cycle;std::cout<<"RAW_ERROR cycle="<<cycle<<" first="<<top.active_first<<" ch="<<unsigned(top.channel)<<" n="<<top.n<<" pass="<<unsigned(top.raw_pass)<<" expected_seq="<<seq<<" returned_seq="<<rsp_seq<<" request="<<rsp_cycle<<" deadline="<<deadline<<"\n";}
    require(correct||loss,"SILENT_RAW_CORRUPTION");
    if(!loss&&top.raw_pass==2)require(top.prepared_value==oracle.prep[top.channel*1024+top.n],"PREP_GOLDEN");
    if(top.channel==11&&top.n==1023&&top.raw_pass==2)prep_done=cycle;
   }
   if(!loss){
    if(top.fft_check){require(top.fft_value==oracle.fft[top.channel*513+top.index],"FFT_GOLDEN");fft_checks++;}
    if(top.phi_check){require(top.phi_value==oracle.phi[top.pair*513+6+top.index],"PHAT_GOLDEN");phi_checks++;}
    if(top.ring_check){unsigned lag=top.ring_addr%32;if(lag>=16)lag+=992;uint32_t word=oracle.corr[top.pair*512+lag/2];require(top.ring_value==uint16_t(word>>(lag%2?16:0)),"RING_GOLDEN");ring_checks++;}
    if(top.score_check){if(top.score_value!=oracle.scores[top.score_addr])std::cout<<"SCORE_ERROR grid="<<top.score_addr<<" got="<<top.score_value<<" expected="<<oracle.scores[top.score_addr]<<" busy="<<unsigned(top.srp_busy)<<" srp_retired="<<srp<<"\n";require(top.score_value==oracle.scores[top.score_addr],"SRP_GOLDEN");score_checks++;}
   }
   if(top.audio_push){
    require(audio_out<audio.size(),"AUDIO_EXTRA_SAMPLE");
    if(link_mode){
     // Independent end-to-end physical steering golden. Never read DUT delays.
     int sum=0,max_delay=0;
     for(int ch=0;ch<12;ch++){
      current_delay[ch]+=target_delay[ch]>current_delay[ch]?1:target_delay[ch]<current_delay[ch]?-1:0;
      max_delay=std::max(max_delay,current_delay[ch]);int64_t acc=0;
      for(int k=0;k<4;k++){
       unsigned age=current_delay[ch]/16+k;
       int x=audio_out>=age?safety_pcm(audio_out-age,ch):0;
       acc+=int64_t(x)*cubic_coefficient(current_delay[ch]%16,k);
      }
      int y=acc<0?-int((-acc+8192)>>14):int((acc+8192)>>14);sum+=std::max(-32768,std::min(32767,y));
     }
     int avg=sum+6;avg=avg<0?-((-avg+11)/12):avg/12;
     audio[audio_out]=packed(avg,(avg*32767)>>15);
     require(top.audio_word==audio[audio_out],"LINKED_DAS_PHYSICAL_GOLDEN");
     require(top.direction_group_delay==unsigned(max_delay*4096+65536),"DIRECTION_GROUP_DELAY");
    }
    else require(top.audio_word==audio[audio_out],"AUDIO_GOLDEN");audio_out++;
   }
   if(top.ring_check&&top.ring_addr>=2110&&kind=="burst")std::cout<<"LAST_RING cycle="<<cycle<<" addr="<<top.ring_addr<<"\n";
   if(top.scan_start&&kind=="burst"){
    for(unsigned adr=0;adr<2112;adr++){top.debug_addr=adr;top.eval();unsigned lag=adr%32;if(lag>=16)lag+=992;uint32_t word=oracle.corr[(adr/32)*512+lag/2];require(top.debug_r==uint16_t(word>>(lag%2?16:0)),"SRP_RAM_GOLDEN");}
    for(unsigned adr=0;adr<lut.size();adr++){top.debug_addr=adr;top.eval();require(top.debug_lut==lut[adr],"LUT_GOLDEN");}
   }
   if(top.srp_start||top.scan_start)std::cout<<"SRP_START cycle="<<cycle<<" start="<<unsigned(top.srp_start)<<" scan="<<unsigned(top.scan_start)<<" busy="<<unsigned(top.srp_busy)<<"\n";
   if(top.retire_valid){uint32_t ins=top.retire_instr,op=ins&127,fn=(ins>>12)&7;
    if(op==0x0b&&fn==7&&(ins>>31)&&((ins>>29)&1)){if((ins>>30)&1)inv++;else fwd++;}
    if(op==0x0b&&!(ins>>31)&&fn==6)cross++;if(op==0x0b&&!(ins>>31)&&fn==5)phat++;if(op==0x2b&&fn==0)srp++;
   }
   if(top.done){
    auto best=std::max_element(oracle.scores.begin(),oracle.scores.end(),[](uint32_t a,uint32_t b){return int32_t(a)<int32_t(b);});
    require(top.result_grid==unsigned(best-oracle.scores.begin())&&top.result_score==*best,"PUBLISHED_PEAK_GOLDEN");
    published_grids.push_back(best-oracle.scores.begin());
    if(!acoustic_pcm.empty()) {
     std::cout<<"ACOUSTIC_RESULT grid="<<(best-oracle.scores.begin())<<" score="<<int32_t(*best)<<" all_scores_checked=1024\n";
    }
    require(!loss,"RESULT_AFTER_LOSS");require(!first_bad,"CORRUPT_RESULT");received++;
    require(top.window_id==received&&top.first==uint32_t(seq_base+session_base+(received-1)*512+(recovered&&recovery_gap?1:0)),"WINDOW_SEQUENCE");
    require(per_window_checks==36864,"RAW_COVERAGE");
    if(fwd!=received*12||inv!=received*66||cross!=received*66||phat!=received*66||srp!=received)std::cout<<"COUNT_ERROR fwd="<<fwd<<" inv="<<inv<<" cross="<<cross<<" phat="<<phat<<" srp="<<srp<<"\n";
    require(fwd==received*12&&inv==received*66&&cross==received*66&&phat==received*66&&srp==received,"CUSTOM_COUNT");
    require(fft_checks==received*6156&&phi_checks==received*13728&&ring_checks==received*2112&&score_checks==received*1024,"STAGE_COVERAGE");
    for(int k=0;k<60;k++)require(top.statistics[k]==oracle.stats[k],"STATS_GOLDEN");
    uint64_t latency=cycle-ready[received-1],gap=previous_result?cycle-previous_result:0;
    max_latency=std::max(max_latency,latency);max_compute=std::max(max_compute,uint64_t(top.compute_cycles));previous_result=cycle;
    std::cout<<"SAFETY_WINDOW id="<<received<<" first="<<top.first<<" ready="<<ready[received-1]<<" scheduled="<<scheduled<<" first_raw="<<first_raw<<" last_raw="<<last_raw<<" oldest_overwrite="<<zero_cycle+(uint64_t(top.active_first)+2048)*1024+1<<" prepared="<<prep_done<<" computed="<<ready[received-1]+top.compute_cycles<<" published="<<cycle<<" latency="<<latency<<" gap="<<gap<<" min_margin="<<min_margin<<"\n";
    if(kind=="normal"||duration<=10000)require(latency<=524288&&(!gap||gap==524288),"REALTIME_DEADLINE");
   }
   bool complete=received==windows&&audio_out==audio.size()&&!top.gsc_count&&!top.gsc_pending;
   if(complete||(loss&&kind!="recover"&&cycle>=loss+800000)){
    require(kind=="normal"||kind=="gap"||kind=="recover"||inject,"NO_INJECTION");
    if(kind=="recover"){
     require(recovered&&recovery_loss&&top.recovery_epoch==1&&top.recovery_fault_events==1,"RECOVERY_NOT_EXERCISED");
     std::cout<<"RECOVERY_PASS epoch="<<top.recovery_epoch<<" fault_events="<<top.recovery_fault_events<<" first_loss="<<recovery_loss<<" post_recovery_windows="<<received<<"\n";
    }
    require(loss||gsc_packets+top.gsc_overflow==audio_out,"GSC_UNRECORDED_LOSS");
    if(link_mode)require(applied_count>0,"DIRECTION_LINK_NOT_EXERCISED");
    std::cout<<"SAFETY_SUMMARY status="<<(loss?"EXPLICIT_LOSS":"PASS")<<" windows="<<received<<" produced="<<produced<<" raw_checks="<<raw_checks<<" min_margin="<<min_margin<<" max_latency="<<max_latency<<" max_compute="<<max_compute<<" raw_drop="<<top.raw_drop<<" window_drop="<<top.window_drop<<" first_loss="<<loss<<" first_bad="<<first_bad<<" audio_in="<<audio.size()<<" audio_out="<<audio_out<<" audio_drop="<<top.audio_drop<<" audio_max="<<top.audio_max<<" mem_blocked="<<mem_blocked<<" op_blocked="<<op_blocked<<" halted="<<halted<<" gsc_packets="<<gsc_packets<<" gsc_overflow="<<top.gsc_overflow<<"\n";
    top.final();return loss?2:0;
   }
  }
  fft_held=!loss&&(top.transfer_state==5||top.transfer_state==17)&&!top.fft_ready;
  ac_held=!loss&&top.transfer_state==10&&!top.ac_ready;
  old_index=top.index;old_fft_data=top.fft_data;old_ac_data=top.ac_data;
  last_state=top.transfer_state;
  // READ_FIRST: the synchronous output captures the old word before this edge's write.
  rsp_seq=shadow[top.raw_addr];rsp_cycle=cycle;
  if(top.wr_active)shadow[top.wr_sample*6+top.wr_word]=int64_t(top.sample_count)-1;
  top.clk=1;top.eval();
 }
 throw std::runtime_error("TIMEOUT");
 }catch(const std::exception& e){std::cout<<"SAFETY_FAIL reason="<<e.what()<<" cycle="<<cycle<<" first_loss="<<loss<<" first_bad="<<first_bad<<" windows="<<received<<"\n";return 1;}
}
