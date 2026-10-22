#include "Vtb_localizer12_verilator.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::vector<uint32_t> readhex(const char* name) {
    std::ifstream f(std::string("build/strict_overlap/vectors/")+name);
    if(!f)throw std::runtime_error(std::string("Missing oracle ")+name);
    std::vector<uint32_t> a;std::string s;
    while(f>>s)a.push_back(std::stoul(s,nullptr,16));
    return a;
}
static void check(bool ok,const char* what,uint64_t cycle) {
    if(!ok)throw std::runtime_error(std::string(what)+" cycle="+std::to_string(cycle));
}
int main(int argc,char** argv) {
 try {
    Verilated::commandArgs(argc,argv);
    const unsigned windows=argc>1?std::stoul(argv[1]):4;
    const std::string mode=argc>2?argv[2]:"normal";
    bool perturbation=false;uint64_t pause_until=0;
    auto pcm=readhex("pcm.hex"),prep=readhex("prepared.hex"),fft=readhex("spectra.hex");
    auto phi=readhex("phi.hex"),corr=readhex("correlation.hex"),scores=readhex("scores.hex");
    auto stats=readhex("stats.hex"),lut=readhex("lut.hex");
    Vtb_localizer12_verilator top;
    std::vector<uint64_t> ready;std::vector<uint32_t> audio;
    uint64_t produced=0,received=0,previous_result=0,max_latency=0,max_compute=0,audio_out=0;
    uint64_t fwd=0,inv=0,cross=0,phat=0,srp=0,raw_checks=0,fft_checks=0,ring_checks=0,score_checks=0,phi_checks=0;
    uint64_t stage_cycles[29]={};
    const uint64_t init_end=4+32+3+lut.size();
    for(uint64_t cycle=0;cycle<(windows+5ULL)*524288;cycle++) {
        top.clk=0;top.rst_n=cycle>=4;top.halt=cycle<init_end;
        if((mode=="halt"||mode=="slow")&&!perturbation&&produced>=1024&&top.compute_wait) {
            perturbation=true;pause_until=cycle+(mode=="slow"?700000:5000);
        }
        if(cycle<pause_until)top.halt=1;
        top.valid=0;top.cw=0;top.cfg_wr=0;top.cfg_rd=0;top.srp_wr=0;
        top.ci=0;top.cd=0;top.cfg_addr=35;top.cfg_data=0;top.srp_addr=0;top.srp_data=0;
        if(cycle>=4&&cycle<36){top.cw=1;top.ci=cycle-4;top.cd=cycle==4?32767:0;}
        if(cycle==36){top.cfg_wr=1;top.cfg_addr=32;top.cfg_data=5;}
        if(cycle==37){top.srp_wr=1;top.srp_addr=0;top.srp_data=2;}
        if(cycle==38){top.srp_wr=1;top.srp_addr=2;top.srp_data=0;}
        if(cycle>=39&&cycle<39+lut.size()) {
            top.srp_wr=1;top.srp_addr=3;top.srp_data=lut[cycle-39];
        }
        if(cycle>=init_end&&top.audio_count)top.cfg_rd=1;
        if(cycle>=init_end&&top.enabled&&received<windows&&cycle%1024==0) {
            top.valid=1;top.sample_id=produced;
            if(mode=="gap"&&!perturbation&&produced>=1100){top.sample_id++;perturbation=true;}
            for(int i=0;i<9;i++)top.pcm[i]=0;
            int sum=0;
            for(int ch=0;ch<12;ch++) {
                int16_t x=pcm[(produced%2048)*12+ch];sum+=x;
                uint32_t bits=uint32_t(uint16_t(x))<<8;
                for(int bit=0;bit<24;bit++)if(bits&(1u<<bit))top.pcm[(ch*24+bit)/32]|=1u<<((ch*24+bit)%32);
            }
            int average=sum+6;average=average<0?-((-average+11)/12):average/12;
            int filtered=(average*32767)>>15;
            audio.push_back(uint16_t(average)|(uint32_t(uint16_t(filtered))<<16));
            produced++;
            if(produced>=1024&&(produced-1024)%512==0)ready.push_back(cycle);
        }
        top.eval();
        if(top.rst_n) {
            if(top.transfer_state>0&&top.transfer_state<29)stage_cycles[top.transfer_state]++;
            if(top.retire_valid&&top.fault)std::cerr<<"FAULT code="<<unsigned(top.fault)<<" pc="<<std::hex<<top.retire_pc<<" ins="<<top.retire_instr<<std::dec<<std::endl;
            check(!top.retire_valid||top.fault==0,"CPU_FAULT",cycle);
            check(top.fw_error==0,"FIRMWARE_ERROR",cycle);
            check(!top.raw_drop&&!top.window_drop,"CAPTURE_LOSS",cycle);
            check(top.audio_drop==0&&top.audio_max<1024,"AUDIO_DROP_OR_DEADLINE",cycle);
            unsigned w=(top.active_first%2048)/512;
            if(top.raw_check){check(top.raw_value==pcm[((top.active_first+top.n)%2048)*12+top.channel],"RAW_GOLDEN",cycle);raw_checks++;}
            if(top.prep_check)check(top.prepared_value==prep[(w*12+top.channel)*1024+top.n],"PREP_GOLDEN",cycle);
            if(top.fft_check){check(top.fft_value==fft[(w*12+top.channel)*513+top.index],"FFT_GOLDEN",cycle);fft_checks++;}
            if(top.phi_check){check(top.phi_value==phi[(w*66+top.pair)*513+6+top.index],"PHAT_GOLDEN",cycle);phi_checks++;}
            if(top.ring_check) {
                unsigned lag=top.ring_addr%32;if(lag>=16)lag+=992;
                uint32_t word=corr[(w*66+top.pair)*512+lag/2];
                check(top.ring_value==uint16_t(word>>(lag%2?16:0)),"RING_GOLDEN",cycle);ring_checks++;
            }
            if(top.score_check){check(top.score_value==scores[w*1024+top.score_addr],"SRP_GOLDEN",cycle);score_checks++;}
            if(top.audio_push) {
                check(audio_out<audio.size()&&top.audio_word==audio[audio_out],"AUDIO_GOLDEN",cycle);audio_out++;
            }
            if(top.retire_valid) {
                uint32_t ins=top.retire_instr,op=ins&127,fn=(ins>>12)&7;
                if(op==0x0b&&fn==7&&(ins>>31)&&((ins>>29)&1)){if((ins>>30)&1)inv++;else fwd++;}
                if(op==0x0b&&!(ins>>31)&&fn==6)cross++;
                if(op==0x0b&&!(ins>>31)&&fn==5)phat++;
                if(op==0x2b&&fn==0)srp++;
            }
            if(top.done) {
                received++;
                check(top.window_id==received&&top.first==(received-1)*512,"WINDOW_ID",cycle);
                check(fwd==received*12&&inv==received*66&&cross==received*66&&phat==received*66&&srp==received,"CUSTOM_INSTRUCTION_COUNT",cycle);
                check(raw_checks==received*12288&&fft_checks==received*6156&&ring_checks==received*2112&&phi_checks==received*13728&&score_checks==received*1024,"ORACLE_COVERAGE",cycle);
                for(int k=0;k<60;k++)check(top.statistics[k]==stats[w*60+k],"STATISTICS_GOLDEN",cycle);
                uint64_t delay=cycle-ready.at(received-1),gap=previous_result?cycle-previous_result:0;
                max_latency=std::max(max_latency,delay);max_compute=std::max(max_compute,uint64_t(top.compute_cycles));
                previous_result=cycle;
                std::cout<<"OVERLAP_WINDOW id="<<received<<" first="<<top.first<<" latency="<<delay
                         <<" fwd="<<fwd<<" inv="<<inv<<" srp="<<srp<<" raw_drop=0 window_drop=0 ready="
                         <<ready[received-1]<<" result="<<cycle<<" gap="<<gap<<" raw_checked="<<raw_checks
                         <<" compute="<<top.compute_cycles<<std::endl;
                std::cout<<"TRANSFER_STAGES id="<<received
                         <<" prepare="<<stage_cycles[1]+stage_cycles[2]+stage_cycles[3]
                         <<" fft_in="<<stage_cycles[4]+stage_cycles[5]<<" fft_run="<<stage_cycles[6]+stage_cycles[7]
                         <<" fft_out="<<stage_cycles[8]<<" gcc_in="<<stage_cycles[9]+stage_cycles[10]
                         <<" cross="<<stage_cycles[11]+stage_cycles[12]<<" phat="<<stage_cycles[13]+stage_cycles[14]
                         <<" phi_out="<<stage_cycles[15]<<" ifft_in="<<stage_cycles[16]+stage_cycles[17]
                         <<" ifft_run="<<stage_cycles[18]+stage_cycles[19]
                         <<" ring_out="<<stage_cycles[20]+stage_cycles[21]+stage_cycles[22]+stage_cycles[23]
                         <<" srp_run="<<stage_cycles[24]+stage_cycles[25]<<" srp_read="<<stage_cycles[26]+stage_cycles[27]
                         <<" publish_wait="<<stage_cycles[28]<<std::endl;
                for(auto& counter:stage_cycles)counter=0;
                check(delay<=524288&&(received==1||gap<=524288),"STRICT_DEADLINE",cycle);
            }
            if(received==windows&&top.fw_done&&audio_out==audio.size()) {
                check(mode=="normal"||perturbation,"PERTURBATION_NOT_EXECUTED",cycle);
                std::cout<<"LOCALIZER12_SOC_PASS windows="<<received<<" audio_in="<<audio.size()<<" audio_out="<<audio_out
                         <<" audio_drops=0 audio_max="<<top.audio_max<<" custom_fwd="<<fwd<<" custom_inv="<<inv
                         <<" custom_cross="<<cross<<" custom_phat="<<phat<<" custom_srp="<<srp<<std::endl;
                std::cout<<"OVERLAP_LOCALIZER_NUMERIC_PASS windows="<<received<<" max_latency="<<max_latency<<" max_compute="<<max_compute<<std::endl;
                std::cout<<"OVERLAP_COVERAGE first=0 samples="<<produced<<" raw_drop=0 window_drop=0"<<std::endl;
                top.final();return 0;
            }
        }
        top.clk=1;top.eval();
    }
    throw std::runtime_error("TIMEOUT");
 }catch(const std::exception& e){std::cerr<<"LOCALIZER12_SOC_FAIL "<<e.what()<<std::endl;return 1;}
}
