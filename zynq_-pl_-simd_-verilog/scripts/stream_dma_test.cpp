#include "Vrv32_stream_dma.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
double sc_time_stamp(){return 0.0;}
static void need(bool b,const std::string&s){if(!b)throw std::runtime_error(s);}
static uint32_t crc(const uint8_t*p,size_t n){uint32_t c=~0u;for(size_t i=0;i<n;i++){c^=p[i];for(int b=0;b<8;b++)c=(c>>1)^((0u-(c&1))&0xedb88320u);}return ~c;}
static uint32_t word(const uint8_t*p){return uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;}
#ifndef TEST_CHANNELS
#define TEST_CHANNELS 12
#endif
static uint32_t source_word(uint32_t seq,unsigned i){
 if(i==0)return TEST_CHANNELS==9?0x47534302:0x47534301;if(i==1)return seq;
 return (seq*0x9e3779b9u)^(i*0x10203041u)^0x73b19e25u;
}
struct Model {
 Vrv32_stream_dma t;
 uint64_t cycles=0,inputs=0,received=0,transactions=0;
 uint32_t source_seq=0,consumer=0,calibration=2;
 unsigned remaining=0,period=40,beat=0;
 bool aw_active=false,pending_b=false,force_error=false;
 uint64_t aw_stall_until=0,w_stall_until=0,b_stall_until=0;
 uint32_t address=0,response=0;unsigned bdelay=0;
 std::array<std::array<uint8_t,128>,16> memory{};
 bool c_aw=false,c_w=false,c_b=false,c_ar=false,c_r=false;uint32_t c_br=0,c_rr=0,c_rd=0;
 bool aw_held=false,w_held=false,sb_held=false,sr_held=false;
 uint32_t held_aw=0,held_sb=0,held_sr=0,held_rr=0;uint64_t held_w=0;bool held_last=false;
 std::vector<uint32_t> samples;
 Model(){
  t.clk_i=0;t.rst_n_i=0;t.stream_valid_i=0;t.stream_timestamp_i=0;
  t.s_axi_awvalid=0;t.s_axi_wvalid=0;t.s_axi_bready=1;t.s_axi_arvalid=0;t.s_axi_rready=1;
  t.s_axi_awaddr=t.s_axi_araddr=0;t.s_axi_wdata=0;t.s_axi_wstrb=15;
  t.m_axi_arready=1;t.m_axi_rdata=0;t.m_axi_rresp=0;t.m_axi_rlast=0;t.m_axi_rvalid=0;
  for(int i=0;i<5;i++)tick();t.rst_n_i=1;for(int i=0;i<3;i++)tick();
 }
 void tick(){
  t.clk_i=0;
  t.m_axi_awready=!aw_active&&!pending_b&&cycles>=aw_stall_until&&cycles%7!=0;
  t.m_axi_wready=aw_active&&cycles>=w_stall_until&&cycles%4!=0;
  t.m_axi_bvalid=pending_b&&bdelay==0&&cycles>=b_stall_until;t.m_axi_bresp=response;
  t.stream_valid_i=t.rst_n_i&&remaining&&cycles%period==0;
  if(t.stream_valid_i){for(unsigned i=0;i<16;i++)t.stream_data_i[i]=source_word(source_seq,i);t.stream_timestamp_i=uint64_t(source_seq)*1024+17;}
  t.eval();
  need(t.stream_ready_o==1,"STREAM_BACKPRESSURE");need(t.m_axi_arvalid==0,"UNEXPECTED_READ");
  if(t.rst_n_i&&aw_held)need(t.m_axi_awvalid&&t.m_axi_awaddr==held_aw,"AW_WITHDRAWN_OR_CHANGED");
  if(t.rst_n_i&&w_held)need(t.m_axi_wvalid&&t.m_axi_wdata==held_w&&bool(t.m_axi_wlast)==held_last,"W_WITHDRAWN_OR_CHANGED");
  if(t.rst_n_i&&sb_held)need(t.s_axi_bvalid&&t.s_axi_bresp==held_sb,"CSR_B_UNSTABLE");
  if(t.rst_n_i&&sr_held)need(t.s_axi_rvalid&&t.s_axi_rdata==held_sr&&t.s_axi_rresp==held_rr,"CSR_R_UNSTABLE");
  aw_held=t.m_axi_awvalid&&!t.m_axi_awready;held_aw=t.m_axi_awaddr;
  w_held=t.m_axi_wvalid&&!t.m_axi_wready;held_w=t.m_axi_wdata;held_last=t.m_axi_wlast;
  sb_held=t.s_axi_bvalid&&!t.s_axi_bready;held_sb=t.s_axi_bresp;
  sr_held=t.s_axi_rvalid&&!t.s_axi_rready;held_sr=t.s_axi_rdata;held_rr=t.s_axi_rresp;
  bool af=t.m_axi_awvalid&&t.m_axi_awready,wf=t.m_axi_wvalid&&t.m_axi_wready,bf=t.m_axi_bvalid&&t.m_axi_bready;
  uint64_t data=t.m_axi_wdata;bool last=t.m_axi_wlast;uint32_t aw=t.m_axi_awaddr;
  c_aw=t.s_axi_awvalid&&t.s_axi_awready;c_w=t.s_axi_wvalid&&t.s_axi_wready;
  c_b=t.s_axi_bvalid&&t.s_axi_bready;c_br=t.s_axi_bresp;
  c_ar=t.s_axi_arvalid&&t.s_axi_arready;c_r=t.s_axi_rvalid&&t.s_axi_rready;c_rd=t.s_axi_rdata;c_rr=t.s_axi_rresp;
  if(af){need(!aw_active&&!pending_b,"MULTIPLE_OUTSTANDING");need(aw>=0x08000000u&&aw<0x08000800u&&(aw&127)==0,"DDR_ADDRESS_ESCAPE");
   need(t.m_axi_awlen==15&&t.m_axi_awsize==3&&t.m_axi_awburst==1,"BAD_BURST");}
  if(wf)need(t.m_axi_wstrb==255&&last==(beat==15),"BAD_WRITE_BEAT");
  t.clk_i=1;t.eval();cycles++;
  if(!t.rst_n_i){aw_active=pending_b=false;beat=0;aw_held=w_held=sb_held=sr_held=false;return;}
  if(t.stream_valid_i){inputs++;source_seq++;remaining--;}
  if(bf){need(pending_b,"UNEXPECTED_B");pending_b=false;response=0;}
  if(af){aw_active=true;address=aw;beat=0;transactions++;response=force_error?2:0;force_error=false;}
  if(wf){
   need(aw_active&&beat<16,"W_WITHOUT_AW");auto&slot=memory[(address-0x08000000u)/128];
   for(unsigned j=0;j<8;j++)slot[beat*8+j]=uint8_t(data>>(8*j));
   beat++;
   if(last){need(beat==16,"EARLY_LAST");aw_active=false;pending_b=true;bdelay=2+transactions%3;}
  }
  if(pending_b&&bdelay)bdelay--;
 }
 void wait(unsigned n){for(unsigned i=0;i<n;i++)tick();}
 void write(uint32_t a,uint32_t d,uint32_t expected=0,unsigned strobe=15){
  t.s_axi_awaddr=a;t.s_axi_wdata=d;t.s_axi_wstrb=strobe;t.s_axi_bready=0;
  bool ad=false,wd=false,done=false;unsigned wait_b=0;
  for(unsigned n=0;n<10000&&!done;n++){
   // Exercise AW/W in both orders and together.
   t.s_axi_awvalid=!ad&&(a%3!=0||n>=3);t.s_axi_wvalid=!wd&&(a%3!=1||n>=3);
   if(ad&&wd){wait_b++;t.s_axi_bready=wait_b>=5;}
   tick();if(c_aw)ad=true;if(c_w)wd=true;
   if(c_b){need(c_br==expected,"CSR_WRITE_RESPONSE addr="+std::to_string(a));done=true;}
  }
  t.s_axi_awvalid=t.s_axi_wvalid=0;t.s_axi_bready=1;need(done,"CSR_WRITE_TIMEOUT");
 }
 uint32_t read(uint32_t a,uint32_t expected=0){
  t.s_axi_araddr=a;t.s_axi_arvalid=1;t.s_axi_rready=0;bool ar=false;unsigned wait_r=0;
  for(unsigned n=0;n<10000;n++){
   t.s_axi_arvalid=!ar;if(ar){wait_r++;t.s_axi_rready=wait_r>=5;}
   tick();if(c_ar)ar=true;
   if(c_r){need(c_rr==expected,"CSR_READ_RESPONSE");t.s_axi_arvalid=0;t.s_axi_rready=1;return c_rd;}
  }
  throw std::runtime_error("CSR_READ_TIMEOUT");
 }
 void setup(){
  need(read(0)==0x394d4450,"ID");write(4,1,2); // cannot enable unconfigured DMA
  write(8,0x08000000);write(12,4);write(0x28,64);write(0x44,calibration);write(4,1);
 }
 void consume(){
  uint32_t producer=read(0x14);need(uint32_t(producer-consumer)<=16,"OWNERSHIP_OVERFLOW");
  while(consumer!=producer){
   auto&slot=memory[consumer&15];need(word(slot.data()+72)==consumer,"OWNER_SEQUENCE");
   need(word(slot.data()+124)==~consumer,"COMMIT");need(word(slot.data()+120)==crc(slot.data(),120),"DDR_CRC");
   uint32_t seq=word(slot.data()+4);
   for(unsigned i=0;i<16;i++)need(word(slot.data()+4*i)==source_word(seq,i),"DDR_PAYLOAD_CORRUPTION");
   uint64_t stamp=word(slot.data()+64)|(uint64_t(word(slot.data()+68))<<32);
   need(stamp==uint64_t(seq)*1024+17,"TIMESTAMP_PAIRING");
   need(word(slot.data()+80)==0x394d4450&&word(slot.data()+84)==128&&word(slot.data()+88)==calibration&&word(slot.data()+92)==(0x00100000|TEST_CHANNELS),"FORMAT");
   for(unsigned i=96;i<120;i++)need(slot[i]==0,"RESERVED_DATA");
   if(!samples.empty())need(seq>samples.back(),"DUPLICATE_OR_REORDERED_SAMPLE");
   samples.push_back(seq);received++;consumer++;
  }
  write(0x10,consumer);
 }
 void drain(){
  for(unsigned n=0;n<20000;n++){
   consume();uint32_t status=read(0x24),level=read(0x34),prod=read(0x14);
   if(!remaining&&!(status&7)&&level==0&&prod==consumer)return;
  }
  throw std::runtime_error("DRAIN_TIMEOUT");
 }
 void traffic(unsigned n){remaining=n;while(remaining)consume();drain();}
 void recover(){write(4,0);write(4,6);need((read(0x24)&16)==0,"FAULT_NOT_CLEARED");write(4,1);}
};
int main(int argc,char**argv){
 Verilated::commandArgs(argc,argv);
 try{
  Model m;m.setup();m.traffic(1000);need(m.read(0x18)==0,"NORMAL_LOSS");
  std::cout<<"DMA_NORMAL_PASS frames="<<m.received<<"\n";
  m.remaining=1000;while(m.remaining)m.tick();m.drain();need(m.read(0x18)>0,"CONGESTION_NOT_EXERCISED");
  uint32_t drops=m.read(0x18);std::cout<<"DMA_CONGESTION_PASS drops="<<drops<<"\n";
  uint32_t oldprod=m.read(0x14);m.force_error=true;m.remaining=1;while(m.remaining)m.tick();m.wait(120);
  need((m.read(0x24)&16)&&m.read(0x1c)==1&&m.read(0x14)==oldprod,"BRESP_ERROR_PUBLICATION");
  m.write(4,2,2);m.recover();m.traffic(1);
  for(unsigned kind=0;kind<3;kind++){
   oldprod=m.read(0x14);
   if(kind==0)m.aw_stall_until=m.cycles+300;
   if(kind==1)m.w_stall_until=m.cycles+300;
   if(kind==2)m.b_stall_until=m.cycles+300;
   m.remaining=1;while(m.remaining)m.tick();m.wait(120);
   need(m.read(0x24)&16,"TIMEOUT_NOT_LATCHED");m.write(4,2,2);m.write(4,0);
   m.wait(400);need(m.read(0x14)==oldprod,"TIMED_OUT_SLOT_PUBLISHED");
   m.write(4,6);m.write(4,1);m.traffic(1);
  }
  need(m.read(0x20)==3,"TIMEOUT_COUNT");
  std::cout<<"DMA_BRESP_TIMEOUT_RECOVERY_PASS phases=AW,W,B\n";
  m.write(0x10,m.consumer+1,2);m.write(0x10,m.consumer-1,2);m.write(0x44,99,2);
  m.write(4,0);m.write(8,0x08000001,2);m.write(12,3,2);m.write(12,13,2);m.write(0x28,15,2);
  m.write(0,123,2);m.write(0x28,64,2,3);need(m.read(0x100,2)==0,"BAD_READ_DATA");
  m.write(8,0x0ffff800);m.write(8,0x0ffff880,2);m.write(8,0x08000000);
  m.write(12,12);need(m.read(12)==12,"MAX_RING_SIZE");m.write(12,4);
  m.write(0x40,0xfffffff0);m.consumer=0xfffffff0;m.write(4,1);m.traffic(100);
  need(m.read(0x14)==84&&m.consumer==84,"RING_COUNTER_WRAP");
  m.traffic(100000);m.write(4,0);m.write(4,4);m.drain();
  uint32_t finaldrops=m.read(0x18);
  need(m.inputs==m.received+finaldrops,"UNCOUNTED_INPUT_LOSS");
  need(m.read(0x30)==m.inputs&&m.read(0x1c)==1&&m.read(0x20)==3,"FINAL_STATISTICS");
  // A coherent global reset is a unit test only, not a board operation.
  Model reset;reset.setup();reset.aw_stall_until=reset.cycles+300;reset.remaining=1;
  while(reset.remaining)reset.tick();reset.wait(10);need(reset.t.m_axi_awvalid,"RESET_NOT_IN_TRANSACTION");
  reset.t.rst_n_i=0;reset.wait(3);need(!reset.t.m_axi_awvalid&&!reset.t.m_axi_wvalid,"RESET_OUTPUTS");
  reset.t.rst_n_i=1;reset.wait(3);need(reset.read(0x14)==0&&reset.read(0x18)==0,"RESET_COUNTERS");
  std::cout<<"STREAM_DMA_PASS inputs="<<m.inputs<<" published="<<m.received<<" drops="<<finaldrops
           <<" axi_errors="<<m.read(0x1c)<<" timeouts="<<m.read(0x20)<<" config_errors="<<m.read(0x2c)<<"\n";
  return 0;
 }catch(const std::exception&e){std::cerr<<"STREAM_DMA_FAIL "<<e.what()<<"\n";return 1;}
}
